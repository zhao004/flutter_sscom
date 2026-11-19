import 'package:flutter_sscom/core/buffers/buffers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BufferPolicy', () {
    test('默认值满足 30 FPS 与有界终端策略', () {
      final policy = BufferPolicy();

      expect(policy.maxRawBytes, 256 * 1024);
      expect(policy.maxDisplayLines, 5000);
      expect(policy.flushInterval, const Duration(milliseconds: 33));
      expect(policy.maxPendingBytes, 16 * 1024);
      expect(policy.hexBytesPerLine, 16);
    });

    test('拒绝非法容量、窗口和 HEX 行宽', () {
      expect(() => BufferPolicy(maxRawBytes: 0), throwsArgumentError);
      expect(() => BufferPolicy(maxDisplayLines: 0), throwsArgumentError);
      expect(
        () => BufferPolicy(flushInterval: Duration.zero),
        throwsArgumentError,
      );
      expect(() => BufferPolicy(maxPendingBytes: 0), throwsArgumentError);
      expect(() => BufferPolicy(hexBytesPerLine: 0), throwsArgumentError);
      expect(() => BufferPolicy(hexBytesPerLine: 65), throwsArgumentError);
    });
  });
}
