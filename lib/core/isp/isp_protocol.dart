import 'dart:typed_data';

/// ISP 流程阶段。
enum IspOperationPhase {
  /// 正在识别目标。
  detecting,

  /// 正在擦除目标 Flash。
  erasing,

  /// 正在写入固件。
  writing,

  /// 正在回读校验。
  verifying,

  /// 正在启动目标程序。
  starting,

  /// 操作完成。
  completed,
}

/// ISP 错误分类。
enum IspErrorCode {
  /// 等待设备响应超时。
  timeout,

  /// 设备返回 NACK。
  nack,

  /// 响应帧格式无效或校验失败。
  framing,

  /// 当前 bootloader 不支持所需命令。
  unsupportedCommand,

  /// 设备与所选型号或容量不匹配。
  deviceMismatch,

  /// 固件地址超出允许范围。
  addressOutOfRange,

  /// 传输或写入失败。
  transport,

  /// 用户取消操作。
  cancelled,

  /// 未分类协议错误。
  unknown,
}

/// ISP 协议异常。
final class IspException implements Exception {
  /// 创建 ISP 异常。
  const IspException({required this.code, required this.message, this.cause});

  /// 稳定错误分类。
  final IspErrorCode code;

  /// 面向用户的错误说明。
  final String message;

  /// 可选的底层原因。
  final Object? cause;

  @override
  String toString() => 'IspException(${code.name}): $message';
}

/// 用户取消 ISP 时抛出的异常。
final class IspCancelledException extends IspException {
  /// 创建取消异常。
  const IspCancelledException()
    : super(code: IspErrorCode.cancelled, message: 'ISP 操作已取消');
}

/// ISP 进度快照。
final class IspProgress {
  /// 创建进度快照。
  const IspProgress({
    required this.phase,
    required this.completedBytes,
    required this.totalBytes,
    this.message,
  });

  /// 当前阶段。
  final IspOperationPhase phase;

  /// 当前阶段已完成字节数。
  final int completedBytes;

  /// 当前阶段总字节数。
  final int totalBytes;

  /// 可选状态说明。
  final String? message;

  /// 完成比例，范围为 0 到 1。
  double get fraction =>
      totalBytes <= 0 ? 0 : (completedBytes / totalBytes).clamp(0, 1);
}

/// ISP 进度回调。
typedef IspProgressCallback = void Function(IspProgress progress);

/// 可取消令牌。
final class IspCancellationToken {
  bool _cancelled = false;

  /// 是否已请求取消。
  bool get isCancelled => _cancelled;

  /// 请求取消；重复调用无副作用。
  void cancel() {
    _cancelled = true;
  }

  /// 已取消时抛出 [IspCancelledException]。
  void throwIfCancelled() {
    if (_cancelled) {
      throw const IspCancelledException();
    }
  }
}

/// ISP 协议使用的有序字节通道。
///
/// 协议核心只依赖该接口，不依赖 Flutter、Signals、GetIt 或具体串口实现。
abstract interface class IspLink {
  /// 写入完整字节序列。
  Future<void> write(Uint8List bytes);

  /// 在超时前读取指定数量的字节。
  Future<Uint8List> readExact(int length, {required Duration timeout});

  /// 丢弃当前尚未消费的输入。
  Future<void> clearInput();

  /// 设置 DTR 输出。
  Future<void> setDtr(bool enabled);

  /// 设置 RTS 输出。
  Future<void> setRts(bool enabled);

  /// 取消订阅并释放通道资源。
  Future<void> close();
}
