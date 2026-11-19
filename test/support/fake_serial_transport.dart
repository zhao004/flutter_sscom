import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 可编排状态、事件和失败的串口传输测试替身。
///
/// 事件流使用同步广播控制器，便于测试在调用后立即断言状态转换。该替身不
/// 模拟真实串口时序，硬件兼容性仍由独立验收覆盖。
final class FakeSerialTransport implements SerialTransport {
  /// 创建 Fake Transport。
  ///
  /// [openError]、[sendError] 和 [configureError] 分别注入对应操作的失败。
  FakeSerialTransport({
    this.openError,
    this.sendError,
    this.configureError,
    this.maxSendChunk,
    this.sendDelay,
    SerialConfig initialConfig = const SerialConfig(
      portName: 'COM1',
      baudRate: 115200,
    ),
    Iterable<SerialPortInfo> initialPorts = const <SerialPortInfo>[],
  }) : _config = initialConfig,
       _ports = List<SerialPortInfo>.unmodifiable(initialPorts);

  /// 打开操作的固定失败。
  final TransportError? openError;

  /// 发送操作的固定失败。
  final TransportError? sendError;

  /// 配置操作的固定失败。
  final TransportError? configureError;

  /// 单次发送最多接受的字节数；为 `null` 时接受全部输入。
  final int? maxSendChunk;

  /// 单次发送完成的模拟延迟。
  final Duration? sendDelay;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);
  final StreamController<List<SerialPortInfo>> _portChanges =
      StreamController<List<SerialPortInfo>>.broadcast(sync: true);
  final List<Uint8List> _sentBatches = <Uint8List>[];
  final List<SendResult> _sendResults = <SendResult>[];

  SerialConfig _config;
  List<SerialPortInfo> _ports;
  SerialSignalState _signals = const SerialSignalState();
  TransportStatus _status = TransportStatus.disconnected;
  bool _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Stream<List<SerialPortInfo>> get portChanges => _portChanges.stream;

  /// 当前串口配置。
  SerialConfig get config => _config;

  /// 当前 DTR/RTS 与输入信号状态。
  SerialSignalState get signals => _signals;

  /// 当前端口快照的只读副本。
  List<SerialPortInfo> get currentPorts =>
      UnmodifiableListView<SerialPortInfo>(_ports);

  /// 传输是否已经释放。
  bool get isDisposed => _disposed;

  /// 已成功发送的批次深拷贝。
  List<Uint8List> get sentBatches =>
      List<Uint8List>.unmodifiable(_sentBatches.map(Uint8List.fromList));

  /// 已成功发送操作的结果列表。
  List<SendResult> get sendResults =>
      List<SendResult>.unmodifiable(_sendResults);

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected) {
      throw _exception(TransportErrorCode.invalidState, '仅断开状态可以打开传输');
    }

    _status = TransportStatus.connecting;
    final failure = openError;
    if (failure != null) {
      _status = TransportStatus.error;
      _events.add(TransportErrorEvent(failure));
      throw TransportException(failure);
    }

    _status = TransportStatus.connected;
    _signals = SerialSignalState(
      dtr: _config.initialDtr,
      rts: _config.initialRts,
    );
    _events
      ..add(TransportConnectedEvent())
      ..add(TransportSignalChangedEvent(_signals));
  }

  @override
  Future<void> close() async {
    _ensureUsable();
    if (_status == TransportStatus.disconnected) {
      return;
    }

    _status = TransportStatus.disconnecting;
    _status = TransportStatus.disconnected;
    _signals = const SerialSignalState();
    _events.add(TransportDisconnectedEvent());
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    _ensureUsable();
    if (_status != TransportStatus.connected) {
      throw _exception(TransportErrorCode.disconnected, '传输尚未连接，不能发送数据');
    }

    final failure = sendError;
    if (failure != null) {
      _events.add(TransportErrorEvent(failure));
      throw TransportException(failure);
    }

    final delay = sendDelay;
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    final acceptedLength = maxSendChunk == null
        ? bytes.length
        : (bytes.length < maxSendChunk! ? bytes.length : maxSendChunk!);
    if (acceptedLength <= 0 || acceptedLength > bytes.length) {
      throw StateError('maxSendChunk 必须为正数');
    }
    final batch = Uint8List.fromList(bytes.sublist(0, acceptedLength));
    final completedAt = DateTime.now();
    final result = SendResult(
      requestedLength: bytes.length,
      acceptedLength: acceptedLength,
      completedAt: completedAt,
    );
    _sentBatches.add(batch);
    _sendResults.add(result);
    return result;
  }

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    _ensureUsable();
    return List<SerialPortInfo>.unmodifiable(_ports);
  }

  /// 替换端口列表并向订阅者广播热插拔快照。
  void setPorts(Iterable<SerialPortInfo> ports) {
    _ensureUsable();
    _ports = List<SerialPortInfo>.unmodifiable(ports);
    _portChanges.add(_ports);
  }

  @override
  Future<void> configure(SerialConfig config) async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected) {
      throw _exception(TransportErrorCode.configureWhileOpen, '串口配置只能在断开状态修改');
    }

    final failure = configureError;
    if (failure != null) {
      _events.add(TransportErrorEvent(failure));
      throw TransportException(failure);
    }
    _config = config;
  }

  @override
  Future<void> setDtr(bool enabled) async {
    _ensureConnected('设置 DTR');
    _signals = _copySignals(dtr: enabled);
    _events.add(TransportSignalChangedEvent(_signals));
  }

  @override
  Future<void> setRts(bool enabled) async {
    _ensureConnected('设置 RTS');
    _signals = _copySignals(rts: enabled);
    _events.add(TransportSignalChangedEvent(_signals));
  }

  /// 注入一组输入和控制信号状态。
  Future<void> injectSignals(SerialSignalState signals) async {
    _ensureConnected('注入信号状态');
    _signals = signals;
    _events.add(TransportSignalChangedEvent(_signals));
  }

  /// 注入一包接收数据；事件内部会再次复制字节。
  void injectData(Uint8List bytes) {
    _ensureConnected('注入接收数据');
    _events.add(TransportDataEvent(bytes));
  }

  /// 注入结构化错误事件，不自动改变当前连接状态。
  void injectError(TransportError error) {
    _ensureUsable();
    _events.add(TransportErrorEvent(error));
  }

  /// 模拟外部断开。
  void simulateDisconnect({String? reason}) {
    _ensureConnected('模拟断开');
    _status = TransportStatus.disconnected;
    _signals = const SerialSignalState();
    _events.add(TransportDisconnectedEvent(reason: reason));
  }

  /// 关闭连接并释放事件流；重复调用无副作用。
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await close();
    _disposed = true;
    await _events.close();
    await _portChanges.close();
  }

  void _ensureConnected(String operation) {
    _ensureUsable();
    if (_status != TransportStatus.connected) {
      throw _exception(TransportErrorCode.disconnected, '传输尚未连接，不能$operation');
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('FakeSerialTransport 已销毁');
    }
  }

  SerialSignalState _copySignals({
    bool? cts,
    bool? dsr,
    bool? dcd,
    bool? ri,
    bool? dtr,
    bool? rts,
  }) {
    return SerialSignalState(
      cts: cts ?? _signals.cts,
      dsr: dsr ?? _signals.dsr,
      dcd: dcd ?? _signals.dcd,
      ri: ri ?? _signals.ri,
      dtr: dtr ?? _signals.dtr,
      rts: rts ?? _signals.rts,
    );
  }

  TransportException _exception(TransportErrorCode code, String message) {
    return TransportException(TransportError(code: code, message: message));
  }
}
