import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/isp/firmware_image.dart';
import 'package:flutter_sscom/core/isp/intel_hex_parser.dart';
import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_client.dart';
import 'package:flutter_sscom/core/isp/stm32_bootloader_simulator.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/file_transfer/application/file_send_controller.dart';
import 'package:flutter_sscom/features/isp/infrastructure/terminal_isp_link.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:signals/signals.dart';

/// 支持的 ISP 目标系列。
enum IspTargetFamily {
  /// STM32 与兼容 AN3155 的 GD32 UART bootloader。
  stm32Gd32,

  /// STC/IAP15 串口 ISP。
  stc15,
}

/// ISP 连接来源。
enum IspConnectionSource {
  /// 当前已连接的真实串口。
  hardware,

  /// 内存中的 STM32 bootloader 模拟器。
  stm32Simulator,
}

/// 进入 STM32 bootloader 时使用的复位方式。
enum IspResetMode {
  /// 由用户手动进入 bootloader。
  manual,

  /// 通过 DTR 低脉冲复位。
  dtrLowPulse,

  /// 通过 RTS 低脉冲复位。
  rtsLowPulse,
}

/// ISP 页面阶段。
enum IspPhase {
  /// 尚未开始。
  idle,

  /// 正在同步和识别。
  detecting,

  /// 已识别，等待烧录确认。
  ready,

  /// 正在擦除。
  erasing,

  /// 正在写入。
  writing,

  /// 正在校验。
  verifying,

  /// 正在启动目标。
  starting,

  /// 已完成。
  completed,

  /// 失败。
  failed,

  /// 已取消。
  cancelled,
}

/// 读取固件文件的字节；测试可注入内存内容以避免真实文件 I/O。
typedef IspFirmwareBytesReader = Future<Uint8List> Function(File file);

/// Intel HEX 文本文件允许的最大字节数。
const int maxIspFirmwareFileBytes = 16 * 1024 * 1024;

Future<Uint8List> _readFirmwareFile(File file) async {
  if (await file.length() > maxIspFirmwareFileBytes) {
    throw const IntelHexFormatException('文件超过允许的 16 MiB 文本上限');
  }
  return file.readAsBytes();
}

const Object _notSet = Object();

/// ISP 允许用户确认的最小 Flash 容量（KiB）。
const int minIspFlashSizeKiB = 1;

/// ISP 允许用户确认的最大 Flash 容量（KiB）。
const int maxIspFlashSizeKiB = 4096;

/// ISP 页面只读状态。
final class IspViewState {
  /// 创建 ISP 状态。
  IspViewState({
    this.family = IspTargetFamily.stm32Gd32,
    this.connectionSource = IspConnectionSource.hardware,
    this.resetMode = IspResetMode.manual,
    this.phase = IspPhase.idle,
    this.flashStartAddress = 0x08000000,
    this.flashSizeKiB = 64,
    this.runAfterProgramming = false,
    this.firmwarePath,
    this.firmwareName,
    this.image,
    this.firmwareError,
    this.deviceInfo,
    this.progressPhase,
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.message,
    this.errorMessage,
  });

  /// 目标系列。
  final IspTargetFamily family;

  /// 连接来源。
  final IspConnectionSource connectionSource;

  /// 复位方式。
  final IspResetMode resetMode;

  /// 当前阶段。
  final IspPhase phase;

  /// STM/GD32 Flash 起始地址。
  final int flashStartAddress;

  /// 用户确认的 Flash 容量。
  final int flashSizeKiB;

  /// 烧录完成后是否执行 Go 命令。
  final bool runAfterProgramming;

  /// 固件路径。
  final String? firmwarePath;

  /// 固件文件名。
  final String? firmwareName;

  /// 已解析固件。
  final FirmwareImage? image;

  /// 固件解析错误。
  final String? firmwareError;

  /// 已识别设备信息。
  final Stm32DeviceInfo? deviceInfo;

