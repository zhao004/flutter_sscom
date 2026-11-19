import 'dart:io';
import 'dart:typed_data';

/// 接收日志待写队列超过上限。
final class ReceiveLogOverflowException implements Exception {
  /// 创建队列溢出异常。
  const ReceiveLogOverflowException(this.pendingBytes, this.maxPendingBytes);

  /// 当前待写字节数。
  final int pendingBytes;

  /// 允许的最大待写字节数。
  final int maxPendingBytes;

  @override
  String toString() => '接收日志写入队列已满（$pendingBytes/$maxPendingBytes 字节）';
}

/// 顺序写入文件系统的接收日志写入器。
///
/// 写入操作按调用顺序串行化，调用 [append] 不会在 UI 线程等待磁盘完成。队列
/// 设置字节上限，超过上限时调用方应停止记录并向用户报告，避免无限占用内存。
final class ReceiveLogWriter {
  /// 创建写入器。
  ReceiveLogWriter({required this.file, this.maxPendingBytes = 4 * 1024 * 1024})
    : assert(maxPendingBytes > 0);

  /// 目标日志文件。
  final File file;

  /// 允许积累的待写字节上限。
  final int maxPendingBytes;

  RandomAccessFile? _handle;
  Future<void> _tail = Future<void>.value();
  Object? _failure;
  int _pendingBytes = 0;
  bool _closed = false;

  /// 当前尚未完成写入的字节数。
  int get pendingBytes => _pendingBytes;

  /// 打开日志文件。[append] 为真时保留已有内容。
  Future<void> open({bool append = true}) async {
    if (_closed) {
      throw StateError('接收日志写入器已关闭');
    }
    if (_handle != null) {
      return;
    }
    await file.parent.create(recursive: true);
    _handle = await file.open(
      mode: append ? FileMode.append : FileMode.writeOnly,
    );
  }

  /// 排队写入一段接收数据。
  Future<void> append(Uint8List bytes) {
    final handle = _handle;
    if (_closed || handle == null) {
      throw StateError('接收日志未打开');
    }
    if (_failure != null) {
      throw StateError('接收日志写入器已失败');
    }
    if (bytes.isEmpty) {
      return Future<void>.value();
    }
    final pendingBytes = _pendingBytes + bytes.length;
    if (pendingBytes > maxPendingBytes) {
      throw ReceiveLogOverflowException(pendingBytes, maxPendingBytes);
    }
    _pendingBytes = pendingBytes;
    final operation = _tail.then((_) async {
      try {
        await handle.writeFrom(bytes);
      } finally {
        _pendingBytes -= bytes.length;
      }
    });
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        _failure = error;
      },
    );
    return operation;
  }

  /// 等待队列完成、刷新并关闭文件。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final handle = _handle;
    _handle = null;
    await _tail;
    if (handle != null) {
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(
        StateError('接收日志写入失败：$failure'),
        StackTrace.current,
      );
    }
  }
}
