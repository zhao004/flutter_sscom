import 'dart:typed_data';

import 'package:flutter_sscom/features/waveform/domain/waveform_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WaveformBuffer', () {
    test('降采样保留区间最小、最大和末值', () {
      final buffer = WaveformBuffer(capacitySamples: 16)
        ..append(Uint8List.fromList(<int>[0, 255, 1, 254]));

      final buckets = buffer.snapshot(maxBuckets: 2);

      expect(buckets, hasLength(2));
      expect(buckets[0].minimum, 0);
      expect(buckets[0].maximum, 255);
      expect(buckets[0].last, 255);
      expect(buckets[1].minimum, 1);
      expect(buckets[1].maximum, 254);
      expect(buckets[1].last, 254);
      expect(buckets.first.startSample, 0);
      expect(buckets.last.endSample, 3);
    });

    test('窗口溢出后保留最新样本并维持绝对样本序号', () {
      final buffer = WaveformBuffer(capacitySamples: 4)
        ..append(Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5]));

      final buckets = buffer.snapshot(maxBuckets: 8);

      expect(buffer.totalSamples, 6);
      expect(buffer.discardedSamples, 2);
      expect(buffer.length, 4);
      expect(
        buckets.map((bucket) => bucket.last),
        orderedEquals(<int>[2, 3, 4, 5]),
      );
      expect(buckets.first.startSample, 2);
      expect(buckets.last.endSample, 5);

      buffer.clear();
      expect(buffer.totalSamples, 0);
      expect(buffer.discardedSamples, 0);
      expect(buffer.isEmpty, isTrue);
    });

    test('任意输入都限制绘制区间数且覆盖全局极值', () {
      final samples = Uint8List(1000);
      samples[10] = 0;
      samples[500] = 255;
      final buffer = WaveformBuffer(capacitySamples: 2000)..append(samples);

      final buckets = buffer.snapshot(maxBuckets: 17);

      expect(buckets, hasLength(17));
      expect(
        buckets.map((bucket) => bucket.minimum).reduce((a, b) => a < b ? a : b),
        0,
      );
      expect(
        buckets.map((bucket) => bucket.maximum).reduce((a, b) => a > b ? a : b),
        255,
      );
      expect(buckets.last.endSample, 999);
    });
  });
}
