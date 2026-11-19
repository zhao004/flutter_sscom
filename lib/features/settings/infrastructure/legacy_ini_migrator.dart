import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';

import '../domain/app_settings.dart';

/// 旧 INI 迁移警告分类。
enum LegacyIniWarningCode {
  missingOptionalKeys('missing-optional-keys'),
  invalidEnum('invalid-enum'),
  invalidInteger('invalid-integer'),
  invalidBoolean('invalid-boolean'),
  invalidBuffer('invalid-buffer'),
  duplicateKey('duplicate-key'),
  unknownKey('unknown-key'),
  embeddedNul('embedded-nul'),
  missingFinalNewline('missing-final-newline'),
  invalidEncoding('invalid-encoding');

  const LegacyIniWarningCode(this.id);

  /// 稳定报告标识。
  final String id;
}

/// 单条迁移警告。
final class LegacyIniWarning {
  /// 创建迁移警告。
  const LegacyIniWarning({required this.code, this.key, required this.message});

  final LegacyIniWarningCode code;
  final String? key;
  final String message;
}

/// 旧 INI 迁移结果。
final class LegacyIniMigrationResult {
  /// 创建迁移结果。
  LegacyIniMigrationResult({
    required this.settings,
    required List<LegacyIniWarning> warnings,
    required Map<String, String> unknownEntries,
    required List<String> duplicateKeys,
  }) : warnings = List<LegacyIniWarning>.unmodifiable(warnings),
       unknownEntries = Map<String, String>.unmodifiable(unknownEntries),
       duplicateKeys = List<String>.unmodifiable(duplicateKeys);

  final AppSettings settings;
  final List<LegacyIniWarning> warnings;
  final Map<String, String> unknownEntries;
  final List<String> duplicateKeys;
}

/// 将旧版 `sscom51.ini` 转换为新版强类型设置。
final class LegacyIniMigrator {
  /// 创建迁移器。
  const LegacyIniMigrator();

  /// 解析旧 INI 字节。
  LegacyIniMigrationResult migrate(
    Uint8List bytes, {
    required String sourceName,
    DateTime? migratedAtUtc,
  }) {
    final warnings = <LegacyIniWarning>[];
    final unknownEntries = <String, String>{};
    final duplicateKeys = <String>[];
    final seenWarnings = <String>{};

    void addWarning(LegacyIniWarningCode code, String message, {String? key}) {
      final id = '${code.id}:${key ?? ''}:$message';
      if (seenWarnings.add(id)) {
        warnings.add(LegacyIniWarning(code: code, key: key, message: message));
      }
    }

    if (bytes.contains(0)) {
      addWarning(LegacyIniWarningCode.embeddedNul, '文件包含 NUL 字节，已从解析文本中移除');
    }
    if (bytes.isNotEmpty && bytes.last != 0x0A) {
      addWarning(LegacyIniWarningCode.missingFinalNewline, '文件末尾没有换行');
    }

    String text;
    try {
      text = _decodeText(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
      addWarning(
        LegacyIniWarningCode.invalidEncoding,
        '无法按 UTF-8 或 GBK 解码，已回退到 Latin-1',
      );
    }
    text = text.replaceAll('\u0000', '');

    final values = <String, String>{};
    final lines = text.split(RegExp(r'\r\n|\n|\r'));
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
        continue;
      }
      final equalsIndex = line.indexOf('=');
      if (equalsIndex <= 0) {
        continue;
      }
      final key = line.substring(0, equalsIndex).trim().toUpperCase();
      var value = line.substring(equalsIndex + 1);
      if (value.startsWith(',')) {
        value = value.substring(1);
      }

      if (!_isKnownKey(key)) {
        unknownEntries[key] = value;
        addWarning(LegacyIniWarningCode.unknownKey, '未识别的配置键', key: key);
        continue;
      }
      if (values.containsKey(key)) {
        duplicateKeys.add(key);
        addWarning(
          LegacyIniWarningCode.duplicateKey,
          '重复配置键，采用首次出现的值',
          key: key,
        );
        continue;
      }
      values[key] = value;
    }

    final missingKeys = <String>[
      'N1053',
      'N1055',
      'N1057',
      'N1059',
      'N1060',
      'N1061',
      'N1062',
      'N1067',
      'N1074',
      'N1075',
      'N1080',
      'N1081',
    ].where((key) => !values.containsKey(key)).toList(growable: false);
    if (missingKeys.isNotEmpty) {
      addWarning(
        LegacyIniWarningCode.missingOptionalKeys,
        '缺少可选配置键：${missingKeys.join(', ')}',
      );
    }

