import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_sscom/core/buffers/byte_ring_buffer.dart';

/// 波形降采样后的一个区间。
final class WaveformBucket {
  /// 创建波形区间。
  const WaveformBucket({
    required this.startSample,
    required this.endSample,
    required this.minimum,
    required this.maximum,
    required this.last,
  });

  /// 区间首样本的绝对序号。
  final int startSample;

  /// 区间末样本的绝对序号，包含该值。
  final int endSample;

  /// 区间最小值，范围为 0 至 255。
  final int minimum;

  /// 区间最大值，范围为 0 至 255。
  final int maximum;

  /// 区间最后一个样本，用于连接相邻区间。
  final int last;
}

/// 有界波形样本及降采样投影。
///
/// 原始字节只保留最新 [capacitySamples] 个；绘制时把当前窗口分成有限数量的
/// 区间，同时保留每个区间的最小值、最大值和末值，避免把高频完整历史放入
/// Widget 状态。
final class WaveformBuffer {
  /// 创建波形缓冲。
  WaveformBuffer({required this.capacitySamples})
    : assert(capacitySamples > 0),
      _samples = ByteRingBuffer(capacitySamples);

  /// 原始样本容量。
  final int capacitySamples;
  ByteRingBuffer _samples;
  int _totalSamples = 0;

  /// 当前窗口中的样本数。
  int get length => _samples.length;

  /// 窗口是否为空。
  bool get isEmpty => _samples.isEmpty;

  /// 自上次清空以来累计接收的样本数。
  int get totalSamples => _totalSamples;

  /// 因容量上限累计丢弃的样本数。
  int get discardedSamples => _samples.discardedBytes;

  /// 追加原始样本并返回本次丢弃的旧样本数。
  int append(Uint8List samples) {
    _totalSamples += samples.length;
    return _samples.append(samples);
  }

  /// 返回最多 [maxBuckets] 个按时间顺序排列的降采样区间。
  List<WaveformBucket> snapshot({required int maxBuckets}) {
    if (maxBuckets <= 0) {
      throw ArgumentError.value(maxBuckets, 'maxBuckets', '波形区间数必须大于 0');
    }
    if (_samples.isEmpty) {
      return const <WaveformBucket>[];
    }

    final bytes = _samples.snapshot();
    final bucketCount = math.min(maxBuckets, bytes.length);
    final windowStart = _totalSamples - bytes.length;
    final result = <WaveformBucket>[];
    for (var bucketIndex = 0; bucketIndex < bucketCount; bucketIndex++) {
      final start = bucketIndex * bytes.length ~/ bucketCount;
      final endExclusive = (bucketIndex + 1) * bytes.length ~/ bucketCount;
      final safeEnd = math.max(start + 1, endExclusive);
      var minimum = 255;
      var maximum = 0;
      var last = 0;
      for (var index = start; index < safeEnd; index++) {
        final value = bytes[index];
        minimum = math.min(minimum, value);
        maximum = math.max(maximum, value);
        last = value;
      }
      result.add(
        WaveformBucket(
          startSample: windowStart + start,
          endSample: windowStart + safeEnd - 1,
          minimum: minimum,
          maximum: maximum,
          last: last,
        ),
      );
    }
    return List<WaveformBucket>.unmodifiable(result);
  }

  /// 清空窗口和累计计数。
  void clear() {
    _samples = ByteRingBuffer(capacitySamples);
    _totalSamples = 0;
  }
}
