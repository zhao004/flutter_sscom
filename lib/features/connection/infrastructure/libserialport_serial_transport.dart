import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'libserialport_driver.dart';
import 'libserialport_mapping.dart';

/// 基于 flutter_libserialport 的隔离串口实现。
///
/// 端口和信号仅在启动或用户主动刷新时枚举，避免后台轮询触发 Windows
/// 热插拔风险。会话关闭等待在途操作结束，再释放原生资源。
final class LibSerialPortSerialTransport implements SerialTransport {
  /// 创建真实串口传输。
  LibSerialPortSerialTransport({
    SerialConfig initialConfig = const SerialConfig(
      portName: '',
      baudRate: 115200,
    ),
    this.driver = const LibSerialPortNativeDriver(),
  }) : _config = initialConfig;

  /// 可注入的原生驱动。
  final LibSerialPortDriver driver;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast(sync: true);
  final StreamController<List<SerialPortInfo>> _portChanges =
      StreamController<List<SerialPortInfo>>.broadcast(sync: true);

  SerialConfig _config;
  LibSerialPortSession? _session;
  StreamSubscription<Uint8List>? _readSubscription;
  TransportStatus _status = TransportStatus.disconnected;
  SerialSignalState _signals = const SerialSignalState();
  bool _disposed = false;
  bool _disposing = false;
  Future<void>? _openFuture;
  Future<SendResult>? _sendFuture;
  Future<void>? _closeFuture;
  Future<void>? _disposeFuture;
  final Set<Future<void>> _signalOperations = {};

  /// 连续无写入进展的最长等待时间。
  static const _writeStallTimeout = Duration(seconds: 5);
  static const _writeRetryInterval = Duration(milliseconds: 1);

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  TransportStatus get status => _status;

