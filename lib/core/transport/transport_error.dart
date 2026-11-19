/// 稳定的传输错误分类。
enum TransportErrorCode {
  /// 指定端口不存在。
  portNotFound,

  /// 端口被其他进程占用。
  portBusy,

  /// 当前进程没有访问权限。
  permissionDenied,

  /// 当前状态不允许执行操作。
  invalidState,

  /// 传输已经断开。
  disconnected,

  /// 无法建立远端连接。
  connectionFailed,

  /// 无法绑定本地监听地址或端口。
  bindFailed,

  /// 主机名无法解析。
  addressResolutionFailed,

  /// 配置只能在关闭状态修改。
  configureWhileOpen,

  /// 读取失败。
  readFailed,

  /// 写入失败。
  writeFailed,

  /// 当前平台或后端不支持该能力。
  unsupported,

  /// 未分类错误。
  unknown,
}

/// 结构化传输错误。
final class TransportError {
  /// 创建传输错误。
  const TransportError({required this.code, required this.message, this.cause});

  /// 稳定错误分类。
  final TransportErrorCode code;

  /// 面向用户或诊断日志的错误说明。
  final String message;

  /// 可选的底层异常。
  final Object? cause;

  @override
  String toString() => 'TransportError(${code.name}): $message';
}

/// 传输操作失败时抛出的异常。
final class TransportException implements Exception {
  /// 创建传输异常。
  const TransportException(this.error);

  /// 结构化错误信息。
  final TransportError error;

  @override
  String toString() => error.toString();
}
