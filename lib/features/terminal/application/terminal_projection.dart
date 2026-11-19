import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'terminal_view_state.dart';

/// 将顺序字节流投影为文本或 HEX 终端行。
///
/// 文本投影会暂存不完整的 UTF-8 尾部，确保多字节字符跨批次时仍能正确解码。
final class TerminalProjection {
  /// 创建受行数上限约束的终端投影。
  TerminalProjection({required this.maxLines, required this.hexBytesPerLine}) {
    if (maxLines <= 0) {
      throw ArgumentError.value(maxLines, 'maxLines', '最大行数必须大于 0');
    }
    if (hexBytesPerLine <= 0 || hexBytesPerLine > 64) {
      throw ArgumentError.value(
        hexBytesPerLine,
        'hexBytesPerLine',
        'HEX 每行字节数必须在 1 到 64 之间',
      );
    }
  }

  /// 每种视图最多保留的行数。
  final int maxLines;

  /// HEX 每行字节数。
  final int hexBytesPerLine;

  final Queue<TerminalLine> _textLines = Queue<TerminalLine>();
  final Queue<TerminalLine> _hexLines = Queue<TerminalLine>();
  final StringBuffer _currentText = StringBuffer();
  final List<int> _pendingUtf8 = <int>[];
  final List<int> _currentHexBytes = <int>[];

  DateTime? _currentTextTimestamp;
  DateTime? _currentHexTimestamp;
  int _textOffset = 0;
  int _hexOffset = 0;
  int _currentHexLineOffset = 0;
  int _textDroppedLines = 0;
  int _hexDroppedLines = 0;
  bool _previousWasCarriageReturn = false;

  /// 追加一批原始字节。
  void append(Uint8List bytes, DateTime receivedAt) {
    if (bytes.isEmpty) {
      return;
    }
    _appendHex(bytes, receivedAt);
    _appendText(bytes, receivedAt);
  }

  /// 返回指定模式的稳定快照。
  List<TerminalLine> snapshot(TerminalDisplayMode mode) {
    return switch (mode) {
      TerminalDisplayMode.text => _snapshotText(),
      TerminalDisplayMode.hex => _snapshotHex(),
    };
  }

  /// 指定模式因行数上限累计丢弃的行数。
  int droppedLines(TerminalDisplayMode mode) {
    return switch (mode) {
      TerminalDisplayMode.text => _textDroppedLines,
      TerminalDisplayMode.hex => _hexDroppedLines,
    };
  }

  /// 当前仍等待后续 UTF-8 字节的数量。
  int get pendingUtf8Bytes => _pendingUtf8.length;

  /// 清空所有投影和历史偏移。
  void clear() {
    _textLines.clear();
    _hexLines.clear();
    _currentText.clear();
    _pendingUtf8.clear();
    _currentHexBytes.clear();
    _currentTextTimestamp = null;
    _currentHexTimestamp = null;
    _textOffset = 0;
    _hexOffset = 0;
    _currentHexLineOffset = 0;
    _textDroppedLines = 0;
    _hexDroppedLines = 0;
    _previousWasCarriageReturn = false;
  }

  void _appendText(Uint8List bytes, DateTime receivedAt) {
    if (bytes.isNotEmpty) {
      _currentTextTimestamp ??= receivedAt;
    }
    final combined = Uint8List(_pendingUtf8.length + bytes.length)
      ..setRange(0, _pendingUtf8.length, _pendingUtf8)
      ..setRange(
        _pendingUtf8.length,
        _pendingUtf8.length + bytes.length,
        bytes,
      );
    final completeLength = _completeUtf8Length(combined);
    _pendingUtf8
      ..clear()
      ..addAll(combined.skip(completeLength));
    if (completeLength == 0) {
      return;
    }

    final decoded = utf8.decode(
      Uint8List.sublistView(combined, 0, completeLength),
      allowMalformed: true,
    );
    for (final rune in decoded.runes) {
      if (rune == 0x0D) {
        _ensureTextTimestamp(receivedAt);
        _commitTextLine();
        _previousWasCarriageReturn = true;
        continue;
      }
      if (rune == 0x0A) {
        if (_previousWasCarriageReturn) {
          _previousWasCarriageReturn = false;
          continue;
        }
        _ensureTextTimestamp(receivedAt);
        _commitTextLine();
        continue;
      }

      _previousWasCarriageReturn = false;
      _ensureTextTimestamp(receivedAt);
      _currentText.writeCharCode(rune);
    }
    _textOffset += completeLength;
  }

