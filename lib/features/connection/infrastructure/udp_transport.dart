import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'network_transport_error.dart';

/// 基于 `dart:io` 的 UDP 传输。
///
/// 每个数据报都转换为一个独立的 [TransportDataEvent]，包括空数据报。默认远端
/// 地址可以在配置中指定；启用 [followRemoteEndpoint] 后，最近数据报的来源会
/// 成为后续发送目标，便于设备调试时直接回复。
final class UdpTransport implements Transport {
  /// 创建 UDP 传输。
  UdpTransport({
    required this.bindAddress,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.followRemoteEndpoint,
  }) : assert(localPort >= 0 && localPort <= 65535),
       assert(remotePort > 0 && remotePort <= 65535);

  /// 本地绑定地址。
  final String bindAddress;

  /// 本地绑定端口；零表示由系统分配。
  final int localPort;

  /// 默认远端主机；为空时只能回复最近来源。
  final String remoteHost;

  /// 默认远端端口。
  final int remotePort;

  /// 是否跟随最近数据报来源更新发送目标。
  final bool followRemoteEndpoint;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  InternetAddress? _remoteAddress;
  int? _remotePort;
  TransportStatus _status = TransportStatus.disconnected;
  bool _disposed = false;
  bool _closing = false;

  /// 实际绑定端口；未打开时为 `null`。
  int? get boundPort => _socket?.port;

  /// 当前发送目标地址；尚未确定时为 `null`。
  InternetAddress? get currentRemoteAddress => _remoteAddress;

  /// 当前发送目标端口；尚未确定时为 `null`。
  int? get currentRemotePort => _remotePort;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected &&
        _status != TransportStatus.error) {
      throw _exception(TransportErrorCode.invalidState, 'UDP 传输已打开');
    }
    if (bindAddress.trim().isEmpty) {
      throw _exception(TransportErrorCode.invalidState, '请先填写本地监听地址');
    }

    await _releaseSocket(emitDisconnected: false);
    _remoteAddress = null;
    _remotePort = null;
    _status = TransportStatus.connecting;
    try {
      if (remoteHost.trim().isNotEmpty) {
        final addresses = await InternetAddress.lookup(remoteHost.trim());
        if (addresses.isEmpty) {
          throw networkTransportException(
            TransportErrorCode.addressResolutionFailed,
            '无法解析远端主机 ${remoteHost.trim()}',
          );
        }
        _remoteAddress = _preferIpv4(addresses);
        _remotePort = remotePort;
      }

      final socket = await RawDatagramSocket.bind(
        bindAddress.trim(),
        localPort,
        reuseAddress: false,
      );
      if (_disposed) {
        socket.close();
        return;
      }
      _socket = socket;
      _socketSubscription = socket.listen(
        _handleSocketEvent,
        onError: _handleSocketError,
        onDone: _handleSocketDone,
        cancelOnError: false,
      );
      _status = TransportStatus.connected;
      _events.add(
        TransportConnectedEvent(
          detail: _connectionDetail(bindAddress.trim(), socket.port),
        ),
      );
    } catch (error) {
      if (_disposed) {
        return;
      }
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.bindFailed,
        message: '无法绑定 UDP ${bindAddress.trim()}:$localPort',
      );
      _status = TransportStatus.error;
      _events.add(TransportErrorEvent(failure));
      await _releaseSocket(emitDisconnected: false);
      throw TransportException(failure);
    }
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    _ensureUsable();
    final socket = _socket;
    final address = _remoteAddress;
    final port = _remotePort;
    if (_status != TransportStatus.connected || socket == null) {
      throw _exception(TransportErrorCode.disconnected, 'UDP 尚未打开，不能发送数据');
    }
    if (address == null || port == null) {
      throw _exception(
        TransportErrorCode.invalidState,
        'UDP 尚未确定远端地址，请先配置远端或接收一个数据报',
      );
    }
    try {
      final acceptedLength = socket.send(bytes, address, port);
      if (acceptedLength <= 0 && bytes.isNotEmpty) {
        throw const SocketException('UDP 数据报未被系统接受');
      }
      return SendResult(
        requestedLength: bytes.length,
        acceptedLength: acceptedLength,
        completedAt: DateTime.now(),
      );
    } catch (error) {
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.writeFailed,
        message: 'UDP 数据发送失败',
      );
      _events.add(TransportErrorEvent(failure));
      throw TransportException(failure);
    }
  }

  @override
  Future<void> close() async {
    _ensureUsable();
    if (_status == TransportStatus.disconnected && _socket == null) {
      return;
    }
    _closing = true;
    _status = TransportStatus.disconnecting;
    await _releaseSocket(emitDisconnected: false);
    _status = TransportStatus.disconnected;
    _events.add(TransportDisconnectedEvent());
    _closing = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    try {
      await close();
    } finally {
      _disposed = true;
      await _events.close();
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (_disposed || _closing || event == RawSocketEvent.closed) {
      return;
    }
    final socket = _socket;
    if (socket == null) {
      return;
    }
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      if (followRemoteEndpoint) {
        _remoteAddress = datagram.address;
        _remotePort = datagram.port;
      }
      _events.add(TransportDataEvent(datagram.data));
    }
  }

  void _handleSocketError(Object error, StackTrace _) {
    if (_disposed || _closing) {
      return;
    }
    final failure = mapNetworkIoError(
      error,
      fallbackCode: TransportErrorCode.readFailed,
      message: 'UDP 接收失败',
    );
    _status = TransportStatus.error;
    _events.add(TransportErrorEvent(failure));
    unawaited(_releaseSocket(emitDisconnected: false));
  }

  void _handleSocketDone() {
    if (_disposed || _closing) {
      return;
    }
    _status = TransportStatus.disconnected;
    unawaited(_releaseSocket(emitDisconnected: false));
    _events.add(TransportDisconnectedEvent(reason: 'UDP socket 已关闭'));
  }

  String _connectionDetail(String address, int boundPort) {
    final host = _remoteAddress;
    final port = _remotePort;
    if (host == null || port == null) {
      return '已绑定 $address:$boundPort，等待远端或首个数据报';
    }
    return '已绑定 $address:$boundPort，远端 ${host.address}:$port';
  }

  InternetAddress _preferIpv4(List<InternetAddress> addresses) {
    return addresses.firstWhere(
      (address) => address.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
  }

  Future<void> _releaseSocket({required bool emitDisconnected}) async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // 关闭后的 UDP 流可能已经自行结束，继续释放底层 socket。
      }
    }
    final socket = _socket;
    _socket = null;
    socket?.close();
    if (emitDisconnected && !_disposed) {
      _events.add(TransportDisconnectedEvent());
    }
  }

  TransportException _exception(TransportErrorCode code, String message) {
    return networkTransportException(code, message);
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('UdpTransport 已销毁');
    }
  }
}