  /// 当前进度所属核心阶段。
  final IspOperationPhase? progressPhase;

  /// 当前阶段完成字节数。
  final int completedBytes;

  /// 当前阶段总字节数。
  final int totalBytes;

  /// 最近状态说明。
  final String? message;

  /// 最近错误说明。
  final String? errorMessage;

  /// 是否有 ISP 任务正在执行。
  bool get isBusy => switch (phase) {
    IspPhase.detecting ||
    IspPhase.erasing ||
    IspPhase.writing ||
    IspPhase.verifying ||
    IspPhase.starting => true,
    IspPhase.idle ||
    IspPhase.ready ||
    IspPhase.completed ||
    IspPhase.failed ||
    IspPhase.cancelled => false,
  };

  /// 当前进度比例。
  double get progress =>
      totalBytes <= 0 ? 0 : (completedBytes / totalBytes).clamp(0, 1);

  /// Flash 尾后一地址。
  int get flashEndAddressExclusive => flashStartAddress + flashSizeKiB * 1024;

  /// 是否已识别可烧录设备。
  bool get isDeviceReady => deviceInfo != null && phase == IspPhase.ready;

  /// 是否允许执行烧录。
  bool get canProgram =>
      isDeviceReady && image != null && validationError == null;

  /// 固件地址验证结果。
  String? get validationError {
    final currentImage = image;
    if (currentImage == null) {
      return '尚未加载 Intel HEX 固件';
    }
    for (final segment in currentImage.segments) {
      if (segment.startAddress < flashStartAddress ||
          segment.endAddressExclusive > flashEndAddressExclusive) {
        return '固件段 0x${segment.startAddress.toRadixString(16)}–'
            '0x${(segment.endAddressExclusive - 1).toRadixString(16)} '
            '超出配置 Flash 范围';
      }
    }
    return null;
  }

