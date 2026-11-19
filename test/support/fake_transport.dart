import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 可记录资源和状态变化的通用传输测试替身。
final class FakeTransport implements Transport {
  /// 创建 Fake Transport。
  FakeTransport({
    this.openStatus = TransportStatus.connected,
    this.detail = '已连接测试传输',
    this.blockSends = false,
  });

  /// 打开成功后的状态。
  final TransportStatus openStatus;

  /// 打开或监听事件说明。
  final String detail;

  /// 模拟对端停止读取，只有关闭连接才能解除发送等待。
  final bool blockSends;
  final Completer<void> sendStarted = Completer<void>();
  final Completer<void> _sendInterrupted = Completer<void>();

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);
  final List<Uint8List> sentBatches = <Uint8List>[];

  TransportStatus _status = TransportStatus.disconnected;
  bool _disposed = false;

  /// 是否执行过关闭操作。
  bool wasClosed = false;

  /// 是否已经释放。
  bool get isDisposed => _disposed;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Future<void> open() async {
    if (_disposed) {
      throw StateError('FakeTransport 已销毁');
    }
    _status = openStatus;
    _events.add(
      openStatus == TransportStatus.listening
          ? TransportListeningEvent(detail: detail)
          : TransportConnectedEvent(detail: detail),
    );
  }

  @override
  Future<void> close() async {
    if (_disposed) {
      return;
    }
    wasClosed = true;
    if (_status == TransportStatus.disconnected) {
      return;
    }
    _status = TransportStatus.disconnected;
    if (!_sendInterrupted.isCompleted) {
      _sendInterrupted.complete();
    }
    _events.add(TransportDisconnectedEvent());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await close();
    _disposed = true;
    await _events.close();
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    if (_status != TransportStatus.connected) {
      throw TransportException(
        const TransportError(
          code: TransportErrorCode.disconnected,
          message: '测试传输未连接',
        ),
      );
    }
    sentBatches.add(Uint8List.fromList(bytes));
    if (!sendStarted.isCompleted) {
      sendStarted.complete();
    }
    if (blockSends) {
      await _sendInterrupted.future;
      throw StateError('发送被关闭连接中止');
    }
    return SendResult(
      requestedLength: bytes.length,
      acceptedLength: bytes.length,
      completedAt: DateTime.now(),
    );
  }

  /// 注入接收数据。
  void injectData(Uint8List bytes) {
    _events.add(TransportDataEvent(bytes));
  }

  /// 模拟远端断开。
  void simulateDisconnect() {
    _status = TransportStatus.disconnected;
    _events.add(TransportDisconnectedEvent(reason: '测试远端断开'));
  }
}

/// 记录配置并按顺序创建 [FakeTransport] 的工厂。
final class RecordingTransportFactory implements TransportFactory {
  RecordingTransportFactory({this.blockSends = false});

  final bool blockSends;

  /// 已创建的配置。
  final List<TransportConfig> configs = <TransportConfig>[];

  /// 已创建的传输。
  final List<FakeTransport> transports = <FakeTransport>[];

  @override
  Transport create(TransportConfig config) {
    configs.add(config);
    final transport = FakeTransport(
      blockSends: blockSends,
      openStatus: config is TcpServerTransportConfig
          ? TransportStatus.listening
          : TransportStatus.connected,
      detail: config is TcpServerTransportConfig ? '测试监听中' : '测试已连接',
    );
    transports.add(transport);
    return transport;
  }
}
