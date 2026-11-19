import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'network_transport_error.dart';

/// 基于 `dart:io` 的 TCP 客户端传输。
///
/// 一个实例对应一条 TCP 连接；关闭或外部断开后不自动重连，避免在网络异常
/// 时形成用户不可见的后台重试。底层 socket 和监听订阅由本类统一释放。
final class TcpClientTransport implements Transport {
  /// 创建 TCP 客户端传输。
  TcpClientTransport({
    required this.host,
    required this.port,
    this.connectTimeout = const Duration(seconds: 10),
  }) : assert(port > 0 && port <= 65535),
       assert(connectTimeout > Duration.zero);

  /// 远端主机名或 IP 地址。
  final String host;

  /// 远端端口。
  final int port;

  /// 建立连接的超时时间。
  final Duration connectTimeout;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSubscription;
  TransportStatus _status = TransportStatus.disconnected;
  bool _disposed = false;
  bool _closing = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected &&
        _status != TransportStatus.error) {
      throw _exception(TransportErrorCode.invalidState, 'TCP 客户端已在连接或已连接');
    }
    if (host.trim().isEmpty) {
      throw _exception(TransportErrorCode.invalidState, '请先填写远端主机');
    }

    await _releaseSocket(emitDisconnected: false);
    _status = TransportStatus.connecting;
    try {
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: connectTimeout,
      );
      if (_disposed) {
        socket.destroy();
        return;
      }
      _socket = socket;
      _socketSubscription = socket.listen(
        _handleData,
        onError: _handleSocketError,
        onDone: _handleSocketDone,
        cancelOnError: false,
      );
      _status = TransportStatus.connected;
      _events.add(TransportConnectedEvent(detail: '已连接 ${host.trim()}:$port'));
    } catch (error) {
      if (_disposed) {
        return;
      }
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.connectionFailed,
        message: '无法连接 ${host.trim()}:$port',
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
    if (_status != TransportStatus.connected || socket == null) {
      throw _exception(TransportErrorCode.disconnected, 'TCP 尚未连接，不能发送数据');
    }
    try {
      socket.add(bytes);
      await socket.flush();
      return SendResult(
        requestedLength: bytes.length,
        acceptedLength: bytes.length,
        completedAt: DateTime.now(),
      );
    } catch (error) {
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.writeFailed,
        message: 'TCP 数据发送失败',
      );
      _status = TransportStatus.error;
      _events.add(TransportErrorEvent(failure));
      await _releaseSocket(emitDisconnected: false);
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

  void _handleData(Uint8List bytes) {
    if (_disposed || _status != TransportStatus.connected) {
      return;
    }
    _events.add(TransportDataEvent(bytes));
  }

  void _handleSocketError(Object error, StackTrace _) {
    if (_disposed || _closing) {
      return;
    }
    final failure = mapNetworkIoError(
      error,
      fallbackCode: TransportErrorCode.readFailed,
      message: 'TCP 连接发生错误',
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
    _events.add(TransportDisconnectedEvent(reason: 'TCP 连接已被远端关闭'));
  }

  Future<void> _releaseSocket({required bool emitDisconnected}) async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // socket 已断开时取消订阅可能失败，后续仍必须释放底层句柄。
      }
    }
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    if (emitDisconnected && !_disposed) {
      _events.add(TransportDisconnectedEvent());
    }
  }

  TransportException _exception(TransportErrorCode code, String message) {
    return networkTransportException(code, message);
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('TcpClientTransport 已销毁');
    }
  }
}