  /// 返回替换部分字段后的状态。
  IspViewState copyWith({
    IspTargetFamily? family,
    IspConnectionSource? connectionSource,
    IspResetMode? resetMode,
    IspPhase? phase,
    int? flashStartAddress,
    int? flashSizeKiB,
    bool? runAfterProgramming,
    Object? firmwarePath = _notSet,
    Object? firmwareName = _notSet,
    Object? image = _notSet,
    Object? firmwareError = _notSet,
    Object? deviceInfo = _notSet,
    Object? progressPhase = _notSet,
    int? completedBytes,
    int? totalBytes,
    Object? message = _notSet,
    Object? errorMessage = _notSet,
  }) {
    return IspViewState(
      family: family ?? this.family,
      connectionSource: connectionSource ?? this.connectionSource,
      resetMode: resetMode ?? this.resetMode,
      phase: phase ?? this.phase,
      flashStartAddress: flashStartAddress ?? this.flashStartAddress,
      flashSizeKiB: flashSizeKiB ?? this.flashSizeKiB,
      runAfterProgramming: runAfterProgramming ?? this.runAfterProgramming,
      firmwarePath: identical(firmwarePath, _notSet)
          ? this.firmwarePath
          : firmwarePath as String?,
      firmwareName: identical(firmwareName, _notSet)
          ? this.firmwareName
          : firmwareName as String?,
      image: identical(image, _notSet) ? this.image : image as FirmwareImage?,
      firmwareError: identical(firmwareError, _notSet)
          ? this.firmwareError
          : firmwareError as String?,
      deviceInfo: identical(deviceInfo, _notSet)
          ? this.deviceInfo
          : deviceInfo as Stm32DeviceInfo?,
      progressPhase: identical(progressPhase, _notSet)
          ? this.progressPhase
          : progressPhase as IspOperationPhase?,
      completedBytes: completedBytes ?? this.completedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      message: identical(message, _notSet) ? this.message : message as String?,
      errorMessage: identical(errorMessage, _notSet)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

/// ISP 工作区控制器。
///
/// 控制器负责串口独占、DTR/RTS 恢复、固件加载、设备识别和危险操作编排；
/// 具体 bootloader 字节协议由 `lib/core/isp` 中的纯 Dart 客户端实现。
final class IspController {
  /// 创建 ISP 控制器。
  IspController({
    required this.terminal,
    this.multiSendController,
    this.fileSendController,
    IspFirmwareBytesReader? firmwareBytesReader,
  }) : _firmwareBytesReader = firmwareBytesReader ?? _readFirmwareFile,
       _state = signal<IspViewState>(IspViewState()) {
    _readonlyState = _state.readonly();
  }

  /// 当前串口工作区。
  final TerminalController terminal;

  /// 用于启动 ISP 前停止多字符串发送。
  final MultiSendController? multiSendController;

  /// 用于拒绝在文件发送期间启动 ISP。
  final FileSendController? fileSendController;

  final IspFirmwareBytesReader _firmwareBytesReader;
  final Signal<IspViewState> _state;
  late final ReadonlySignal<IspViewState> _readonlyState;
  Stm32BootloaderClient? _client;
  IspLink? _link;
  IspCancellationToken? _cancellation;
  SerialSignalState? _initialSignals;
  bool _exclusiveHeld = false;
  bool _disposed = false;
  int _lastProgressBucket = -1;

  /// 只读 ISP 状态。
  ReadonlySignal<IspViewState> get state => _readonlyState;

  /// 切换目标系列并关闭现有识别会话。
  Future<void> setFamily(IspTargetFamily family) async {
    _throwIfDisposed();
    if (_state.value.isBusy || _state.value.family == family) {
      return;
    }
    await _closeSession();
    _state.value = _state.value.copyWith(
      family: family,
      phase: IspPhase.idle,
      deviceInfo: null,
      progressPhase: null,
      completedBytes: 0,
      totalBytes: 0,
      message: null,
      errorMessage: null,
    );
  }

  /// 切换硬件或模拟器来源。
  Future<void> setConnectionSource(IspConnectionSource source) async {
    _throwIfDisposed();
    if (_state.value.isBusy || _state.value.connectionSource == source) {
      return;
    }
    await _closeSession();
    _state.value = _state.value.copyWith(
      connectionSource: source,
      phase: IspPhase.idle,
      deviceInfo: null,
      progressPhase: null,
      completedBytes: 0,
      totalBytes: 0,
      message: null,
      errorMessage: null,
    );
  }

  /// 修改手动确认的 Flash 容量。
  ///
  /// 已识别的 bootloader 客户端持有识别时的容量和地址范围；容量变化时必须
  /// 释放旧会话并要求重新识别，避免继续使用过期配置执行烧录。
  Future<void> setFlashSizeKiB(int value) async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    if (value < minIspFlashSizeKiB || value > maxIspFlashSizeKiB) {
      _state.value = _state.value.copyWith(
        errorMessage:
            'Flash 容量必须在 $minIspFlashSizeKiB 到 $maxIspFlashSizeKiB KiB 之间',
      );
      return;
    }
    final current = _state.value;
    if (current.flashSizeKiB == value) {
      return;
    }
    final hadSession = _link != null || _exclusiveHeld;
    _state.value = current.copyWith(
      flashSizeKiB: value,
      phase: IspPhase.idle,
      deviceInfo: null,
      progressPhase: null,
      completedBytes: 0,
      totalBytes: 0,
      message: 'Flash 容量已更新，请重新识别设备',
      errorMessage: null,
    );
    if (hadSession) {
      await _closeSession();
    }
  }

  /// 修改进入 bootloader 的复位方式。
  void setResetMode(IspResetMode mode) {
    _throwIfDisposed();
    if (_state.value.isBusy || _state.value.resetMode == mode) {
      return;
    }
    _state.value = _state.value.copyWith(resetMode: mode);
  }

  /// 修改烧录完成后是否启动目标。
  void setRunAfterProgramming(bool enabled) {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    _state.value = _state.value.copyWith(runAfterProgramming: enabled);
  }

  /// 加载并严格解析 Intel HEX 固件。
  Future<void> loadFirmware(File file) async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    try {
      final bytes = await _firmwareBytesReader(file);
      if (bytes.length > maxIspFirmwareFileBytes) {
        throw const IntelHexFormatException('文件超过允许的 16 MiB 文本上限');
      }
      var start = 0;
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        start = 3;
      }
      final content = String.fromCharCodes(bytes, start);
      final image = parseIntelHex(content);
      _state.value = _state.value.copyWith(
        firmwarePath: file.path,
        firmwareName: _fileName(file.path),
        image: image,
        firmwareError: null,
        phase: _state.value.isDeviceReady ? IspPhase.ready : IspPhase.idle,
        completedBytes: 0,
        totalBytes: 0,
        message: '已加载 ${image.segmentCount} 个段，共 ${image.totalBytes} 字节',
        errorMessage: null,
      );
    } catch (error) {
      _state.value = _state.value.copyWith(
        firmwarePath: file.path,
        firmwareName: _fileName(file.path),
        image: null,
        firmwareError: _messageFor(error),
        completedBytes: 0,
        totalBytes: 0,
        errorMessage: _messageFor(error),
      );
    }
  }

