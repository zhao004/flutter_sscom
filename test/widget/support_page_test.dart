import 'package:flutter/material.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/support/domain/app_release_info.dart';
import 'package:flutter_sscom/features/support/presentation/support_page.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

void main() {
  testWidgets('诊断页面显示发布信息并复制脱敏报告', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 760);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final terminal = TerminalController(
      transport: FakeSerialTransport(),
      textEncoder: const Utf8TextByteEncoder(),
      backendLabel: '测试串口',
      initialTextDraft: 'SHOULD NOT APPEAR',
    );
    final multiSend = MultiSendController(
      terminal: terminal,
      initialEntries: const <MultiSendEntry>[
        MultiSendEntry(
          index: 1,
          mode: SendInputMode.ansiText,
          payload: 'PRIVATE PAYLOAD',
          enabled: true,
          name: 'PRIVATE NAME',
          intervalMs: 100,
        ),
      ],
    );
    String? copied;
    addTearDown(() async {
      await multiSend.dispose();
      await terminal.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SupportPage(
          terminal: terminal,
          multiSendController: multiSend,
          releaseInfoLoader: () async => const AppReleaseInfo(
            product: 'SSCOM',
            version: '1.2.3',
            buildNumber: '7',
            displayVersion: '1.2.3+7',
            channel: 'beta',
            serialBackend: 'libserialport',
            codeSigning: 'signed-sha256-timestamped',
            hardwareValidation: 'pending',
            ispRealHardwareEnabled: false,
            ispNote: 'HIL pending',
            manifestLoaded: true,
          ),
          clipboardWriter: (text) async => copied = text,
          operatingSystemVersionProvider: () => 'Windows test build',
          now: () => DateTime.utc(2026, 11, 13, 9),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('诊断与反馈'), findsOneWidget);
    expect(find.text('版本：1.2.3+7'), findsOneWidget);
    expect(find.textContaining('不会包含串口原始数据'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(find.text('导出诊断报告'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '复制诊断信息'));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('版本：1.2.3+7'));
    expect(copied, contains('操作系统：Windows test build'));
    expect(copied, isNot(contains('SHOULD NOT APPEAR')));
    expect(copied, isNot(contains('PRIVATE PAYLOAD')));
    expect(copied, isNot(contains('PRIVATE NAME')));
    expect(find.text('诊断信息已复制到剪贴板'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
