import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'network_transport_error.dart';

/// 基于 `dart:io` 的单客户端 TCP 服务端传输。
///
/// 监听器建立后保持存在；首个客户端连接时进入已连接状态，客户端断开后回到
/// 监听状态，以便设备重连。第二个并发客户端会被立即关闭，避免在旧版多客户端
/// 行为尚未确认前悄然扩展协议语义。
final class TcpServerTransport implements Transport {
  /// 创建 TCP 服务端传输。
  TcpServerTransport({required this.bindAddress, required this.port})
    : assert(port >= 0 && port <= 65535);

  /// 监听地址。
  final String bindAddress;

  /// 请求的监听端口；零表示由系统分配。
  final int port;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);

  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSubscription;
  Socket? _client;
  final Set<Completer<void>> _pendingSends = <Completer<void>>{};
  StreamSubscription<Uint8List>? _clientSubscription;
  TransportStatus _status = TransportStatus.disconnected;
  bool _disposed = false;
  bool _closing = false;

  /// 实际监听端口；监听未建立时为 `null`。
  int? get boundPort => _server?.port;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected &&
        _status != TransportStatus.error) {
      throw _exception(TransportErrorCode.invalidState, 'TCP 服务端已启动');
    }
    if (bindAddress.trim().isEmpty) {
      throw _exception(TransportErrorCode.invalidState, '请先填写监听地址');
    }

    await _releaseAll(emitDisconnected: false);
    _status = TransportStatus.connecting;
    try {
      final server = await ServerSocket.bind(
        bindAddress.trim(),
        port,
        shared: false,
      );
      if (_disposed) {
        await server.close();
        return;
      }
      _server = server;
      _status = TransportStatus.listening;
      _acceptSubscription = server.listen(
        _handleClient,
        onError: _handleServerError,
        onDone: _handleServerDone,
        cancelOnError: false,
      );
      _events.add(
        TransportListeningEvent(
          detail: '正在监听 ${bindAddress.trim()}:${server.port}，等待客户端',
        ),
      );
    } catch (error) {
      if (_disposed) {
        return;
      }
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.bindFailed,
        message: '无法监听 ${bindAddress.trim()}:$port',
      );
      _status = TransportStatus.error;
      _events.add(TransportErrorEvent(failure));
      await _releaseAll(emitDisconnected: false);
      throw TransportException(failure);
    }
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    _ensureUsable();
    final client = _client;
    if (_status != TransportStatus.connected || client == null) {
      throw _exception(TransportErrorCode.disconnected, '没有 TCP 客户端连接，不能发送数据');
    }
    final aborted = Completer<void>();
    _pendingSends.add(aborted);
    try {
      client.add(bytes);
      await Future.any<void>([
        client.flush(),
        aborted.future.then<void>((_) {
          throw _exception(TransportErrorCode.disconnected, 'TCP 发送已因连接关闭而中止');
        }),
      ]);
      if (!identical(_client, client)) {
        throw _exception(TransportErrorCode.disconnected, 'TCP 客户端已断开');
      }
      return SendResult(
        requestedLength: bytes.length,
        acceptedLength: bytes.length,
        completedAt: DateTime.now(),
      );
    } catch (error) {
      final failure = mapNetworkIoError(
        error,
        fallbackCode: TransportErrorCode.writeFailed,
        message: 'TCP 服务端发送失败',
      );
      if (!_disposed && !_closing && identical(_client, client)) {
        _events.add(TransportErrorEvent(failure));
        await _returnToListening();
      }
      throw TransportException(failure);
    } finally {
      _pendingSends.remove(aborted);
    }
  }

  @override
  Future<void> close() async {
    _ensureUsable();
    if (_status == TransportStatus.disconnected &&
        _server == null &&
        _client == null) {
      return;
    }
    _closing = true;
    _status = TransportStatus.disconnecting;
    await _releaseAll(emitDisconnected: false);
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

  void _handleClient(Socket socket) {
    if (_disposed || _closing || _status == TransportStatus.error) {
      socket.destroy();
      return;
    }
    if (_client != null) {
      socket.destroy();
      return;
    }

    _client = socket;
    _clientSubscription = socket.listen(
      _handleClientData,
      onError: _handleClientError,
      onDone: _handleClientDone,
      cancelOnError: false,
    );
    _status = TransportStatus.connected;
    _events.add(
      TransportConnectedEvent(
        detail: '客户端 ${socket.remoteAddress.address}:${socket.remotePort} 已连接',
      ),
    );
  }

  void _handleClientData(Uint8List bytes) {
    if (_disposed || _status != TransportStatus.connected) {
      return;
    }
    _events.add(TransportDataEvent(bytes));
  }

  void _handleClientError(Object error, StackTrace _) {
    if (_disposed || _closing) {
      return;
    }
    final failure = mapNetworkIoError(
      error,
      fallbackCode: TransportErrorCode.readFailed,
      message: 'TCP 客户端连接发生错误',
    );
    _events.add(TransportErrorEvent(failure));
    unawaited(_returnToListening());
  }

  void _handleClientDone() {
    if (_disposed || _closing) {
      return;
    }
    unawaited(_returnToListening());
  }

  void _handleServerError(Object error, StackTrace _) {
    if (_disposed || _closing) {
      return;
    }
    final failure = mapNetworkIoError(
      error,
      fallbackCode: TransportErrorCode.readFailed,
      message: 'TCP 监听器发生错误',
    );
    _status = TransportStatus.error;
    _events.add(TransportErrorEvent(failure));
    unawaited(_handleServerFailure());
  }

  void _handleServerDone() {
    if (_disposed || _closing || _status == TransportStatus.error) {
      return;
    }
    _status = TransportStatus.disconnected;
    _events.add(TransportDisconnectedEvent(reason: 'TCP 监听器已停止'));
  }

  Future<void> _handleServerFailure() async {
    await _releaseAll(emitDisconnected: false);
    if (!_disposed) {
      _events.add(TransportDisconnectedEvent(reason: 'TCP 监听器已停止'));
    }
  }

  Future<void> _returnToListening() async {
    await _releaseClient(emitListening: false);
    if (_disposed || _closing || _server == null) {
      return;
    }
    _status = TransportStatus.listening;
    _events.add(TransportListeningEvent(detail: _listeningDetail()));
  }

  String _listeningDetail() {
    final server = _server;
    final address = server?.address.address ?? bindAddress.trim();
    final boundPort = server?.port ?? port;
    return '正在监听 $address:$boundPort，等待客户端';
  }

  Future<void> _releaseClient({required bool emitListening}) async {
    final client = _client;
    _client = null;
    for (final aborted in _pendingSends) {
      aborted.complete();
    }
    _pendingSends.clear();
    client?.destroy();
    final subscription = _clientSubscription;
    _clientSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // 连接已关闭时取消订阅可能失败，但底层 socket 仍需销毁。
      }
    }
    if (emitListening && !_disposed && _server != null) {
      _status = TransportStatus.listening;
      _events.add(TransportListeningEvent(detail: _listeningDetail()));
    }
  }

  Future<void> _releaseAll({required bool emitDisconnected}) async {
    final acceptSubscription = _acceptSubscription;
    _acceptSubscription = null;
    if (acceptSubscription != null) {
      try {
        await acceptSubscription.cancel();
      } catch (_) {
        // 已停止的监听流无需重复暴露取消异常。
      }
    }
    await _releaseClient(emitListening: false);
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {
        // 关闭阶段优先保证句柄释放和状态结束。
      }
    }
    if (emitDisconnected && !_disposed) {
      _events.add(TransportDisconnectedEvent());
    }
  }

  TransportException _exception(TransportErrorCode code, String message) {
    return networkTransportException(code, message);
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('TcpServerTransport 已销毁');
    }
  }
}
