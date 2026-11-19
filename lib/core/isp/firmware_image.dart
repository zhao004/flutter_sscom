import 'dart:typed_data';

/// 固件中的一段连续地址数据。
final class FirmwareSegment {
  /// 创建固件段，并复制输入字节。
  FirmwareSegment({required this.startAddress, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes) {
    if (startAddress < 0 || startAddress > 0xFFFFFFFF) {
      throw ArgumentError.value(startAddress, 'startAddress', '固件地址超出 32 位范围');
    }
    if (this.bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', '固件段不能为空');
    }
    if (startAddress + this.bytes.length > 0x100000000) {
      throw ArgumentError.value(startAddress, 'startAddress', '固件段跨越 32 位地址上界');
    }
  }

  /// 段首地址。
  final int startAddress;

  /// 段数据副本。
  final Uint8List bytes;

  /// 段尾后一地址。
  int get endAddressExclusive => startAddress + bytes.length;
}

/// 严格解析后的固件镜像。
final class FirmwareImage {
  /// 创建固件镜像。
  ///
  /// 各段必须非空、按地址排序且互不重叠；相邻段会由解析器预先合并。
  FirmwareImage({required List<FirmwareSegment> segments, this.entryPoint})
    : segments = List<FirmwareSegment>.unmodifiable(segments) {
    if (this.segments.isEmpty) {
      throw ArgumentError.value(segments, 'segments', '固件镜像不能为空');
    }
    var previousEnd = -1;
    for (final segment in this.segments) {
      if (segment.startAddress < previousEnd) {
        throw ArgumentError.value(segments, 'segments', '固件段不能重叠');
      }
      previousEnd = segment.endAddressExclusive;
    }
    if (entryPoint != null && (entryPoint! < 0 || entryPoint! > 0xFFFFFFFF)) {
      throw ArgumentError.value(entryPoint, 'entryPoint', '入口地址超出 32 位范围');
    }
  }

  /// 按地址升序排列的连续固件段。
  final List<FirmwareSegment> segments;

  /// Intel HEX 声明的入口地址。
  final int? entryPoint;

  /// 最低数据地址。
  int get minimumAddress => segments.first.startAddress;

  /// 最高数据地址后一地址。
  int get maximumAddressExclusive => segments.last.endAddressExclusive;

  /// 所有段的数据字节总数。
  int get totalBytes =>
      segments.fold<int>(0, (total, segment) => total + segment.bytes.length);

  /// 镜像覆盖的地址区间数。
  int get segmentCount => segments.length;
}
