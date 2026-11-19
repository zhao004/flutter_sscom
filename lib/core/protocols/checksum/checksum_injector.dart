import 'dart:typed_data';

import 'legacy_checksum.dart';

/// 校验插入位置和算法配置。
final class ChecksumSpec {
  /// 创建校验插入配置。
  ///
  /// [startByte] 使用 1-based 字节位置；[trailingByteCount] 表示从消息末尾
  /// 排除并用于放置校验的字节数，0 表示追加在末尾。
  const ChecksumSpec({
    required this.mode,
    required this.startByte,
    this.trailingByteCount = 0,
  });

  /// 校验算法。
  final LegacyChecksumMode mode;

  /// 参与校验的第一个字节位置，从 1 开始。
  final int startByte;

  /// 从消息末尾排除的字节数。
  final int trailingByteCount;
}

/// 表示校验区间为空或越过消息边界。
final class ChecksumRangeException implements Exception {
  /// 创建校验范围异常。
  const ChecksumRangeException({
    required this.payloadLength,
    required this.startByte,
    required this.trailingByteCount,
  });

  /// 原始消息长度。
  final int payloadLength;

  /// 请求的 1-based 起始位置。
  final int startByte;

  /// 请求的尾部排除字节数。
  final int trailingByteCount;

  @override
  String toString() {
    return 'ChecksumRangeException(payloadLength: $payloadLength, '
        'startByte: $startByte, trailingByteCount: $trailingByteCount)';
  }
}

/// 将旧版校验字节插入发送消息。
final class ChecksumInjector {
  const ChecksumInjector._();

  /// 计算并插入校验字节。
  ///
  /// [ChecksumSpec.mode] 为 `none` 时返回消息副本。其他模式要求校验区间至少
  /// 包含一个字节，否则抛出 [ChecksumRangeException]。
  static Uint8List apply(Uint8List payload, ChecksumSpec spec) {
    if (spec.mode == LegacyChecksumMode.none) {
      return Uint8List.fromList(payload);
    }
    if (spec.trailingByteCount < 0) {
      throw ChecksumRangeException(
        payloadLength: payload.length,
        startByte: spec.startByte,
        trailingByteCount: spec.trailingByteCount,
      );
    }

    final selectionEnd = payload.length - spec.trailingByteCount;
    final selectionStart = spec.startByte - 1;
    if (selectionStart < 0 ||
        selectionEnd < 0 ||
        selectionStart >= selectionEnd ||
        selectionEnd > payload.length) {
      throw ChecksumRangeException(
        payloadLength: payload.length,
        startByte: spec.startByte,
        trailingByteCount: spec.trailingByteCount,
      );
    }

    final checksum = LegacyChecksum.calculate(
      spec.mode,
      Uint8List.sublistView(payload, selectionStart, selectionEnd),
    );
    final builder = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(payload, 0, selectionEnd))
      ..add(checksum)
      ..add(Uint8List.sublistView(payload, selectionEnd));
    return builder.takeBytes();
  }
}
