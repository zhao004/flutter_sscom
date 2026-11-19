import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';

/// 当前设置 JSON 架构版本。
const int currentSettingsSchemaVersion = 1;

/// 新版主题模式。
enum AppThemeMode { system, light, dark }

/// 终端偏好。
final class TerminalPreferences {
  /// 创建终端偏好。
  const TerminalPreferences({
    this.displayMode = TerminalDisplayMode.text,
    this.showTimestamp = false,
    this.autoScroll = true,
    this.packetSplitEnabled = false,
    this.packetSplitTimeoutMs = 20,
    this.maxRawBytes = 256 * 1024,
  });

  final TerminalDisplayMode displayMode;
  final bool showTimestamp;
  final bool autoScroll;
  final bool packetSplitEnabled;
  final int packetSplitTimeoutMs;
  final int maxRawBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'displayMode': displayMode.name,
    'showTimestamp': showTimestamp,
    'autoScroll': autoScroll,
    'packetSplitEnabled': packetSplitEnabled,
    'packetSplitTimeoutMs': packetSplitTimeoutMs,
    'maxRawBytes': maxRawBytes,
  };
}

/// 发送偏好与最近草稿。
final class SendPreferences {
  /// 创建发送偏好。
  const SendPreferences({
    this.mode = SendInputMode.ansiText,
    this.textDraft = '',
    this.hexDraft = '',
    this.appendCrLf = false,
    this.checksumMode = LegacyChecksumMode.none,
    this.checksumStartByte = 1,
    this.checksumTrailingByteCount = 0,
    this.repeatIntervalMs = 1000,
  });

  final SendInputMode mode;
  final String textDraft;
  final String hexDraft;
  final bool appendCrLf;
  final LegacyChecksumMode checksumMode;
  final int checksumStartByte;
  final int checksumTrailingByteCount;
  final int repeatIntervalMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'textDraft': textDraft,
    'hexDraft': hexDraft,
    'appendCrLf': appendCrLf,
    'checksumMode': checksumMode.name,
    'checksumStartByte': checksumStartByte,
    'checksumTrailingByteCount': checksumTrailingByteCount,
    'repeatIntervalMs': repeatIntervalMs,
  };
}

/// 多字符串发送条目。
final class MultiSendEntry {
  /// 创建多字符串条目。
  const MultiSendEntry({
    required this.index,
    required this.mode,
    required this.payload,
    required this.enabled,
    required this.name,
    required this.intervalMs,
  });

  final int index;
  final SendInputMode mode;
  final String payload;
  final bool enabled;
  final String name;
  final int intervalMs;

  /// 返回替换部分字段后的条目。
  MultiSendEntry copyWith({
    int? index,
    SendInputMode? mode,
    String? payload,
    bool? enabled,
    String? name,
    int? intervalMs,
  }) {
    return MultiSendEntry(
      index: index ?? this.index,
      mode: mode ?? this.mode,
      payload: payload ?? this.payload,
      enabled: enabled ?? this.enabled,
      name: name ?? this.name,
      intervalMs: intervalMs ?? this.intervalMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'mode': mode.name,
    'payload': payload,
    'enabled': enabled,
    'name': name,
    'intervalMs': intervalMs,
  };
}

/// 网络设置占位，Phase 3 使用。
final class NetworkPreferences {
  /// 创建网络设置。
  const NetworkPreferences({
    this.mode = TransportMode.serial,
    this.safetyMode = NetworkSafetyMode.safe,
    this.bindAddress = '127.0.0.1',
    this.remoteHost = '',
    this.remotePort = 5001,
    this.localPort = 5001,
    this.followRemoteEndpoint = true,
  });

  /// 连接模式。
  final TransportMode mode;

  /// 网络调试安全模式。
  final NetworkSafetyMode safetyMode;

  /// TCP 服务端或 UDP 的本地监听地址。
  final String bindAddress;

  /// TCP/UDP 远端主机。
  final String remoteHost;

  /// TCP/UDP 远端端口。
  final int remotePort;

  /// TCP 服务端或 UDP 的本地端口。
  final int localPort;

  /// UDP 是否跟随最近数据报来源。
  final bool followRemoteEndpoint;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode.name,
    'safetyMode': safetyMode.name,
    'bindAddress': bindAddress,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
    'localPort': localPort,
    'followRemoteEndpoint': followRemoteEndpoint,
  };
}

/// 窗口几何设置。
final class WindowPreferences {
  /// 创建窗口设置。
  const WindowPreferences({
    this.width = 1113,
    this.height = 857,
    this.left = 184,
    this.top = 89,
  });

  final int width;
  final int height;
  final int left;
  final int top;

  Map<String, Object?> toJson() => <String, Object?>{
    'width': width,
    'height': height,
    'left': left,
    'top': top,
  };
}

