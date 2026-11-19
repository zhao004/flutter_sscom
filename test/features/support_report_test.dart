import 'dart:convert';
import 'dart:io';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/support/application/support_report_builder.dart';
import 'package:flutter_sscom/features/support/domain/app_release_info.dart';
import 'package:flutter_sscom/features/support/infrastructure/release_manifest_loader.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('支持诊断', () {
    test('发布清单读取有效字段并在损坏时安全回退', () async {
      final directory = Directory(
        '.cache/test-support/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final manifest = File('${directory.path}/release-manifest.json');
      await manifest.writeAsString(
        jsonEncode(<String, Object?>{
          'product': 'SSCOM',
          'version': '1.2.3',
          'buildNumber': 7,
          'displayVersion': '1.2.3+7',
          'channel': 'beta',
          'serialBackend': 'libserialport',
          'codeSigning': 'signed-sha256-timestamped',
          'hardwareValidation': 'pending',
          'ispRealHardwareEnabled': false,
          'ispNote': 'HIL pending',
        }),
        flush: true,
      );

      final release = await loadAppReleaseInfoFromFile(manifest);

      expect(release.manifestLoaded, isTrue);
      expect(release.version, '1.2.3');
      expect(release.buildNumber, '7');
      expect(release.displayVersion, '1.2.3+7');
      expect(release.serialBackend, 'libserialport');
      expect(release.codeSigning, 'signed-sha256-timestamped');

      await manifest.writeAsString('{broken', flush: true);
      final fallback = await loadAppReleaseInfoFromFile(manifest);
      expect(fallback.manifestLoaded, isFalse);
      expect(fallback.displayVersion, '开发构建');
    });

    test('报告包含诊断计数但不包含数据、草稿、内容、主机和本地路径', () {
      final release = AppReleaseInfo(
        product: 'SSCOM',
        version: '1.2.3',
        buildNumber: '7',
        displayVersion: '1.2.3+7',
        channel: 'beta',
        serialBackend: 'libserialport',
        codeSigning: 'unsigned',
        hardwareValidation: 'pending',
        ispRealHardwareEnabled: false,
        ispNote: 'HIL pending',
        manifestLoaded: true,
      );
      final terminal = TerminalViewState(
        status: TransportStatus.error,
        ports: const <SerialPortInfo>[],
        config: const SerialConfig(
          portName: 'COM7',
          baudRate: 921600,
          dataBits: SerialDataBits.eight,
          stopBits: SerialStopBits.two,
          parity: SerialParity.even,
          flowControl: SerialFlowControl.rtsCts,
        ),
        signals: const SerialSignalState(),
        lines: <TerminalLine>[
          TerminalLine(
            text: 'SECRET SERIAL DATA',
            timestamp: DateTime.utc(2026, 11, 13),
            byteOffset: 0,
          ),
        ],
        backendLabel: 'libserialport 0.6.0（实验性）',
        isSimulatedBackend: false,
        transportMode: TransportMode.tcpClient,
        remoteHost: 'secret.example.com',
        remotePort: 6000,
        bindAddress: '127.0.0.1',
        localPort: 6001,
        displayMode: TerminalDisplayMode.hex,
        textDraft: 'TOP SECRET TEXT',
        hexDraft: 'DE AD BE EF',
        receivedBytes: 123,
        sentBytes: 45,
        droppedBytes: 6,
        droppedLines: 7,
        errorMessage:
            '连接 secret.example.com 失败，文件 C:\\Users\\alice\\secret.txt',
      );
      final multiSend = MultiSendState(
        entries: const <MultiSendEntry>[
          MultiSendEntry(
            index: 1,
            mode: SendInputMode.ansiText,
            payload: 'PRIVATE MULTI SEND PAYLOAD',
            enabled: true,
            name: 'PRIVATE NAME',
            intervalMs: 100,
          ),
        ],
        isRunning: true,
        completedSends: 9,
        completedCycles: 2,
      );

      final report = buildSupportReport(
        release: release,
        terminal: terminal,
        multiSend: multiSend,
        generatedAt: DateTime.utc(2026, 11, 13, 8, 30),
        operatingSystemVersion: 'Windows 11 test build',
      );

      expect(report, contains('版本：1.2.3+7'));
      expect(report, contains('串口端口：COM7'));
      expect(report, contains('接收字节：123'));
      expect(report, contains('已完成循环：2'));
      expect(report, contains('<remote-host>'));
      expect(report, contains('<local-path>'));
      expect(report, isNot(contains('SECRET SERIAL DATA')));
      expect(report, isNot(contains('TOP SECRET TEXT')));
      expect(report, isNot(contains('DE AD BE EF')));
      expect(report, isNot(contains('PRIVATE MULTI SEND PAYLOAD')));
      expect(report, isNot(contains('PRIVATE NAME')));
      expect(report, isNot(contains('secret.example.com')));
      expect(report, isNot(contains('C:\\Users\\alice')));
    });

    test('错误脱敏覆盖主机大小写、带空格路径和 UNC 路径', () {
      final terminal = TerminalViewState(
        status: TransportStatus.error,
        ports: const <SerialPortInfo>[],
        config: const SerialConfig(portName: 'COM3', baudRate: 115200),
        signals: const SerialSignalState(),
        lines: const <TerminalLine>[],
        backendLabel: 'libserialport',
        isSimulatedBackend: false,
        transportMode: TransportMode.tcpClient,
        remoteHost: 'secret.example.com',
        errorMessage:
            '连接 SECRET.EXAMPLE.COM 失败：'
            r'"C:\Users\Alice Smith\My Secret\capture.txt"，'
            r'"%APPDATA%\SSCOM\token.txt"，'
            r'回退日志 \\lab-server\share\Private Dir\trace.log 不可用',
      );

      final report = buildSupportReport(
        release: AppReleaseInfo.development(),
        terminal: terminal,
        multiSend: MultiSendState(entries: const <MultiSendEntry>[]),
        generatedAt: DateTime.utc(2026, 11, 13, 9),
        operatingSystemVersion: 'Windows 11 test build',
      );

      expect(report, contains('当前错误：连接 <remote-host> 失败：<local-path>'));
      expect(report, isNot(contains('SECRET.EXAMPLE.COM')));
      expect(report, isNot(contains('secret.example.com')));
      expect(report, isNot(contains('Alice Smith')));
      expect(report, isNot(contains('My Secret')));
      expect(report, isNot(contains('%APPDATA%')));
      expect(report, isNot(contains('token.txt')));
      expect(report, isNot(contains('lab-server')));
      expect(report, isNot(contains('Private Dir')));
      expect(report, isNot(contains('C:\\Users')));
      expect(report, isNot(contains(r'\\lab-server')));
    });
  });
}
