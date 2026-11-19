import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sscom/core/buffers/buffers.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:signals/signals.dart';

import 'terminal_projection.dart';
import 'terminal_view_state.dart';

/// 串口与网络工作区控制器。
///
/// 控制器持有长期存在的串口传输，并按当前模式创建 TCP/UDP 传输。所有模式
/// 共享同一终端投影、发送管线和接收数据流；页面只读取 [state]，不直接访问
/// 传输实现。
final class TerminalController {
  /// 创建工作区控制器。
  TerminalController({
    required SerialTransport transport,
    required this.textEncoder,
    required String backendLabel,
    bool isSimulatedBackend = false,
    this.networkTransportFactory,
    BufferPolicy? bufferPolicy,
    DateTime Function()? now,
    TransportMode initialTransportMode = TransportMode.serial,
    NetworkSafetyMode initialNetworkSafetyMode = NetworkSafetyMode.safe,
    String initialRemoteHost = '',
    int initialRemotePort = 5001,
    String initialBindAddress = '127.0.0.1',
    int initialLocalPort = 5001,
    bool initialFollowRemoteEndpoint = true,
    TerminalDisplayMode initialDisplayMode = TerminalDisplayMode.text,
    bool initialShowTimestamp = false,
    bool initialAutoScroll = true,
    SendInputMode initialSendMode = SendInputMode.ansiText,
    LegacyChecksumMode initialSendChecksumMode = LegacyChecksumMode.none,
    int initialSendChecksumStartByte = 1,
    int initialSendChecksumTrailingByteCount = 0,
    bool initialSendAppendCrLf = false,
    String initialTextDraft = '',
    String initialHexDraft = '',
    String? initialNotice,
    SerialConfig initialConfig = const SerialConfig(
      portName: '',
      baudRate: 115200,
    ),
  }) : _serialTransport = transport,
       _serialBackendLabel = backendLabel,
       _serialIsSimulated = isSimulatedBackend,
       _bufferPolicy = bufferPolicy ?? BufferPolicy(),
       _now = now ?? DateTime.now {
    _state = signal<TerminalViewState>(
      TerminalViewState(
        status: initialTransportMode == TransportMode.serial
            ? transport.status
            : TransportStatus.disconnected,
        ports: const <SerialPortInfo>[],
        config: initialConfig,
        signals: const SerialSignalState(),
        lines: const <TerminalLine>[],
        backendLabel: _backendLabelForMode(initialTransportMode),
        isSimulatedBackend:
            isSimulatedBackend && initialTransportMode == TransportMode.serial,
        transportMode: initialTransportMode,
        networkSafetyMode: initialNetworkSafetyMode,
        remoteHost: initialRemoteHost,
        remotePort: initialRemotePort,
        bindAddress: initialBindAddress,
        localPort: initialLocalPort,
        followRemoteEndpoint: initialFollowRemoteEndpoint,
        displayMode: initialDisplayMode,
        showTimestamp: initialShowTimestamp,
        autoScroll: initialAutoScroll,
        sendMode: initialSendMode,
        sendChecksumMode: initialSendChecksumMode,
        sendChecksumStartByte: initialSendChecksumStartByte,
        sendChecksumTrailingByteCount: initialSendChecksumTrailingByteCount,
        sendAppendCrLf: initialSendAppendCrLf,
        textDraft: initialTextDraft,
        hexDraft: initialHexDraft,
        noticeMessage: initialNotice,
      ),
    );
    _rawBuffer = ByteRingBuffer(_bufferPolicy.maxRawBytes);
    _projection = TerminalProjection(
      maxLines: _bufferPolicy.maxDisplayLines,
      hexBytesPerLine: _bufferPolicy.hexBytesPerLine,
    );
    _scheduler = ByteBatchScheduler(
      flushInterval: _bufferPolicy.flushInterval,
      maxPendingBytes: _bufferPolicy.maxPendingBytes,
      onBatch: _handleBatch,
    );
    _readonlyState = _state.readonly();
  }

  final SerialTransport _serialTransport;