/// 旧 INI 迁移元数据。
final class SettingsMigrationMetadata {
  /// 创建迁移元数据。
  const SettingsMigrationMetadata({
    required this.sourceName,
    required this.migratedAtUtc,
    required this.warnings,
  });

  final String sourceName;
  final DateTime migratedAtUtc;
  final List<String> warnings;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceName': sourceName,
    'migratedAtUtc': migratedAtUtc.toUtc().toIso8601String(),
    'warnings': warnings,
  };
}

/// 新版强类型应用设置。
final class AppSettings {
  /// 创建设置。
  AppSettings({
    this.schemaVersion = currentSettingsSchemaVersion,
    this.serial = const SerialConfig(portName: '', baudRate: 115200),
    this.terminal = const TerminalPreferences(),
    this.send = const SendPreferences(),
    List<MultiSendEntry> multiSend = const <MultiSendEntry>[],
    this.network = const NetworkPreferences(),
    this.window = const WindowPreferences(),
    this.locale = 'zh-CN',
    this.theme = AppThemeMode.system,
    this.migration,
  }) : multiSend = List<MultiSendEntry>.unmodifiable(multiSend);

  /// 默认设置。
  factory AppSettings.defaults() => AppSettings();

  final int schemaVersion;
  final SerialConfig serial;
  final TerminalPreferences terminal;
  final SendPreferences send;
  final List<MultiSendEntry> multiSend;
  final NetworkPreferences network;
  final WindowPreferences window;
  final String locale;
  final AppThemeMode theme;
  final SettingsMigrationMetadata? migration;

  /// 返回替换部分字段后的设置。
  AppSettings copyWith({
    int? schemaVersion,
    SerialConfig? serial,
    TerminalPreferences? terminal,
    SendPreferences? send,
    List<MultiSendEntry>? multiSend,
    NetworkPreferences? network,
    WindowPreferences? window,
    String? locale,
    AppThemeMode? theme,
    SettingsMigrationMetadata? migration,
  }) {
    return AppSettings(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      serial: serial ?? this.serial,
      terminal: terminal ?? this.terminal,
      send: send ?? this.send,
      multiSend: multiSend ?? this.multiSend,
      network: network ?? this.network,
      window: window ?? this.window,
      locale: locale ?? this.locale,
      theme: theme ?? this.theme,
      migration: migration ?? this.migration,
    );
  }