  @override
  Stream<List<SerialPortInfo>> get portChanges => _portChanges.stream;

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    _ensureUsable();
    try {
      final ports = await driver.listPorts();
      final snapshot = List<SerialPortInfo>.unmodifiable(ports);
      _portChanges.add(snapshot);
      return snapshot;
    } catch (error, stackTrace) {
      final mapped = _mapError(error, fallback: TransportErrorCode.unknown);
      _events.add(TransportErrorEvent(mapped));
      Error.throwWithStackTrace(TransportException(mapped), stackTrace);
    }
  }

  @override
  Future<void> configure(SerialConfig config) async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected) {
      throw _exception(TransportErrorCode.configureWhileOpen, '串口配置只能在断开状态修改');
    }
    if (config.baudRate <= 0) {
      throw _exception(TransportErrorCode.invalidState, '波特率必须大于零');
    }
    try {
      mapStopBits(config.stopBits);
      _config = config;
    } on UnsupportedError catch (error, stackTrace) {
      final mapped = TransportError(
        code: TransportErrorCode.unsupported,
        message: error.message ?? error.toString(),
        cause: error,
      );
      _events.add(TransportErrorEvent(mapped));
      Error.throwWithStackTrace(TransportException(mapped), stackTrace);
    }
  }

  @override
  Future<void> open() async {
    _ensureUsable();
    if (_status != TransportStatus.disconnected || _closeFuture != null) {
      throw _exception(TransportErrorCode.invalidState, '仅断开状态可以打开串口');
    }
    if (_config.portName.trim().isEmpty) {
      throw _exception(TransportErrorCode.portNotFound, '未选择串口');
    }
    _status = TransportStatus.connecting;
    final operation = _openSession();
    _openFuture = operation;
    try {
      await operation;
    } finally {
      _openFuture = null;
    }
  }

  Future<void> _openSession() async {
    try {
      final session = await driver.open(_config);
      if (_status != TransportStatus.connecting || _disposing) {
        await session.close();
        throw _exception(TransportErrorCode.disconnected, '串口打开已取消');
      }
      _session = session;
      _readSubscription = session.data.listen(
        (data) => _handleData(session, data),
        onError: (Object error, StackTrace stackTrace) {
          unawaited(_handleReadFailure(session, error));
        },
        onDone: () {
          unawaited(_handleReadFailure(session, const OSError('串口读取流意外结束')));
        },
      );
      _signals = session.signals;
      _status = TransportStatus.connected;
      _events
        ..add(TransportConnectedEvent())
        ..add(TransportSignalChangedEvent(_signals));
    } catch (error, stackTrace) {
      final mapped = _mapError(error, fallback: TransportErrorCode.unknown);
      if (_status == TransportStatus.connecting) {
        _status = TransportStatus.error;
        _events.add(TransportErrorEvent(mapped));
      }
      try {
        await _releaseSession();
      } catch (_) {
        // 打开失败保留最初的错误，释放失败不覆盖根因。
      }
      Error.throwWithStackTrace(TransportException(mapped), stackTrace);
    }
  }

  @override
  Future<SendResult> send(Uint8List bytes) async {
    _ensureUsable();
    final session = _session;
    if (_status != TransportStatus.connected || session == null) {
      throw _exception(TransportErrorCode.disconnected, '串口尚未连接，不能发送数据');
    }
    if (_sendFuture != null) {
      throw _exception(TransportErrorCode.invalidState, '串口正在发送数据');
    }
    // 先登记在途操作，随后写入；同步的读流错误也能等待本次发送结束。
    final payload = Uint8List.fromList(bytes);
    final operation = Future<SendResult>.microtask(
      () => _write(session, payload),
    );
    _sendFuture = operation;
    try {
      return await operation;
    } finally {
      _sendFuture = null;
    }
  }

  Future<SendResult> _write(
    LibSerialPortSession session,
    Uint8List payload,
  ) async {
    var accepted = 0;
    var stalled = false;
    Timer watchdog() => Timer(_writeStallTimeout, () => stalled = true);
    var timer = watchdog();
    try {
      while (accepted < payload.length) {
        if (_status != TransportStatus.connected ||
            !identical(_session, session)) {
          throw _exception(TransportErrorCode.disconnected, '串口已关闭，发送中止');
        }
        if (stalled) {
          throw const OSError('串口写入连续 5 秒没有进展');
        }
        final remaining = Uint8List.sublistView(payload, accepted);
        final written = session.write(remaining);
        if (written < 0 || written > remaining.length) {
          throw const OSError('串口返回无效的写入长度');
        }
        if (written > 0) {
          accepted += written;
          timer.cancel();
          timer = watchdog();
        }
        if (accepted < payload.length) {
          await Future<void>.delayed(
            written == 0 ? _writeRetryInterval : Duration.zero,
          );
        }
      }
      return SendResult(
        requestedLength: payload.length,
        acceptedLength: accepted,
        completedAt: DateTime.now(),
      );
    } catch (error, stackTrace) {
      final mapped = _mapError(error, fallback: TransportErrorCode.writeFailed);
      if (_status == TransportStatus.connected) {
        _events.add(TransportErrorEvent(mapped));
      }
      Error.throwWithStackTrace(TransportException(mapped), stackTrace);
    } finally {
      timer.cancel();
    }
  }

  @override
  Future<void> setDtr(bool enabled) async {
    _ensureUsable();
    _ensurePinControlAllowed(SerialFlowControl.dtrDsr, 'DTR');
    final session = _session;
    if (_status != TransportStatus.connected || session == null) {
      throw _exception(TransportErrorCode.disconnected, '串口尚未连接，不能设置 DTR');
    }
    await _setSignal(session, () => session.setDtr(enabled));
  }

  @override
  Future<void> setRts(bool enabled) async {
    _ensureUsable();
    _ensurePinControlAllowed(SerialFlowControl.rtsCts, 'RTS');
    final session = _session;
    if (_status != TransportStatus.connected || session == null) {
      throw _exception(TransportErrorCode.disconnected, '串口尚未连接，不能设置 RTS');
    }
    await _setSignal(session, () => session.setRts(enabled));
  }

  Future<void> _setSignal(
    LibSerialPortSession session,
    Future<void> Function() action,
  ) async {
    final operation = Future<void>.microtask(() async {
      try {
        if (!_isCurrentSession(session)) {
          throw _exception(TransportErrorCode.disconnected, '串口已关闭，信号操作中止');
        }
        await action();
        if (!_isCurrentSession(session)) {
          throw _exception(TransportErrorCode.disconnected, '串口已关闭，信号操作中止');
        }
        _signals = session.signals;
        _events.add(TransportSignalChangedEvent(_signals));
      } catch (error, stackTrace) {
        final mapped = _mapError(
          error,
          fallback: TransportErrorCode.writeFailed,
        );
        if (_isCurrentSession(session)) {
          _events.add(TransportErrorEvent(mapped));
        }
        Error.throwWithStackTrace(TransportException(mapped), stackTrace);
      }
    });
    _signalOperations.add(operation);
    try {
      await operation;
    } finally {
      _signalOperations.remove(operation);
    }
  }

  bool _isCurrentSession(LibSerialPortSession session) =>
      !_disposed &&
      !_disposing &&
      _status == TransportStatus.connected &&
      identical(_session, session);

  @override
  Future<void> close() {
    _ensureUsable();
    return _beginClose();
  }

  Future<void> _beginClose({String? reason}) {
    final ongoing = _closeFuture;
    if (ongoing != null) return ongoing;
    if (_status == TransportStatus.disconnected && _session == null) {
      return Future<void>.value();
    }
    _status = TransportStatus.disconnecting;
    final operation = _closeSession(reason: reason);
    _closeFuture = operation;
    return operation;
  }

  Future<void> _closeSession({String? reason}) async {
    try {
      try {
        await _openFuture;
      } catch (_) {
        // 取消打开时仍须继续释放已取得的资源。
      }
      try {
        await _sendFuture;
      } catch (_) {
        // 关闭使发送中止，其错误由发送调用方处理。
      }
      try {
        await Future.wait(_signalOperations.toList());
      } catch (_) {
        // 信号操作完成前保持原生会话存活，错误由各调用方处理。
      }
      await _releaseSession();
    } catch (error, stackTrace) {
      final mapped = _mapError(error, fallback: TransportErrorCode.unknown);
      _events.add(TransportErrorEvent(mapped));
      Error.throwWithStackTrace(TransportException(mapped), stackTrace);
    } finally {
      _status = TransportStatus.disconnected;
      _signals = const SerialSignalState();
      _closeFuture = null;
      _events.add(TransportDisconnectedEvent(reason: reason));
    }
  }

  @override
  Future<void> dispose() {
    final ongoing = _disposeFuture;
    if (ongoing != null) return ongoing;
    _disposing = true;
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    try {
      await _beginClose();
    } finally {
      _disposed = true;
      await _events.close();
      await _portChanges.close();
    }
  }

  void _handleData(LibSerialPortSession session, Uint8List data) {
    if (_disposed ||
        _status != TransportStatus.connected ||
        !identical(_session, session)) {
      return;
    }
    _events.add(TransportDataEvent(data));
  }

  Future<void> _handleReadFailure(
    LibSerialPortSession session,
    Object error,
  ) async {
    if (_disposed ||
        _status != TransportStatus.connected ||
        !identical(_session, session)) {
      return;
    }
    final mapped = _mapError(error, fallback: TransportErrorCode.readFailed);
    _events.add(TransportErrorEvent(mapped));
    try {
      await _beginClose(reason: mapped.message);
    } catch (_) {
      // 异步读回调没有等待者；关闭已发布释放错误，避免产生未处理异常。
    }
  }

  Future<void> _releaseSession() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    final subscription = _readSubscription;
    _readSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }

    final session = _session;
    _session = null;
    if (session != null) {
      try {
        await session.close();
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

  void _ensurePinControlAllowed(SerialFlowControl conflictingFlow, String pin) {
    if (_config.flowControl == conflictingFlow) {
      throw _exception(TransportErrorCode.unsupported, '$pin 已用于流控，不能手动切换');
    }
  }

  TransportError _mapError(
    Object error, {
    required TransportErrorCode fallback,
  }) {
    if (error is TransportException) {
      return error.error;
    }
    final code = error is OSError
        ? classifyOsErrorCode(error.errorCode, fallback: fallback)
        : fallback;
    return TransportError(
      code: code,
      message: error is OSError && error.message.isNotEmpty
          ? error.message
          : error.toString(),
      cause: error,
    );
  }

  TransportException _exception(TransportErrorCode code, String message) {
    return TransportException(TransportError(code: code, message: message));
  }

  void _ensureUsable() {
    if (_disposed || _disposing) {
      throw StateError('LibSerialPortSerialTransport 已销毁');
    }
  }
}