  void _appendHex(Uint8List bytes, DateTime receivedAt) {
    for (final byte in bytes) {
      if (_currentHexBytes.isEmpty) {
        _currentHexTimestamp = receivedAt;
        _currentHexLineOffset = _hexOffset;
      }
      _currentHexBytes.add(byte);
      _hexOffset++;
      if (_currentHexBytes.length == hexBytesPerLine) {
        _commitHexLine();
      }
    }
  }

  void _ensureTextTimestamp(DateTime receivedAt) {
    _currentTextTimestamp ??= receivedAt;
  }

  void _commitTextLine() {
    final timestamp = _currentTextTimestamp;
    if (timestamp == null) {
      return;
    }
    _textLines.add(
      TerminalLine(
        text: _currentText.toString(),
        timestamp: timestamp,
        byteOffset: _textOffset,
      ),
    );
    _currentText.clear();
    _currentTextTimestamp = null;
    _trimQueue(_textLines, isText: true);
  }

  void _commitHexLine() {
    final timestamp = _currentHexTimestamp;
    if (timestamp == null) {
      return;
    }
    _hexLines.add(
      _buildHexLine(_currentHexBytes, _currentHexLineOffset, timestamp),
    );
    _currentHexBytes.clear();
    _currentHexTimestamp = null;
    _trimQueue(_hexLines, isText: false);
  }

  List<TerminalLine> _snapshotText() {
    final result = <TerminalLine>[
      ..._textLines,
      if (_currentText.isNotEmpty)
        TerminalLine(
          text: _currentText.toString(),
          timestamp: _currentTextTimestamp!,
          byteOffset: _textOffset,
        ),
    ];
    return _boundedSnapshot(result);
  }

  List<TerminalLine> _snapshotHex() {
    final result = <TerminalLine>[
      ..._hexLines,
      if (_currentHexBytes.isNotEmpty)
        _buildHexLine(
          _currentHexBytes,
          _currentHexLineOffset,
          _currentHexTimestamp!,
        ),
    ];
    return _boundedSnapshot(result);
  }

  List<TerminalLine> _boundedSnapshot(List<TerminalLine> lines) {
    final visible = lines.length <= maxLines
        ? lines
        : lines.sublist(lines.length - maxLines);
    return List<TerminalLine>.unmodifiable(visible);
  }

  void _trimQueue(Queue<TerminalLine> queue, {required bool isText}) {
    while (queue.length > maxLines) {
      queue.removeFirst();
      if (isText) {
        _textDroppedLines++;
      } else {
        _hexDroppedLines++;
      }
    }
  }

  TerminalLine _buildHexLine(List<int> bytes, int offset, DateTime timestamp) {
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ')
        .padRight(hexBytesPerLine * 3 - 1);
    final ascii = bytes
        .map(
          (byte) =>
              byte >= 0x20 && byte <= 0x7E ? String.fromCharCode(byte) : '.',
        )
        .join();
    final offsetText = offset.toRadixString(16).padLeft(8, '0').toUpperCase();
    return TerminalLine(
      text: '$offsetText  $hex  |$ascii|',
      timestamp: timestamp,
      byteOffset: offset,
    );
  }

  int _completeUtf8Length(Uint8List bytes) {
    if (bytes.isEmpty) {
      return 0;
    }

    var leadIndex = bytes.length - 1;
    var continuationBytes = 0;
    while (leadIndex >= 0 &&
        (bytes[leadIndex] & 0xC0) == 0x80 &&
        continuationBytes < 3) {
      continuationBytes++;
      leadIndex--;
    }
    if (leadIndex < 0) {
      return bytes.length;
    }

    final lead = bytes[leadIndex];
    final expectedLength = switch (lead) {
      >= 0xC2 && <= 0xDF => 2,
      >= 0xE0 && <= 0xEF => 3,
      >= 0xF0 && <= 0xF4 => 4,
      _ => null,
    };
    if (expectedLength == null) {
      return bytes.length;
    }

    final actualLength = bytes.length - leadIndex;
    return actualLength < expectedLength ? leadIndex : bytes.length;
  }
}