  /// 序列化为 JSON 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'serial': <String, Object?>{
      'portName': serial.portName,
      'baudRate': serial.baudRate,
      'dataBits': serial.dataBits.name,
      'stopBits': serial.stopBits.name,
      'parity': serial.parity.name,
      'flowControl': serial.flowControl.name,
      'initialDtr': serial.initialDtr,
      'initialRts': serial.initialRts,
    },
    'terminal': terminal.toJson(),
    'send': send.toJson(),
    'multiSend': multiSend.map((entry) => entry.toJson()).toList(),
    'network': network.toJson(),
    'window': window.toJson(),
    'locale': locale,
    'theme': theme.name,
    if (migration != null) 'migration': migration!.toJson(),
  };

  /// 从 JSON 对象恢复设置。
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final version = _readInt(
      json['schemaVersion'],
      currentSettingsSchemaVersion,
      minimum: 1,
    );
    if (version > currentSettingsSchemaVersion) {
      throw FormatException('不支持的设置版本：$version');
    }

    final serialJson = _readMap(json['serial']);
    final terminalJson = _readMap(json['terminal']);
    final sendJson = _readMap(json['send']);
    final networkJson = _readMap(json['network']);
    final windowJson = _readMap(json['window']);

    return AppSettings(
      schemaVersion: version,
      serial: SerialConfig(
        portName: _readString(serialJson['portName'], ''),
        baudRate: _readInt(serialJson['baudRate'], 115200, minimum: 1),
        dataBits: _readEnum(
          serialJson['dataBits'],
          SerialDataBits.values,
          SerialDataBits.eight,
        ),
        stopBits: _readEnum(
          serialJson['stopBits'],
          SerialStopBits.values,
          SerialStopBits.one,
        ),
        parity: _readEnum(
          serialJson['parity'],
          SerialParity.values,
          SerialParity.none,
        ),
        flowControl: _readEnum(
          serialJson['flowControl'],
          SerialFlowControl.values,
          SerialFlowControl.none,
        ),
        initialDtr: _readBool(serialJson['initialDtr'], false),
        initialRts: _readBool(serialJson['initialRts'], false),
      ),
      terminal: TerminalPreferences(
        displayMode: _readEnum(
          terminalJson['displayMode'],
          TerminalDisplayMode.values,
          TerminalDisplayMode.text,
        ),
        showTimestamp: _readBool(terminalJson['showTimestamp'], false),
        autoScroll: _readBool(terminalJson['autoScroll'], true),
        packetSplitEnabled: _readBool(
          terminalJson['packetSplitEnabled'],
          false,
        ),
        packetSplitTimeoutMs: _readInt(
          terminalJson['packetSplitTimeoutMs'],
          20,
          minimum: 1,
        ),
        maxRawBytes: _readInt(
          terminalJson['maxRawBytes'],
          256 * 1024,
          minimum: 1,
        ),
      ),
      send: SendPreferences(
        mode: _readEnum(
          sendJson['mode'],
          SendInputMode.values,
          SendInputMode.ansiText,
        ),
        textDraft: _readString(sendJson['textDraft'], ''),
        hexDraft: _readString(sendJson['hexDraft'], ''),
        appendCrLf: _readBool(sendJson['appendCrLf'], false),
        checksumMode: _readEnum(
          sendJson['checksumMode'],
          LegacyChecksumMode.values,
          LegacyChecksumMode.none,
        ),
        checksumStartByte: _readInt(
          sendJson['checksumStartByte'],
          1,
          minimum: 1,
        ),
        checksumTrailingByteCount: _readInt(
          sendJson['checksumTrailingByteCount'],
          0,
          minimum: 0,
        ),
        repeatIntervalMs: _readInt(
          sendJson['repeatIntervalMs'],
          1000,
          minimum: 1,
        ),
      ),
      multiSend: _readList(json['multiSend'])
          .whereType<Map<String, dynamic>>()
          .map(_multiSendFromJson)
          .toList(growable: false),
      network: NetworkPreferences(
        mode: _readEnum(
          networkJson['mode'],
          TransportMode.values,
          TransportMode.serial,
        ),
        safetyMode: _readEnum(
          networkJson['safetyMode'],
          NetworkSafetyMode.values,
          NetworkSafetyMode.safe,
        ),
        bindAddress: _readString(networkJson['bindAddress'], '127.0.0.1'),
        remoteHost: _readString(networkJson['remoteHost'], ''),
        remotePort: _readInt(
          networkJson['remotePort'],
          5001,
          minimum: 1,
          maximum: 65535,
        ),
        localPort: _readInt(
          networkJson['localPort'],
          5001,
          minimum: 1,
          maximum: 65535,
        ),
        followRemoteEndpoint: _readBool(
          networkJson['followRemoteEndpoint'],
          true,
        ),
      ),
      window: WindowPreferences(
        width: _readInt(windowJson['width'], 1113, minimum: 320),
        height: _readInt(windowJson['height'], 857, minimum: 240),
        left: _readInt(windowJson['left'], 184),
        top: _readInt(windowJson['top'], 89),
      ),
      locale: _readString(json['locale'], 'zh-CN'),
      theme: _readEnum(json['theme'], AppThemeMode.values, AppThemeMode.system),
      migration: _migrationFromJson(json['migration']),
    );
  }

  static MultiSendEntry _multiSendFromJson(Map<String, dynamic> json) {
    return MultiSendEntry(
      index: _readInt(json['index'], 1, minimum: 1, maximum: 99),
      mode: _readEnum(
        json['mode'],
        SendInputMode.values,
        SendInputMode.ansiText,
      ),
      payload: _readString(json['payload'], ''),
      enabled: _readBool(json['enabled'], false),
      name: _readString(json['name'], ''),
      intervalMs: _readInt(json['intervalMs'], 1000, minimum: 1),
    );
  }

  static SettingsMigrationMetadata? _migrationFromJson(Object? value) {
    final json = _readMap(value);
    final sourceName = _readString(json['sourceName'], '');
    final migratedAt = DateTime.tryParse(
      _readString(json['migratedAtUtc'], ''),
    );
    if (sourceName.isEmpty || migratedAt == null) {
      return null;
    }
    return SettingsMigrationMetadata(
      sourceName: sourceName,
      migratedAtUtc: migratedAt.toUtc(),
      warnings: _readList(json['warnings'])
          .map((warning) => warning.toString())
          .toList(growable: false),
    );
  }
}

Map<String, dynamic> _readMap(Object? value) {
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

List<dynamic> _readList(Object? value) {
  return value is List<dynamic> ? value : const <dynamic>[];
}

String _readString(Object? value, String fallback) {
  return value is String ? value : fallback;
}

bool _readBool(Object? value, bool fallback) {
  return value is bool ? value : fallback;
}

int _readInt(
  Object? value,
  int fallback, {
  int minimum = -0x7FFFFFFF,
  int maximum = 0x7FFFFFFF,
}) {
  if (value is! num) {
    return fallback;
  }
  final integer = value.toInt();
  if (integer < minimum || integer > maximum) {
    return fallback;
  }
  return integer;
}

T _readEnum<T extends Enum>(Object? value, List<T> values, T fallback) {
  if (value is String) {
    for (final item in values) {
      if (item.name == value) {
        return item;
      }
    }
  }
  return fallback;
}
