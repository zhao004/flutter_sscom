import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 内置回环模拟串口，供无硬件环境演示和开发使用。
///
/// 发送数据在固定延迟后原样回显。端口名使用 `SIM-*` 前缀，避免与真实
/// Windows COM 端口混淆。
final class SimulatedSerialTransport implements SerialTransport {
  /// 创建模拟串口传输。
  SimulatedSerialTransport({
    SerialConfig initialConfig = const SerialConfig(
      portName: 'SIM-A',
      baudRate: 115200,
    ),
    this.echoDelay = const Duration(milliseconds: 25),
  }) : _config = initialConfig;

  static const List<SerialPortInfo> _availablePorts = <SerialPortInfo>[
    SerialPortInfo(
      systemPath: 'SIM-A',
      displayName: '模拟设备 A（回环）',
      isAvailable: true,
    ),
    SerialPortInfo(
      systemPath: 'SIM-B',
      displayName: '模拟设备 B（回环）',
      isAvailable: true,
    ),
  ];

  final Duration echoDelay;
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);
  final StreamController<List<SerialPortInfo>> _portChanges =
      StreamController<List<SerialPortInfo>>.broadcast(sync: true);
  final Set<Timer> _echoTimers = <Timer>{};

  SerialConfig _config;
  TransportStatus _status = TransportStatus.disconnected;
  SerialSignalState _signals = const SerialSignalState();
  bool _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Stream<List<SerialPortInfo>> get portChanges => _portChanges.stream;

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected) {
      throw _exception(TransportErrorCode.invalidState, '仅断开状态可以打开模拟串口');
    }
    _status = TransportStatus.connecting;
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
    _cancelEchoTimers();
    _status = TransportStatus.disconnecting;
    _status = TransportStatus.disconnected;
    _signals = const SerialSignalState();
    _events.add(TransportDisconnectedEvent());
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    _ensureUsable();
    if (_status != TransportStatus.connected) {
      throw _exception(TransportErrorCode.disconnected, '模拟串口尚未连接');
    }

    final payload = Uint8List.fromList(bytes);
    late final Timer timer;
    timer = Timer(echoDelay, () {
      _echoTimers.remove(timer);
      if (_status == TransportStatus.connected) {
        _events.add(TransportDataEvent(payload));
      }
    });
    _echoTimers.add(timer);
    return SendResult(
      requestedLength: bytes.length,
      acceptedLength: bytes.length,
      completedAt: DateTime.now(),
    );
  }

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    _ensureUsable();
    const ports = _availablePorts;
    _portChanges.add(ports);
    return ports;
  }

  @override
  Future<void> configure(SerialConfig config) async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected) {
      throw _exception(
        TransportErrorCode.configureWhileOpen,
        '模拟串口配置只能在断开状态修改',
      );
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
      throw _exception(
        TransportErrorCode.disconnected,
        '模拟串口尚未连接，不能$operation',
      );
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('SimulatedSerialTransport 已销毁');
    }
  }

  void _cancelEchoTimers() {
    for (final timer in _echoTimers) {
      timer.cancel();
    }
    _echoTimers.clear();
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