    int readInteger(
      String key,
      int fallback, {
      required int minimum,
      int? maximum,
    }) {
      final raw = values[key];
      if (raw == null || raw.trim().isEmpty) {
        return fallback;
      }
      final parsed = int.tryParse(raw.trim());
      if (parsed == null ||
          parsed < minimum ||
          (maximum != null && parsed > maximum)) {
        addWarning(
          LegacyIniWarningCode.invalidInteger,
          '整数无效或超出范围，使用默认值 $fallback',
          key: key,
        );
        return fallback;
      }
      return parsed;
    }

    bool readBoolean(String key, bool fallback) {
      final raw = values[key]?.trim().toUpperCase();
      return switch (raw) {
        'Y' || '1' => true,
        'N' || '0' => false,
        null || '' => fallback,
        _ => () {
          addWarning(
            LegacyIniWarningCode.invalidBoolean,
            '布尔值必须为 Y/N，使用默认值 ${fallback ? 'Y' : 'N'}',
            key: key,
          );
          return fallback;
        }(),
      };
    }

    SendInputMode readSendMode(String key, String fallbackRaw) {
      final raw = values[key]?.trim().toUpperCase();
      if (raw == null || raw.isEmpty) {
        return fallbackRaw == 'H' ? SendInputMode.hex : SendInputMode.ansiText;
      }
      return switch (raw) {
        'A' => SendInputMode.ansiText,
        'H' => SendInputMode.hex,
        _ => () {
          addWarning(
            LegacyIniWarningCode.invalidEnum,
            '发送模式必须为 A 或 H',
            key: key,
          );
          return SendInputMode.ansiText;
        }(),
      };
    }

    final connectionTarget = values['N1080']?.trim() ?? '';
    final networkMode = switch (connectionTarget) {
      '1' => TransportMode.tcpClient,
      '2' => TransportMode.tcpServer,
      '3' => TransportMode.udp,
      _ => TransportMode.serial,
    };
    final baudRate = readInteger('N1081', 115200, minimum: 1);
    var checksumIndex = 0;
    final checksumRaw = values['N1060']?.trim();
    if (checksumRaw != null && checksumRaw.isNotEmpty) {
      final parsed = int.tryParse(checksumRaw);
      if (parsed == null || parsed < 0 || parsed > 7) {
        addWarning(
          LegacyIniWarningCode.invalidEnum,
          '校验模式索引必须为 0 到 7，使用 None',
          key: 'N1060',
        );
      } else {
        checksumIndex = parsed;
      }
    }
    final checksumMode = LegacyChecksumMode.fromLegacyIndex(checksumIndex);
    final displayHex = readBoolean('N1059', false);
    final bufferValue = values['N1067']?.trim();
    const allowedBuffers = <int>{200000, 500000, 1000000, 2000000, 5000000};
    var maxRawBytes = 256 * 1024;
    if (bufferValue != null && bufferValue.isNotEmpty) {
      final parsed = int.tryParse(bufferValue);
      if (parsed == null || !allowedBuffers.contains(parsed)) {
        addWarning(
          LegacyIniWarningCode.invalidBuffer,
          '接收缓冲阈值不在支持范围内，使用 256 KiB',
          key: 'N1067',
        );
      } else {
        maxRawBytes = parsed;
      }
    }

    final sendMode = readSendMode('N1055', 'A');
    final textDraft = _decodeStorageEscapes(values['N1053'] ?? '');
    final hexDraft = _decodeStorageEscapes(values['N1054'] ?? '');
    final appendCrLf = readBoolean('N1057', false);
    final multiSend = _readMultiSendEntries(values, addWarning);
    final migratedAt = (migratedAtUtc ?? DateTime.now()).toUtc();
    final warningIds =
        warnings.map((warning) => warning.code.id).toSet().toList()..sort();