  /// 创建 TCP/UDP 传输的工厂；为 `null` 时网络模式会明确报错。
  final TransportFactory? networkTransportFactory;
  final String _serialBackendLabel;
  final bool _serialIsSimulated;
  final TextByteEncoder textEncoder;
  final BufferPolicy _bufferPolicy;
  final DateTime Function() _now;
  late final Signal<TerminalViewState> _state;
  final StreamController<Uint8List> _receivedData =
      StreamController<Uint8List>.broadcast(sync: true);

  late final ReadonlySignal<TerminalViewState> _readonlyState;
  late final ByteRingBuffer _rawBuffer;
  late final TerminalProjection _projection;
  late final ByteBatchScheduler _scheduler;

  Transport? _networkTransport;
  Future<void>? _networkDisposeFuture;
  StreamSubscription<TransportEvent>? _eventSubscription;
  Transport? _eventSubscriptionOwner;
  StreamSubscription<List<SerialPortInfo>>? _portSubscription;
  bool _initialized = false;
  bool _disposed = false;
  bool _operationInProgress = false;
  Object? _exclusiveSendOwner;
  int _receivedBytes = 0;
  int _sentBytes = 0;

  /// 只读表现层状态。
  ReadonlySignal<TerminalViewState> get state => _readonlyState;

  /// 原始接收数据广播。
  ///
  /// 该流只用于需要完整字节历史的独立消费者（例如接收日志）；终端显示仍由
  /// 有界投影负责。消费者不得修改收到的 [Uint8List]。
  Stream<Uint8List> get receivedData => _receivedData.stream;

  /// 开始监听传输事件并执行一次端口枚举。
  Future<void> initialize() async {
    _throwIfDisposed();
    if (_initialized) {
      return;
    }
    _initialized = true;
    _portSubscription = _serialTransport.portChanges.listen(
      _handlePortsChanged,
    );
    if (_state.value.transportMode == TransportMode.serial) {
      await _attachTransportEvents(_serialTransport);
    }
    await refreshPorts();
  }

  /// 刷新串口列表，并在允许配置时选择首个可用端口。
  Future<void> refreshPorts() async {
    _throwIfDisposed();
    if (_state.value.isRefreshingPorts || _operationInProgress) {
      return;
    }
    _state.value = _state.value.copyWith(
      isRefreshingPorts: true,
      errorMessage: null,
    );

    try {
      final ports = await _serialTransport.listPorts();
      final current = _state.value;
      final config = _withSelectedPort(current.config, ports);
      if (current.canConfigure &&
          current.transportMode == TransportMode.serial &&
          (config.portName != current.config.portName ||
              _serialTransport.status == TransportStatus.error)) {
        await _prepareSerialConfiguration(config);
      }
      _state.value = _state.value.copyWith(
        ports: ports,
        config: config,
        isRefreshingPorts: false,
      );
    } catch (error, stackTrace) {
      _setError(error, stackTrace: stackTrace, isRefreshingPorts: false);
    }
  }

