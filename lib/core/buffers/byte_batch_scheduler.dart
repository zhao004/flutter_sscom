import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// 批量刷新回调。
typedef ByteBatchSink = void Function(Uint8List batch);

/// 将高频字节流按固定时间窗口聚合成有限大小的批次。
final class ByteBatchScheduler {
  ByteBatchScheduler({
    required this.flushInterval,
    required this.maxPendingBytes,
    required this.onBatch,
  }) {
    if (flushInterval <= Duration.zero) {
      throw ArgumentError.value(flushInterval, 'flushInterval', '刷新窗口必须大于 0');
    }
    if (maxPendingBytes <= 0) {
      throw ArgumentError.value(
        maxPendingBytes,
        'maxPendingBytes',
        '最大待处理字节数必须大于 0',
      );
    }
  }

  /// 固定刷新窗口。
  final Duration flushInterval;

  /// 单批最多积累的字节数。
  final int maxPendingBytes;

  /// 批次达到时间窗口或容量上限时调用的回调。
  final ByteBatchSink onBatch;
  final List<int> _pending = <int>[];
  Timer? _timer;
  bool _disposed = false;

  /// 当前尚未回调的字节数。
  int get pendingLength => _pending.length;

  /// 追加待刷新字节。
  ///
  /// 达到 [maxPendingBytes] 时立即刷新；否则在首个字节到达后启动固定窗口计时器。
  void add(Uint8List bytes) {
    _throwIfDisposed();
    var offset = 0;
    while (offset < bytes.length) {
      final writable = math.min(
        maxPendingBytes - _pending.length,
        bytes.length - offset,
      );
      _pending.addAll(Uint8List.sublistView(bytes, offset, offset + writable));
      offset += writable;
      if (_pending.length == maxPendingBytes) {
        _emit();
      } else {
        _schedule();
      }
    }
  }

  /// 立即刷新当前批次。
  void flushNow() {
    _throwIfDisposed();
    _emit();
  }

  /// 取消计时器并丢弃尚未刷新的数据。
  ///
  /// 重复调用不会产生额外副作用。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void _schedule() {
    _timer ??= Timer(flushInterval, () {
      _timer = null;
      _emit();
    });
  }

  void _emit() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) {
      return;
    }
    final batch = Uint8List.fromList(_pending);
    _pending.clear();
    onBatch(batch);
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('ByteBatchScheduler 已销毁');
    }
  }
}