    final settings = AppSettings(
      serial: SerialConfig(
        portName: networkMode == TransportMode.serial ? connectionTarget : '',
        baudRate: baudRate,
        initialDtr: readBoolean('N1061', false),
        initialRts: readBoolean('N1062', false),
      ),
      terminal: TerminalPreferences(
        displayMode: displayHex
            ? TerminalDisplayMode.hex
            : TerminalDisplayMode.text,
        packetSplitEnabled: readBoolean('N1064', false),
        packetSplitTimeoutMs: readInteger('N1065', 20, minimum: 1),
        maxRawBytes: maxRawBytes,
      ),
      send: SendPreferences(
        mode: sendMode,
        textDraft: textDraft,
        hexDraft: hexDraft,
        appendCrLf: appendCrLf,
        checksumMode: checksumMode,
        checksumStartByte: readInteger('N1074', 1, minimum: 1),
        checksumTrailingByteCount: readInteger('N1075', 0, minimum: 0),
        repeatIntervalMs: readInteger('N1056', 1000, minimum: 1),
      ),
      multiSend: multiSend,
      network: NetworkPreferences(
        mode: networkMode,
        safetyMode: NetworkSafetyMode.safe,
        bindAddress: '127.0.0.1',
        remoteHost: values['N1068'] ?? '',
        remotePort: readInteger('N1069', 5001, minimum: 1, maximum: 65535),
        localPort: readInteger('N1070', 5001, minimum: 1, maximum: 65535),
        followRemoteEndpoint: true,
      ),
      window: WindowPreferences(
        width: readInteger('N1082', 1113, minimum: 320),
        height: readInteger('N1083', 857, minimum: 240),
        left: readInteger('N1084', 184, minimum: -0x7FFFFFFF),
        top: readInteger('N1085', 89, minimum: -0x7FFFFFFF),
      ),
      migration: SettingsMigrationMetadata(
        sourceName: sourceName,
        migratedAtUtc: migratedAt,
        warnings: warningIds,
      ),
    );

    return LegacyIniMigrationResult(
      settings: settings,
      warnings: warnings,
      unknownEntries: unknownEntries,
      duplicateKeys: duplicateKeys,
    );
  }

  List<MultiSendEntry> _readMultiSendEntries(
    Map<String, String> values,
    void Function(LegacyIniWarningCode code, String message, {String? key})
    addWarning,
  ) {
    final entries = <MultiSendEntry>[];
    for (var index = 1; index <= 99; index++) {
      final payloadRaw = values['N$index'];
      if (payloadRaw == null) {
        continue;
      }
      final separator = payloadRaw.indexOf(',');
      if (separator <= 0) {
        addWarning(
          LegacyIniWarningCode.invalidEnum,
          '多字符串发送内容缺少 A/H 前缀或逗号',
          key: 'N$index',
        );
        continue;
      }
      final modeRaw = payloadRaw.substring(0, separator).trim().toUpperCase();
      final mode = switch (modeRaw) {
        'A' => SendInputMode.ansiText,
        'H' => SendInputMode.hex,
        _ => null,
      };
      if (mode == null) {
        addWarning(
          LegacyIniWarningCode.invalidEnum,
          '多字符串发送模式必须为 A 或 H',
          key: 'N$index',
        );
        continue;
      }

      var enabled = false;
      var name = '';
      var intervalMs = 1000;
      final metadata = values['N${100 + index}'];
      if (metadata != null) {
        final firstComma = metadata.indexOf(',');
        final lastComma = metadata.lastIndexOf(',');
        if (firstComma >= 0 && lastComma > firstComma) {
          final enabledValue = int.tryParse(
            metadata.substring(0, firstComma).trim(),
          );
          if (enabledValue == null) {
            addWarning(
              LegacyIniWarningCode.invalidBoolean,
              '多字符串启用值无效，按禁用处理',
              key: 'N${100 + index}',
            );
          } else {
            enabled = enabledValue != 0;
          }
          name = metadata.substring(firstComma + 1, lastComma).trim();
          final interval = int.tryParse(
            metadata.substring(lastComma + 1).trim(),
          );
          if (interval == null || interval < 1) {
            addWarning(
              LegacyIniWarningCode.invalidInteger,
              '多字符串发送间隔无效，使用 1000 ms',
              key: 'N${100 + index}',
            );
          } else {
            intervalMs = interval;
          }
        }
      }

      entries.add(
        MultiSendEntry(
          index: index,
          mode: mode,
          payload: _decodeStorageEscapes(payloadRaw.substring(separator + 1)),
          enabled: enabled,
          name: name,
          intervalMs: intervalMs,
        ),
      );
    }
    return entries;
  }

  bool _isKnownKey(String key) {
    final match = RegExp(r'^N(\d+)$').firstMatch(key);
    if (match == null) {
      return false;
    }
    final number = int.tryParse(match.group(1)!);
    if (number == null) {
      return false;
    }
    return (number >= 1 && number <= 99) ||
        (number >= 101 && number <= 199) ||
        (number >= 1051 && number <= 1100);
  }

  String _decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return gbk.decode(bytes);
    }
  }

  String _decodeStorageEscapes(String value) {
    return value
        .replaceAll('\u0002', ',')
        .replaceAll('\u0003', '\r')
        .replaceAll('\u0004', '\n');
  }
}