  /// 修改串口配置；连接期间拒绝变更。
  Future<void> updateConfig(SerialConfig config) async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null) {
      _setErrorMessage('ISP 独占串口期间不能修改串口参数');
      return;
    }
    if (_state.value.transportMode != TransportMode.serial) {
      _setErrorMessage('当前不是串口模式');
      return;
    }
    if (!_state.value.canConfigure || _operationInProgress) {
      _setErrorMessage('连接期间不能修改串口参数');
      return;
    }

    _operationInProgress = true;
    try {
      await _prepareSerialConfiguration(config);
      _state.value = _state.value.copyWith(
        config: config,
        status: _serialTransport.status,
        errorMessage: null,
      );
    } catch (error, stackTrace) {
      _setError(error, stackTrace: stackTrace);
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> _prepareSerialConfiguration(SerialConfig config) async {
    if (_serialTransport.status == TransportStatus.error) {
      await _serialTransport.close();
    }
    await _serialTransport.configure(config);
  }

  /// 切换串口、TCP 客户端、TCP 服务端或 UDP。
  ///
  /// 切换前会关闭并释放当前活动连接；新模式保持未连接，由用户显式打开，避免
  /// 配置修改后立即访问网络或设备。
  Future<void> switchTransportMode(TransportMode mode) async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null) {
      _setErrorMessage('ISP 独占串口期间不能切换连接模式');
      return;
    }
    final current = _state.value;
    if (current.transportMode == mode) {
      return;
    }
    if (_operationInProgress || current.isSending) {
      _setErrorMessage('当前正在传输数据，暂时不能切换连接模式');
      return;
    }

    _operationInProgress = true;
    try {
      await _releaseActiveTransportForModeChange();
      final nextLabel = _backendLabelForMode(mode);
      _state.value = _state.value.copyWith(
        transportMode: mode,
        status: mode == TransportMode.serial
            ? _serialTransport.status
            : TransportStatus.disconnected,
        signals: const SerialSignalState(),
        backendLabel: nextLabel,
        isSimulatedBackend: mode == TransportMode.serial && _serialIsSimulated,
        connectionDetail: null,
        errorMessage: null,
        isOpening: false,
      );
      if (mode == TransportMode.serial) {
        await _attachTransportEvents(_serialTransport);
      }
    } catch (error, stackTrace) {
      _setError(error, stackTrace: stackTrace, isOpening: false);
    } finally {
      _operationInProgress = false;
    }
  }

  /// 修改网络目标、监听地址或安全模式。
  ///
  /// 该操作只更新下一次打开所用的配置；活动连接期间拒绝修改。
  void updateNetworkSettings({
    NetworkSafetyMode? safetyMode,
    String? remoteHost,
    int? remotePort,
    String? bindAddress,
    int? localPort,
    bool? followRemoteEndpoint,
  }) {
    _throwIfDisposed();
    if (!_state.value.canConfigure) {
      _setErrorMessage('连接期间不能修改网络参数');
      return;
    }
    if (remotePort != null && (remotePort < 1 || remotePort > 65535)) {
      _setErrorMessage('远端端口必须在 1 到 65535 之间');
      return;
    }
    if (localPort != null && (localPort < 1 || localPort > 65535)) {
      _setErrorMessage('本地端口必须在 1 到 65535 之间');
      return;
    }

    _state.value = _state.value.copyWith(
      networkSafetyMode: safetyMode,
      remoteHost: remoteHost?.trim(),
      remotePort: remotePort,
      bindAddress: bindAddress?.trim(),
      localPort: localPort,
      followRemoteEndpoint: followRemoteEndpoint,
      connectionDetail: null,
      errorMessage: null,
    );
  }

  /// 申请独占发送权。
  ///
  /// ISP 等严格请求/响应流程使用该机制阻止手动发送、文件发送和多字符串发送
  /// 在协议帧之间插入数据。调用方必须在结束或失败后释放同一 owner。
  bool acquireExclusiveSend(Object owner) {
    _throwIfDisposed();
    final existing = _exclusiveSendOwner;
    if (existing != null && !identical(existing, owner)) {
      _setErrorMessage('串口正被其他独占操作占用');
      return false;
    }
    if (_state.value.isSending) {
      _setErrorMessage('当前正在发送数据，不能进入 ISP');
      return false;
    }
    if (_state.value.transportMode != TransportMode.serial ||
        !_state.value.isConnected) {
      _setErrorMessage('ISP 需要已连接的串口');
      return false;
    }
    _exclusiveSendOwner = owner;
    _state.value = _state.value.copyWith(
      isExclusiveSend: true,
      errorMessage: null,
    );
    return true;
  }

  /// 释放独占发送权；owner 不匹配时无副作用。
  void releaseExclusiveSend(Object owner) {
    if (_disposed || !identical(_exclusiveSendOwner, owner)) {
      return;
    }
    _exclusiveSendOwner = null;
    _state.value = _state.value.copyWith(isExclusiveSend: false);
  }

  /// 打开当前模式的连接或监听。
  Future<void> open() async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null) {
      _setErrorMessage('ISP 独占串口期间不能重新打开连接');
      return;
    }
    final current = _state.value;
    if (_operationInProgress ||
        current.isTransportActive ||
        current.isOpening) {
      return;
    }
    if (current.transportMode == TransportMode.serial &&
        current.config.portName.isEmpty) {
      _setErrorMessage('请先选择串口');
      return;
    }
    if (current.isNetworkMode) {
      final validationError = _validateNetworkSettings(current);
      if (validationError != null) {
        _setErrorMessage(validationError);
        return;
      }
    }

    _operationInProgress = true;
    _state.value = current.copyWith(
      status: TransportStatus.connecting,
      isOpening: true,
      errorMessage: null,
      connectionDetail: _openingDetail(current),
    );
    try {
      if (current.transportMode == TransportMode.serial) {
        await _prepareSerialConfiguration(_state.value.config);
        await _serialTransport.open();
        _state.value = _state.value.copyWith(
          status: _serialTransport.status,
          isOpening: false,
          errorMessage: null,
        );
      } else {
        final transport = await _createNetworkTransport(current);
        await _attachTransportEvents(transport);
        await transport.open();
        _state.value = _state.value.copyWith(
          status: transport.status,
          isOpening: false,
          errorMessage: null,
        );
      }
    } catch (error, stackTrace) {
      if (current.isNetworkMode) {
        await _disposeNetworkTransport();
      }
      _setError(
        error,
        stackTrace: stackTrace,
        status: current.isNetworkMode
            ? TransportStatus.error
            : _serialTransport.status,
        isOpening: false,
      );
    } finally {
      _operationInProgress = false;
    }
  }

  /// 关闭当前连接或监听；断开状态重复调用无副作用。
  Future<void> close() async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null) {
      _setErrorMessage('请先结束 ISP 会话再关闭串口');
      return;
    }
    final current = _state.value;
    final hasNetworkResource =
        current.isNetworkMode && _networkTransport != null;
    if (_operationInProgress ||
        current.status == TransportStatus.disconnecting ||
        (!current.isTransportActive && !hasNetworkResource)) {
      return;
    }
    _operationInProgress = true;
    _state.value = current.copyWith(
      status: TransportStatus.disconnecting,
      isOpening: false,
    );
    try {
      if (current.transportMode == TransportMode.serial) {
        await _serialTransport.close();
        _state.value = _state.value.copyWith(
          status: _serialTransport.status,
          isOpening: false,
          errorMessage: null,
          connectionDetail: null,
        );
      } else {
        await _closeAndDisposeNetworkTransport();
        _state.value = _state.value.copyWith(
          status: TransportStatus.disconnected,
          isOpening: false,
          errorMessage: null,
          connectionDetail: null,
        );
      }
    } catch (error, stackTrace) {
      if (current.isNetworkMode) {
        await _disposeNetworkTransport();
      }
      _setError(
        error,
        stackTrace: stackTrace,
        status: current.isNetworkMode
            ? TransportStatus.error
            : _serialTransport.status,
        isOpening: false,
      );
    } finally {
      _operationInProgress = false;
    }
  }

  /// 设置 DTR 输出状态。
  Future<void> setDtr(bool enabled) async {
    _throwIfDisposed();
    if (_state.value.transportMode != TransportMode.serial) {
      _setErrorMessage('DTR 仅在串口模式可用');
      return;
    }
    try {
      await _serialTransport.setDtr(enabled);
    } catch (error, stackTrace) {
      _setError(error, stackTrace: stackTrace);
    }
  }

  /// 设置 RTS 输出状态。
  Future<void> setRts(bool enabled) async {
    _throwIfDisposed();
    if (_state.value.transportMode != TransportMode.serial) {
      _setErrorMessage('RTS 仅在串口模式可用');
      return;
    }
    try {
      await _serialTransport.setRts(enabled);
    } catch (error, stackTrace) {
      _setError(error, stackTrace: stackTrace);
    }
  }

  /// 编码、追加校验并发送数据。
  ///
  /// 返回 `null` 表示输入、连接或传输失败；具体原因写入 [state]。
  Future<SendResult?> send(SendRequest request) {
    final state = _state.value;
    return sendFormatted(
      input: request.input,
      mode: state.sendMode,
      appendCrLf: state.sendAppendCrLf,
    );
  }

  /// 按指定文本/HEX 模式编码并发送数据。
  ///
  /// 多字符串发送使用此入口覆盖当前输入模式，同时沿用当前校验配置。
  Future<SendResult?> sendFormatted({
    required String input,
    required SendInputMode mode,
    required bool appendCrLf,
  }) async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null) {
      _setErrorMessage('串口正被 ISP 等独占流程使用');
      return null;
    }
    if (!_state.value.isConnected) {
      _setErrorMessage('${_modeLabel(_state.value.transportMode)}未连接，不能发送数据');
      return null;
    }
    if (_state.value.isSending) {
      return null;
    }

    try {
      final encoded = SendPayloadCodec.encode(
        input: input,
        mode: mode,
        textEncoder: textEncoder,
        appendCrLf: appendCrLf,
      );
      if (encoded.isEmpty) {
        throw const FormatException('发送内容为空');
      }
      final payload = ChecksumInjector.apply(
        encoded,
        ChecksumSpec(
          mode: _state.value.sendChecksumMode,
          startByte: _state.value.sendChecksumStartByte,
          trailingByteCount: _state.value.sendChecksumTrailingByteCount,
        ),
      );
      return await sendBytes(payload);
    } catch (error, stackTrace) {
      _setError(
        error,
        stackTrace: stackTrace,
        status: _activeTransportStatus(),
        isSending: false,
      );
      return null;
    }
  }

  /// 直接发送原始字节，不经过文本/HEX 编码和校验追加。
  ///
  /// 文件发送等二进制场景使用此入口。传输层返回短写时会继续发送剩余字节，
  /// 从而确保最终 [SendResult] 的接受长度与实际发送进度一致。
  Future<SendResult?> sendBytes(
    Uint8List bytes, {
    Object? exclusiveOwner,
  }) async {
    _throwIfDisposed();
    if (_exclusiveSendOwner != null &&
        !identical(_exclusiveSendOwner, exclusiveOwner)) {
      _setErrorMessage('串口正被 ISP 等独占流程使用');
      return null;
    }
    if (!_state.value.isConnected) {
      _setErrorMessage('${_modeLabel(_state.value.transportMode)}未连接，不能发送数据');
      return null;
    }
    if (_state.value.isSending) {
      return null;
    }
    if (bytes.isEmpty) {
      _setErrorMessage('发送内容为空');
      return null;
    }

    _state.value = _state.value.copyWith(isSending: true, errorMessage: null);
    var acceptedLength = 0;
    try {
      final transport = _requireActiveTransport();
      while (acceptedLength < bytes.length) {
        final result = await transport.send(
          Uint8List.sublistView(bytes, acceptedLength),
        );
        final remaining = bytes.length - acceptedLength;
        if (result.acceptedLength <= 0 || result.acceptedLength > remaining) {
          throw StateError('传输层返回了无效的发送长度');
        }
        acceptedLength += result.acceptedLength;
      }
      _sentBytes += acceptedLength;
      _state.value = _state.value.copyWith(
        sentBytes: _sentBytes,
        isSending: false,
        errorMessage: null,
      );
      return SendResult(
        requestedLength: bytes.length,
        acceptedLength: acceptedLength,
        completedAt: _now(),
      );
    } catch (error, stackTrace) {
      _sentBytes += acceptedLength;
      _state.value = _state.value.copyWith(
        sentBytes: _sentBytes,
        isSending: false,
      );
      _setError(
        error,
        stackTrace: stackTrace,
        status: _activeTransportStatus(),
      );
      return null;
    }
  }

  /// 切换文本/HEX 接收视图。
  void setDisplayMode(TerminalDisplayMode mode) {
    _throwIfDisposed();
    if (_state.value.displayMode == mode) {
      return;
    }
    _state.value = _state.value.copyWith(
      displayMode: mode,
      lines: _projection.snapshot(mode),
      droppedLines: _projection.droppedLines(mode),
    );
  }

  /// 设置是否显示逐行时间戳。
  void setShowTimestamp(bool enabled) {
    _throwIfDisposed();
    _state.value = _state.value.copyWith(showTimestamp: enabled);
  }

  /// 设置是否自动滚动到最新接收行。
  void setAutoScroll(bool enabled) {
    _throwIfDisposed();
    _state.value = _state.value.copyWith(autoScroll: enabled);
  }

  /// 切换发送输入模式。
  void setSendMode(SendInputMode mode) {
    _throwIfDisposed();
    if (_state.value.sendMode == mode) {
      return;
    }
    _state.value = _state.value.copyWith(sendMode: mode);
  }

  /// 修改发送校验模式。
  void setSendChecksumMode(LegacyChecksumMode mode) {
    _throwIfDisposed();
    if (_state.value.sendChecksumMode == mode) {
      return;
    }
    _state.value = _state.value.copyWith(sendChecksumMode: mode);
  }

  /// 修改文本发送 CRLF 偏好。
  void setSendAppendCrLf(bool enabled) {
    _throwIfDisposed();
    _state.value = _state.value.copyWith(sendAppendCrLf: enabled);
  }

  /// 更新当前输入模式对应的发送草稿。
  void updateSendDraft(String value) {
    _throwIfDisposed();
    _state.value = switch (_state.value.sendMode) {
      SendInputMode.ansiText => _state.value.copyWith(textDraft: value),
      SendInputMode.hex => _state.value.copyWith(hexDraft: value),
    };
  }

  /// 显示非致命提示。
  void showNotice(String message) {
    _throwIfDisposed();
    _state.value = _state.value.copyWith(noticeMessage: message);
  }

  /// 关闭当前非致命提示。
  void dismissNotice() {
    _throwIfDisposed();
    _state.value = _state.value.copyWith(noticeMessage: null);
  }

  /// 清空接收显示和原始环形缓冲，但保留会话收发计数。
  void clearTerminal() {
    _throwIfDisposed();
    _scheduler.flushNow();
    _rawBuffer.clear();
    _projection.clear();
    _state.value = _state.value.copyWith(
      lines: const <TerminalLine>[],
      droppedBytes: 0,
      droppedLines: 0,
    );
  }

  /// 取消订阅并释放 transport、计时器和状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _cancelAllTransportEvents();
    await _portSubscription?.cancel();
    _portSubscription = null;
    await _disposeNetworkTransport();
    _scheduler.dispose();
    _projection.clear();
    await _serialTransport.dispose();
    // 广播流可能仍被外部功能控制器订阅；关闭通知不需要阻塞终端释放，否则
    // 组合容器按注册顺序销毁时可能形成等待环。
    unawaited(_receivedData.close());
    _state.dispose();
  }

  void _handleTransportEvent(TransportEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case TransportConnectedEvent():
        _state.value = _state.value.copyWith(
          status: TransportStatus.connected,
          isOpening: false,
          errorMessage: null,
          connectionDetail: event.detail,
        );
      case TransportListeningEvent():
        _state.value = _state.value.copyWith(
          status: TransportStatus.listening,
          isOpening: false,
          connectionDetail: event.detail,
        );
      case TransportDisconnectedEvent():
        _state.value = _state.value.copyWith(
          status: TransportStatus.disconnected,
          signals: const SerialSignalState(),
          isOpening: false,
          connectionDetail: null,
          errorMessage: event.reason,
        );
        if (_state.value.isNetworkMode) {
          unawaited(Future<void>.microtask(_disposeNetworkTransport));
        }
      case TransportDataEvent():
        _receivedBytes += event.bytes.length;
        _receivedData.add(Uint8List.fromList(event.bytes));
        _scheduler.add(event.bytes);
      case TransportErrorEvent():
        _setError(
          TransportException(event.error),
          status: _activeTransportStatus(),
          isOpening: false,
          isSending: false,
        );
      case TransportSignalChangedEvent():
        _state.value = _state.value.copyWith(signals: event.signals);
    }
  }

  void _handlePortsChanged(List<SerialPortInfo> ports) {
    if (_disposed) {
      return;
    }
    final current = _state.value;
    final config = _withSelectedPort(current.config, ports);
    _state.value = current.copyWith(ports: ports, config: config);
  }

  void _handleBatch(Uint8List batch) {
    if (_disposed) {
      return;
    }
    final droppedBytes = _rawBuffer.append(batch);
    _projection.append(batch, _now());
    final current = _state.value;
    _state.value = current.copyWith(
      lines: _projection.snapshot(current.displayMode),
      receivedBytes: _receivedBytes,
      droppedBytes: current.droppedBytes + droppedBytes,
      droppedLines: _projection.droppedLines(current.displayMode),
    );
  }

  Future<void> _attachTransportEvents(Transport transport) async {
    await _cancelAllTransportEvents();
    final subscription = transport.events.listen(_handleTransportEvent);
    _eventSubscription = subscription;
    _eventSubscriptionOwner = transport;
  }

  Future<void> _cancelAllTransportEvents() async {
    final subscription = _eventSubscription;
    _eventSubscription = null;
    _eventSubscriptionOwner = null;
    await subscription?.cancel();
  }

  Future<void> _cancelTransportEventsFor(Transport transport) async {
    if (!identical(_eventSubscriptionOwner, transport)) {
      return;
    }
    final subscription = _eventSubscription;
    _eventSubscription = null;
    _eventSubscriptionOwner = null;
    await subscription?.cancel();
  }

  Future<Transport> _createNetworkTransport(TerminalViewState state) async {
    final factory = networkTransportFactory;
    if (factory == null) {
      throw const TransportException(
        TransportError(
          code: TransportErrorCode.unsupported,
          message: '当前组合未配置网络传输工厂',
        ),
      );
    }
    await _disposeNetworkTransport();
    final config = switch (state.transportMode) {
      TransportMode.serial => throw StateError('串口模式不能创建网络传输'),
      TransportMode.tcpClient => TcpClientTransportConfig(
        host: state.remoteHost,
        port: state.remotePort,
      ),
      TransportMode.tcpServer => TcpServerTransportConfig(
        bindAddress: state.bindAddress,
        port: state.localPort,
      ),
      TransportMode.udp => UdpTransportConfig(
        bindAddress: state.bindAddress,
        localPort: state.localPort,
        remoteHost: state.remoteHost,
        remotePort: state.remotePort,
        followRemoteEndpoint: state.followRemoteEndpoint,
      ),
    };
    final transport = factory.create(config);
    _networkTransport = transport;
    return transport;
  }

  Future<void> _releaseActiveTransportForModeChange() async {
    final mode = _state.value.transportMode;
    if (mode == TransportMode.serial) {
      try {
        await _serialTransport.close();
      } finally {
        await _cancelTransportEventsFor(_serialTransport);
      }
      return;
    }
    await _closeAndDisposeNetworkTransport();
  }

  Future<void> _closeAndDisposeNetworkTransport() async {
    final transport = _networkTransport;
    if (transport == null) {
      return;
    }
    try {
      await transport.close();
    } finally {
      await _disposeNetworkTransport();
    }
  }

  Future<void> _disposeNetworkTransport() {
    final ongoing = _networkDisposeFuture;
    if (ongoing != null) {
      return ongoing;
    }
    final transport = _networkTransport;
    if (transport == null) {
      return Future<void>.value();
    }
    _networkTransport = null;
    late final Future<void> operation;
    operation = _disposeNetworkTransportNow(transport).whenComplete(() {
      if (identical(_networkDisposeFuture, operation)) {
        _networkDisposeFuture = null;
      }
    });
    _networkDisposeFuture = operation;
    return operation;
  }

  Future<void> _disposeNetworkTransportNow(Transport transport) async {
    await _cancelTransportEventsFor(transport);
    try {
      await transport.dispose();
    } catch (_) {
      // 释放阶段不覆盖已向用户展示的连接错误。
    }
  }

  Transport _requireActiveTransport() {
    final transport = _state.value.transportMode == TransportMode.serial
        ? _serialTransport
        : _networkTransport;
    if (transport == null) {
      throw StateError('当前传输尚未创建');
    }
    return transport;
  }

  TransportStatus _activeTransportStatus() {
    final transport = _state.value.transportMode == TransportMode.serial
        ? _serialTransport
        : _networkTransport;
    return transport?.status ?? _state.value.status;
  }

  String? _validateNetworkSettings(TerminalViewState state) {
    if (state.remotePort < 1 || state.remotePort > 65535) {
      return '远端端口必须在 1 到 65535 之间';
    }
    if (state.localPort < 1 || state.localPort > 65535) {
      return '本地端口必须在 1 到 65535 之间';
    }
    final listensExternally =
        (state.transportMode == TransportMode.tcpServer ||
            state.transportMode == TransportMode.udp) &&
        state.bindAddress.trim().isNotEmpty &&
        !isLoopbackBindAddress(state.bindAddress);
    if (state.networkSafetyMode == NetworkSafetyMode.safe &&
        listensExternally) {
      return 'Safe 模式禁止监听非回环地址，请改用 Raw/Debug 并确认风险';
    }
    if (state.transportMode == TransportMode.udp &&
        !state.followRemoteEndpoint &&
        state.remoteHost.trim().isEmpty) {
      return 'UDP 已关闭来源跟随，请先填写远端主机';
    }
    return switch (state.transportMode) {
      TransportMode.serial => null,
      TransportMode.tcpClient =>
        state.remoteHost.trim().isEmpty ? '请先填写远端主机' : null,
      TransportMode.tcpServer =>
        state.bindAddress.trim().isEmpty ? '请先填写监听地址' : null,
      TransportMode.udp =>
        state.bindAddress.trim().isEmpty ? '请先填写本地监听地址' : null,
    };
  }

  String _openingDetail(TerminalViewState state) {
    return switch (state.transportMode) {
      TransportMode.serial => '正在打开 ${state.config.portName}',
      TransportMode.tcpClient =>
        '正在连接 ${state.remoteHost.trim()}:${state.remotePort}',
      TransportMode.tcpServer =>
        '正在监听 ${state.bindAddress.trim()}:${state.localPort}',
      TransportMode.udp =>
        '正在绑定 ${state.bindAddress.trim()}:${state.localPort}',
    };
  }

  String _backendLabelForMode(TransportMode mode) {
    return switch (mode) {
      TransportMode.serial => _serialBackendLabel,
      TransportMode.tcpClient => 'TCP 客户端',
      TransportMode.tcpServer => 'TCP 服务端',
      TransportMode.udp => 'UDP',
    };
  }

  String _modeLabel(TransportMode mode) {
    return switch (mode) {
      TransportMode.serial => '串口',
      TransportMode.tcpClient => 'TCP 客户端',
      TransportMode.tcpServer => 'TCP 服务端',
      TransportMode.udp => 'UDP',
    };
  }

  SerialConfig _withSelectedPort(
    SerialConfig config,
    List<SerialPortInfo> ports,
  ) {
    if (ports.isEmpty) {
      return config.portName.isEmpty ? config : config.copyWith(portName: '');
    }
    final existing = ports.where((port) => port.systemPath == config.portName);
    if (existing.isNotEmpty) {
      return config;
    }
    final preferred = ports.firstWhere(
      (port) => port.isAvailable,
      orElse: () => ports.first,
    );
    return config.copyWith(portName: preferred.systemPath);
  }

  void _setErrorMessage(String message) {
    _state.value = _state.value.copyWith(errorMessage: message);
  }

  void _setError(
    Object error, {
    StackTrace? stackTrace,
    TransportStatus? status,
    bool? isRefreshingPorts,
    bool? isOpening,
    bool? isSending,
  }) {
    _state.value = _state.value.copyWith(
      status: status ?? _state.value.status,
      errorMessage: _messageFor(error),
      isRefreshingPorts: isRefreshingPorts ?? _state.value.isRefreshingPorts,
      isOpening: isOpening ?? _state.value.isOpening,
      isSending: isSending ?? _state.value.isSending,
    );
  }

  String _messageFor(Object error) {
    return switch (error) {
      TransportException() => error.error.message,
      EscapeInputException() => error.message,
      HexInputException() => error.message,
      ChecksumRangeException() => '校验范围无效',
      FormatException() => error.message,
      StateError() => error.message,
      ArgumentError() => error.message ?? error.toString(),
      _ => error.toString(),
    };
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('TerminalController 已销毁');
    }
  }
}
