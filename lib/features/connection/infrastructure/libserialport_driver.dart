import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'libserialport_mapping.dart';
import 'serial_read_pump.dart';

/// 真实串口后端的最小原生驱动契约。
abstract interface class LibSerialPortDriver {
  /// 枚举平台串口。
  Future<List<SerialPortInfo>> listPorts();

  /// 打开端口并应用配置。
  Future<LibSerialPortSession> open(SerialConfig config);
}

/// 一次已打开的原生串口会话。
abstract interface class LibSerialPortSession {
  /// 异步接收数据流。
  Stream<Uint8List> get data;

  /// 当前信号快照。
  SerialSignalState get signals;

  /// 执行一次非阻塞写入并返回接受字节数。
  int write(Uint8List bytes);

  /// 修改 DTR 输出。
  Future<void> setDtr(bool enabled);

  /// 修改 RTS 输出。
  Future<void> setRts(bool enabled);

  /// 释放原生会话；重复调用无副作用。
  Future<void> close();
}

/// 使用 flutter_libserialport 的原生驱动实现。
final class LibSerialPortNativeDriver implements LibSerialPortDriver {
  /// 创建原生驱动。
  const LibSerialPortNativeDriver();

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    final names = SerialPort.availablePorts.cast<String>();
    final result = <SerialPortInfo>[];
    for (final name in names) {
      SerialPort? port;
      try {
        port = SerialPort(name);
        final description = port.description?.trim();
        result.add(
          SerialPortInfo(
            systemPath: name,
            displayName: description?.isNotEmpty == true
                ? '$description ($name)'
                : name,
            isAvailable: true,
          ),
        );
      } finally {
        port?.dispose();
      }
    }
    return List<SerialPortInfo>.unmodifiable(result);
  }

  @override
  Future<LibSerialPortSession> open(SerialConfig config) async {
    final port = SerialPort(config.portName);
    try {
      if (!port.openReadWrite()) {
        throw SerialPort.lastError ??
            SerialPortError('无法打开串口 ${config.portName}');
      }
      // port.config 由端口持有并随端口释放；调用方不能再次 dispose。
      final serialConfig = port.config;
      serialConfig
        ..baudRate = config.baudRate
        ..bits = mapDataBits(config.dataBits)
        ..parity = mapParity(config.parity)
        ..stopBits = mapStopBits(config.stopBits);
      serialConfig.setFlowControl(mapFlowControl(config.flowControl));
      serialConfig.dtr = config.flowControl == SerialFlowControl.dtrDsr
          ? SerialPortDtr.flowControl
          : config.initialDtr
          ? SerialPortDtr.on
          : SerialPortDtr.off;
      serialConfig.rts = config.flowControl == SerialFlowControl.rtsCts
          ? SerialPortRts.flowControl
          : config.initialRts
          ? SerialPortRts.on
          : SerialPortRts.off;
      port.config = serialConfig;

      return _NativeSerialPortSession(
        port: port,
        dtr: config.initialDtr,
        rts: config.initialRts,
      );
    } catch (_) {
      try {
        if (port.isOpen) {
          port.close();
        }
      } finally {
        port.dispose();
      }
      rethrow;
    }
  }
}

class _NativeSerialPortSession implements LibSerialPortSession {
  _NativeSerialPortSession({
    required this._port,
    required this._dtr,
    required this._rts,
  });

  final SerialPort _port;
  // 读取与释放在同一 isolate 执行，避免插件读取 isolate 尚在 FFI 调用时释放端口。
  late final SerialReadPump _reader = SerialReadPump(
    bytesAvailable: () => _port.bytesAvailable,
    read: (count) => _port.read(count),
    readError: () => SerialPort.lastError ?? const SerialPortError('串口读取失败'),
  );
  bool _dtr;
  bool _rts;
  bool _closed = false;

  @override
  Stream<Uint8List> get data => _reader.stream;

  @override
  SerialSignalState get signals {
    final mask = _port.signals;
    return SerialSignalState(
      cts: (mask & SerialPortSignal.cts) != 0,
      dsr: (mask & SerialPortSignal.dsr) != 0,
      dcd: (mask & SerialPortSignal.dcd) != 0,
      ri: (mask & SerialPortSignal.ri) != 0,
      dtr: _dtr,
      rts: _rts,
    );
  }

  @override
  int write(Uint8List bytes) => _port.write(bytes);

  @override
  Future<void> setDtr(bool enabled) async {
    final config = _port.config;
    final previous = config.dtr;
    config.dtr = enabled ? SerialPortDtr.on : SerialPortDtr.off;
    try {
      _port.config = config;
    } catch (_) {
      // 缓存与端口共用对象，失败目标不能在下次修改 RTS 时被隐式重放。
      config.dtr = previous;
      rethrow;
    }
    _dtr = enabled;
  }

  @override
  Future<void> setRts(bool enabled) async {
    final config = _port.config;
    final previous = config.rts;
    config.rts = enabled ? SerialPortRts.on : SerialPortRts.off;
    try {
      _port.config = config;
    } catch (_) {
      config.rts = previous;
      rethrow;
    }
    _rts = enabled;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _reader.close();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      if (_port.isOpen) {
        _port.close();
      }
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    } finally {
      try {
        _port.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        firstError,
        firstStackTrace ?? StackTrace.current,
      );
    }
  }
}