  /// 同步目标并读取设备信息；该操作不会擦除 Flash。
  Future<void> inspectDevice() async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    if (_state.value.family == IspTargetFamily.stc15) {
      _state.value = _state.value.copyWith(
        phase: IspPhase.failed,
        errorMessage: 'STC/IAP15 真实烧录需要硬件 trace 与设备矩阵，当前未启用',
      );
      return;
    }
    if (fileSendController?.state.value.isRunning == true) {
      _state.value = _state.value.copyWith(
        phase: IspPhase.failed,
        errorMessage: '文件发送进行中，不能进入 ISP',
      );
      return;
    }

    final multiSend = multiSendController;
    if (multiSend?.state.value.isRunning == true) {
      await multiSend!.stop();
    }
    await _closeSession();
    _lastProgressBucket = -1;
    _state.value = _state.value.copyWith(
      phase: IspPhase.detecting,
      completedBytes: 0,
      totalBytes: 0,
      deviceInfo: null,
      message: null,
      errorMessage: null,
    );
    final cancellation = IspCancellationToken();
    _cancellation = cancellation;

    try {
      _link = await _createLink();
      _client = Stm32BootloaderClient(
        link: _link!,
        options: Stm32IspOptions(
          flashStartAddress: _state.value.flashStartAddress,
          flashSizeBytes: _state.value.flashSizeKiB * 1024,
        ),
      );
      if (_state.value.connectionSource == IspConnectionSource.hardware) {
        _initialSignals = terminal.state.value.signals;
        await _pulseResetIfConfigured();
      }
      final info = await _client!.connect(cancellation: cancellation);
      if (_state.value.connectionSource == IspConnectionSource.hardware) {
        await _restoreSignals();
      }
      _state.value = _state.value.copyWith(
        phase: IspPhase.ready,
        deviceInfo: info,
        message: '目标已识别，可加载固件并确认烧录',
        errorMessage: null,
      );
    } on IspCancelledException catch (error) {
      await _closeSession();
      _state.value = _state.value.copyWith(
        phase: IspPhase.cancelled,
        deviceInfo: null,
        message: error.message,
        errorMessage: null,
      );
    } catch (error) {
      await _closeSession();
      if (cancellation.isCancelled) {
        _state.value = _state.value.copyWith(
          phase: IspPhase.cancelled,
          deviceInfo: null,
          message: 'ISP 识别已取消',
          errorMessage: null,
        );
      } else {
        _state.value = _state.value.copyWith(
          phase: IspPhase.failed,
          deviceInfo: null,
          errorMessage: _messageFor(error),
        );
      }
    } finally {
      if (identical(_cancellation, cancellation)) {
        _cancellation = null;
      }
    }
  }

  /// 执行擦除、写入、回读校验和可选启动。
  Future<void> program() async {
    _throwIfDisposed();
    final current = _state.value;
    final client = _client;
    final image = current.image;
    if (current.isBusy) {
      return;
    }
    if (!current.isDeviceReady || client == null || image == null) {
      _state.value = current.copyWith(errorMessage: '请先识别设备并加载有效固件');
      return;
    }
    final validationError = current.validationError;
    if (validationError != null) {
      _state.value = current.copyWith(errorMessage: validationError);
      return;
    }

    final cancellation = IspCancellationToken();
    _cancellation = cancellation;
    _lastProgressBucket = -1;
    try {
      final prepared = client.prepareImage(image);
      final vectorAddress = current.runAfterProgramming
          ? client.applicationVectorAddress(image)
          : null;
      _state.value = _state.value.copyWith(
        phase: IspPhase.erasing,
        progressPhase: IspOperationPhase.erasing,
        completedBytes: 0,
        totalBytes: 1,
        message: '正在执行全片擦除',
        errorMessage: null,
      );
      await client.eraseAll(cancellation: cancellation);
      _state.value = _state.value.copyWith(completedBytes: 1, totalBytes: 1);
      await client.writeImage(
        prepared,
        cancellation: cancellation,
        onProgress: _handleProgress,
      );
      await client.verifyImage(
        prepared,
        cancellation: cancellation,
        onProgress: _handleProgress,
      );
      if (current.runAfterProgramming) {
        _state.value = _state.value.copyWith(
          phase: IspPhase.starting,
          progressPhase: IspOperationPhase.starting,
          completedBytes: 0,
          totalBytes: 1,
          message: '正在启动目标程序',
        );
        await client.go(vectorAddress!, cancellation: cancellation);
        _state.value = _state.value.copyWith(completedBytes: 1, totalBytes: 1);
      }
      _state.value = _state.value.copyWith(
        phase: IspPhase.completed,
        progressPhase: IspOperationPhase.completed,
        message: current.runAfterProgramming
            ? '烧录、校验和启动完成'
            : '烧录与校验完成，设备仍停留在 bootloader',
        errorMessage: null,
      );
    } on IspCancelledException catch (error) {
      _state.value = _state.value.copyWith(
        phase: IspPhase.cancelled,
        deviceInfo: null,
        message: error.message,
        errorMessage: null,
      );
    } catch (error) {
      if (cancellation.isCancelled) {
        _state.value = _state.value.copyWith(
          phase: IspPhase.cancelled,
          deviceInfo: null,
          message: 'ISP 操作已取消',
          errorMessage: null,
        );
      } else {
        _state.value = _state.value.copyWith(
          phase: IspPhase.failed,
          deviceInfo: null,
          errorMessage: _messageFor(error),
        );
      }
    } finally {
      _cancellation = null;
      await _closeSession();
    }
  }

  /// 结束当前识别会话并释放串口独占、DTR/RTS 和协议链路。
  ///
  /// 识别成功后控制器会保留 bootloader 客户端以支持后续烧录；用户取消烧录
  /// 或返回主工作区前可调用此方法主动恢复串口控制权。
  Future<void> endSession() async {
    _throwIfDisposed();
    if (_state.value.isBusy) {
      return;
    }
    await _closeSession();
    _state.value = _state.value.copyWith(
      phase: IspPhase.idle,
      deviceInfo: null,
      progressPhase: null,
      completedBytes: 0,
      totalBytes: 0,
      message: 'ISP 会话已结束，串口控制权已释放',
      errorMessage: null,
    );
  }

  /// 请求取消当前 ISP 操作。
  void cancel() {
    if (_disposed || !_state.value.isBusy) {
      return;
    }
    _cancellation?.cancel();
    _state.value = _state.value.copyWith(message: '正在取消并恢复串口状态');
    final link = _link;
    if (link != null) {
      unawaited(link.close());
    }
  }

  /// 关闭 ISP 会话并释放状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancellation?.cancel();
    await _closeSession();
    _state.dispose();
  }

  Future<IspLink> _createLink() async {
    if (_state.value.connectionSource == IspConnectionSource.stm32Simulator) {
      _initialSignals = null;
      return Stm32BootloaderSimulator(
        flashStartAddress: _state.value.flashStartAddress,
        flashSizeBytes: _state.value.flashSizeKiB * 1024,
      );
    }

    final terminalState = terminal.state.value;
    if (terminalState.transportMode != TransportMode.serial ||
        !terminalState.isConnected) {
      throw const IspException(
        code: IspErrorCode.transport,
        message: '请先在串口模式连接目标',
      );
    }
    if (terminalState.config.dataBits != SerialDataBits.eight ||
        terminalState.config.stopBits != SerialStopBits.one ||
        terminalState.config.parity != SerialParity.even) {
      throw const IspException(
        code: IspErrorCode.transport,
        message: 'STM/GD32 UART bootloader 要求 8 数据位、偶校验、1 停止位（8E1）',
      );
    }
    if (!terminal.acquireExclusiveSend(this)) {
      throw IspException(
        code: IspErrorCode.transport,
        message: terminal.state.value.errorMessage ?? '无法获得串口独占发送权',
      );
    }
    _exclusiveHeld = true;
    return TerminalIspLink(terminal: terminal, owner: this);
  }

  Future<void> _pulseResetIfConfigured() async {
    switch (_state.value.resetMode) {
      case IspResetMode.manual:
        return;
      case IspResetMode.dtrLowPulse:
        await _link!.setDtr(false);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _link!.setDtr(true);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      case IspResetMode.rtsLowPulse:
        await _link!.setRts(false);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _link!.setRts(true);
        await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<void> _restoreSignals() async {
    final signals = _initialSignals;
    if (signals == null ||
        terminal.state.value.transportMode != TransportMode.serial ||
        !terminal.state.value.isConnected) {
      return;
    }
    try {
      await terminal.setDtr(signals.dtr);
      await terminal.setRts(signals.rts);
    } catch (_) {
      // 串口已断开时无法恢复引脚，但资源清理仍需继续。
    }
  }

  Future<void> _closeSession() async {
    final link = _link;
    _link = null;
    _client = null;
    if (link != null) {
      await link.close();
    }
    try {
      await _restoreSignals();
    } finally {
      _initialSignals = null;
      if (_exclusiveHeld) {
        terminal.releaseExclusiveSend(this);
        _exclusiveHeld = false;
      }
    }
  }

  void _handleProgress(IspProgress progress) {
    final bucket = (progress.fraction * 200).floor();
    if (bucket == _lastProgressBucket &&
        progress.completedBytes < progress.totalBytes) {
      return;
    }
    _lastProgressBucket = bucket;
    _state.value = _state.value.copyWith(
      phase: switch (progress.phase) {
        IspOperationPhase.writing => IspPhase.writing,
        IspOperationPhase.verifying => IspPhase.verifying,
        IspOperationPhase.erasing => IspPhase.erasing,
        IspOperationPhase.starting => IspPhase.starting,
        IspOperationPhase.detecting => IspPhase.detecting,
        IspOperationPhase.completed => IspPhase.completed,
      },
      progressPhase: progress.phase,
      completedBytes: progress.completedBytes,
      totalBytes: progress.totalBytes,
      message: progress.message,
    );
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  String _messageFor(Object error) {
    return switch (error) {
      IspException() => error.message,
      IntelHexFormatException() => error.toString(),
      FileSystemException() => '读取固件失败：${error.message}',
      FormatException() => error.message,
      StateError() => error.message,
      ArgumentError() => error.message ?? error.toString(),
      _ => error.toString(),
    };
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('IspController 已销毁');
    }
  }
}
