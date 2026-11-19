/// 终端接收缓冲和高频刷新策略。
final class BufferPolicy {
  /// 创建并校验缓冲策略。
  BufferPolicy({
    this.maxRawBytes = defaultMaxRawBytes,
    this.maxDisplayLines = defaultMaxDisplayLines,
    this.flushInterval = defaultFlushInterval,
    this.maxPendingBytes = defaultMaxPendingBytes,
    this.hexBytesPerLine = defaultHexBytesPerLine,
  }) {
    if (maxRawBytes <= 0) {
      throw ArgumentError.value(maxRawBytes, 'maxRawBytes', '最大原始字节数必须大于 0');
    }
    if (maxDisplayLines <= 0) {
      throw ArgumentError.value(
        maxDisplayLines,
        'maxDisplayLines',
        '最大显示行数必须大于 0',
      );
    }
    if (flushInterval <= Duration.zero) {
      throw ArgumentError.value(flushInterval, 'flushInterval', '刷新窗口必须大于 0');
    }
    if (maxPendingBytes <= 0) {
      throw ArgumentError.value(
        maxPendingBytes,
        'maxPendingBytes',
        '最大待刷新字节数必须大于 0',
      );
    }
    if (hexBytesPerLine <= 0 || hexBytesPerLine > 64) {
      throw ArgumentError.value(
        hexBytesPerLine,
        'hexBytesPerLine',
        'HEX 每行字节数必须在 1 到 64 之间',
      );
    }
  }

  /// 默认原始接收缓冲：256 KiB。
  static const int defaultMaxRawBytes = 256 * 1024;

  /// 默认最大终端行数。
  static const int defaultMaxDisplayLines = 5000;

  /// 默认约 30 FPS 的刷新窗口。
  static const Duration defaultFlushInterval = Duration(milliseconds: 33);

  /// 默认每批最多 16 KiB。
  static const int defaultMaxPendingBytes = 16 * 1024;

  /// 默认 HEX 每行 16 字节。
  static const int defaultHexBytesPerLine = 16;

  /// 原始字节环形缓冲上限。
  final int maxRawBytes;

  /// 文本和 HEX 投影各自允许的最大行数。
  final int maxDisplayLines;

  /// 终端状态刷新窗口。
  final Duration flushInterval;

  /// 单次批量回调的最大字节数。
  final int maxPendingBytes;

  /// HEX 视图每行展示的字节数。
  final int hexBytesPerLine;
}
