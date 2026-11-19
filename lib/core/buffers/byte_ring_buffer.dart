import 'dart:math' as math;
import 'dart:typed_data';

/// 固定容量的字节环形缓冲。
///
/// 写入超过容量时保留最新字节，适用于终端接收数据的有界累积。
final class ByteRingBuffer {
  /// 创建指定容量的缓冲。
  ///
  /// [capacityBytes] 必须大于 0。
  ByteRingBuffer(this.capacityBytes)
    : _storage = Uint8List(_validateCapacity(capacityBytes));

  /// 最大保存字节数。
  final int capacityBytes;

  final Uint8List _storage;
  int _head = 0;
  int _length = 0;
  int _discardedBytes = 0;

  /// 当前保存的字节数。
  int get length => _length;

  /// 缓冲是否为空。
  bool get isEmpty => _length == 0;

  /// 因容量限制累计丢弃的字节数。
  int get discardedBytes => _discardedBytes;

  /// 追加字节并返回本次被丢弃的旧数据数量。
  int append(Uint8List bytes) {
    if (bytes.isEmpty) {
      return 0;
    }

    var dropped = 0;
    if (bytes.length >= capacityBytes) {
      dropped = _length + bytes.length - capacityBytes;
      _storage.setRange(0, capacityBytes, bytes, bytes.length - capacityBytes);
      _head = 0;
      _length = capacityBytes;
      _discardedBytes += dropped;
      return dropped;
    }

    final overflow = _length + bytes.length - capacityBytes;
    if (overflow > 0) {
      _head = (_head + overflow) % capacityBytes;
      _length -= overflow;
      dropped = overflow;
    }

    final writeIndex = (_head + _length) % capacityBytes;
    final firstPartLength = math.min(bytes.length, capacityBytes - writeIndex);
    _storage.setRange(writeIndex, writeIndex + firstPartLength, bytes);
    if (firstPartLength < bytes.length) {
      _storage.setRange(
        0,
        bytes.length - firstPartLength,
        bytes,
        firstPartLength,
      );
    }

    _length += bytes.length;
    _discardedBytes += dropped;
    return dropped;
  }

  /// 返回当前内容的独立副本。
  Uint8List snapshot() {
    if (_length == 0) {
      return Uint8List(0);
    }
    final result = Uint8List(_length);
    final firstPartLength = math.min(_length, capacityBytes - _head);
    result.setRange(0, firstPartLength, _storage, _head);
    if (firstPartLength < _length) {
      result.setRange(firstPartLength, _length, _storage);
    }
    return result;
  }

  /// 清空内容，但保留累计丢弃计数。
  void clear() {
    _head = 0;
    _length = 0;
  }

  static int _validateCapacity(int capacityBytes) {
    if (capacityBytes <= 0) {
      throw ArgumentError.value(capacityBytes, 'capacityBytes', '容量必须大于 0');
    }
    return capacityBytes;
  }
}
