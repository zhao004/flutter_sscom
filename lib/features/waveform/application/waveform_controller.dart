import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sscom/core/buffers/byte_batch_scheduler.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:signals/signals.dart';

import '../domain/waveform_buffer.dart';

/// 波形页面只读状态。
final class WaveformState {
  /// 创建波形状态。
  WaveformState({
    required List<WaveformBucket> buckets,
    required this.totalSamples,
    required this.windowSamples,
    required this.discardedSamples,
    required this.isPaused,
  }) : buckets = List<WaveformBucket>.unmodifiable(buckets);

  /// 当前窗口的降采样区间。
  final List<WaveformBucket> buckets;

  /// 自上次清空以来累计接收的样本数。
  final int totalSamples;

  /// 当前有界窗口中的原始样本数。
  final int windowSamples;

  /// 因窗口上限累计丢弃的样本数。
  final int discardedSamples;

  /// 是否暂停接收新样本。
  final bool isPaused;

  /// 当前窗口是否有可绘制数据。
  bool get hasSamples => buckets.isNotEmpty;

  /// 最新样本值；没有数据时为 `null`。
  int? get latestSample => buckets.isEmpty ? null : buckets.last.last;
}

/// 从终端原始接收流构建独立、有界且降采样的波形。
///
/// 波形使用自己的批量刷新计时器，不依赖终端 Widget 的重绘节奏；暂停或清空
/// 波形不会影响终端、接收日志或原始字节计数。每个字节映射为一个 0 至 255
/// 的样本。
final class WaveformController {
  /// 创建波形控制器。
  WaveformController({
    required this.terminal,
    int capacitySamples = 64 * 1024,
    int maxBuckets = 512,
    Duration flushInterval = const Duration(milliseconds: 33),
    int maxPendingBytes = 16 * 1024,
  }) : assert(capacitySamples > 0),
       assert(maxBuckets > 0),
       _buffer = WaveformBuffer(capacitySamples: capacitySamples) {
    _scheduler = ByteBatchScheduler(
      flushInterval: flushInterval,
      maxPendingBytes: maxPendingBytes,
      onBatch: _handleBatch,
    );
    _maxBuckets = maxBuckets;
    _state = signal<WaveformState>(_snapshot());
    _readonlyState = _state.readonly();
    _subscription = terminal.receivedData.listen(_handleReceivedData);
  }

  /// 原始接收数据来源。
  final TerminalController terminal;
  final WaveformBuffer _buffer;
  late final ByteBatchScheduler _scheduler;
  late final int _maxBuckets;
  late final Signal<WaveformState> _state;
  late final ReadonlySignal<WaveformState> _readonlyState;
  StreamSubscription<Uint8List>? _subscription;
  bool _paused = false;
  bool _disposed = false;

  /// 只读波形状态。
  ReadonlySignal<WaveformState> get state => _readonlyState;

  /// 设置是否暂停接收新样本；暂停期间终端仍正常接收。
  void setPaused(bool paused) {
    _throwIfDisposed();
    if (_paused == paused) {
      return;
    }
    if (paused) {
      _scheduler.flushNow();
    }
    _paused = paused;
    _publish();
  }

  /// 清空波形窗口和累计计数。
  void clear() {
    _throwIfDisposed();
    _scheduler.flushNow();
    _buffer.clear();
    _publish();
  }

  /// 取消接收并释放计时器和状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    _scheduler.dispose();
    _state.dispose();
  }

  void _handleReceivedData(Uint8List bytes) {
    if (_disposed || _paused || bytes.isEmpty) {
      return;
    }
    _scheduler.add(bytes);
  }

  void _handleBatch(Uint8List batch) {
    if (_disposed) {
      return;
    }
    _buffer.append(batch);
    _publish();
  }

  void _publish() {
    if (_disposed) {
      return;
    }
    _state.value = _snapshot();
  }

  WaveformState _snapshot() {
    return WaveformState(
      buckets: _buffer.snapshot(maxBuckets: _maxBuckets),
      totalSamples: _buffer.totalSamples,
      windowSamples: _buffer.length,
      discardedSamples: _buffer.discardedSamples,
      isPaused: _paused,
    );
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('WaveformController 已销毁');
    }
  }
}
