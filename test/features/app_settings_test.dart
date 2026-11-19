import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppSettings', () {
    test('完整 JSON 往返保留串口、终端、发送和迁移数据', () {
      final settings = AppSettings(
        serial: const SerialConfig(
          portName: 'COM7',
          baudRate: 921600,
          dataBits: SerialDataBits.seven,
          stopBits: SerialStopBits.two,
          parity: SerialParity.even,
          flowControl: SerialFlowControl.rtsCts,
          initialDtr: true,
          initialRts: true,
        ),
        terminal: const TerminalPreferences(
          displayMode: TerminalDisplayMode.hex,
          showTimestamp: true,
          autoScroll: false,
          packetSplitEnabled: true,
          packetSplitTimeoutMs: 35,
          maxRawBytes: 500000,
        ),
        send: const SendPreferences(
          mode: SendInputMode.hex,
          textDraft: 'text',
          hexDraft: '01 02',
          appendCrLf: true,
          checksumMode: LegacyChecksumMode.crc32,
          checksumStartByte: 2,
          checksumTrailingByteCount: 1,
          repeatIntervalMs: 250,
        ),
        multiSend: const <MultiSendEntry>[
          MultiSendEntry(
            index: 1,
            mode: SendInputMode.ansiText,
            payload: 'hello',
            enabled: true,
            name: '问候',
            intervalMs: 1000,
          ),
        ],
        network: const NetworkPreferences(
          mode: TransportMode.tcpClient,
          safetyMode: NetworkSafetyMode.rawDebug,
          bindAddress: '0.0.0.0',
          remoteHost: '127.0.0.1',
          remotePort: 6000,
          localPort: 6001,
          followRemoteEndpoint: false,
        ),
        window: const WindowPreferences(
          width: 1440,
          height: 900,
          left: 10,
          top: 20,
        ),
        locale: 'zh-CN',
        theme: AppThemeMode.dark,
        migration: SettingsMigrationMetadata(
          sourceName: 'sscom51.ini',
          migratedAtUtc: DateTime.utc(2026, 11, 12),
          warnings: const <String>['unknown-key'],
        ),
      );

      final restored = AppSettings.fromJson(settings.toJson());

      expect(restored.schemaVersion, currentSettingsSchemaVersion);
      expect(restored.serial.portName, 'COM7');
      expect(restored.serial.dataBits, SerialDataBits.seven);
      expect(restored.serial.flowControl, SerialFlowControl.rtsCts);
      expect(restored.terminal.displayMode, TerminalDisplayMode.hex);
      expect(restored.terminal.maxRawBytes, 500000);
      expect(restored.send.mode, SendInputMode.hex);
      expect(restored.send.checksumMode, LegacyChecksumMode.crc32);
      expect(restored.multiSend.single.name, '问候');
      expect(restored.network.remotePort, 6000);
      expect(restored.network.mode, TransportMode.tcpClient);
      expect(restored.network.safetyMode, NetworkSafetyMode.rawDebug);
      expect(restored.network.bindAddress, '0.0.0.0');
      expect(restored.network.followRemoteEndpoint, isFalse);
      expect(restored.window.width, 1440);
      expect(restored.theme, AppThemeMode.dark);
      expect(restored.migration?.warnings, <String>['unknown-key']);
    });

    test('缺失或非法字段回退安全默认值', () {
      final restored = AppSettings.fromJson(<String, dynamic>{
        'schemaVersion': 1,
        'serial': <String, dynamic>{'baudRate': -1, 'parity': 'unknown'},
        'terminal': <String, dynamic>{'maxRawBytes': 0},
        'send': <String, dynamic>{'checksumMode': 'bad', 'appendCrLf': 'Y'},
      });

      expect(restored.serial.portName, '');
      expect(restored.serial.baudRate, 115200);
      expect(restored.serial.parity, SerialParity.none);
      expect(restored.terminal.maxRawBytes, 256 * 1024);
      expect(restored.send.checksumMode, LegacyChecksumMode.none);
      expect(restored.send.appendCrLf, isFalse);
      expect(restored.network.mode, TransportMode.serial);
      expect(restored.network.safetyMode, NetworkSafetyMode.safe);
      expect(restored.network.bindAddress, '127.0.0.1');
      expect(restored.network.followRemoteEndpoint, isTrue);
    });

    test('拒绝未来设置版本', () {
      expect(
        () => AppSettings.fromJson(<String, dynamic>{'schemaVersion': 99}),
        throwsFormatException,
      );
    });
  });
}
