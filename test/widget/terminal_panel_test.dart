import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/app/bootstrap.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/app/theme/sscom_theme.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import '../support/fake_serial_transport.dart';

void main() {
  for (final outcome in ['saved', 'cancelled', 'failed']) {
    testWidgets('接收快照导出处理 $outcome', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      final container = GetIt.asNewInstance();
      final transport = FakeSerialTransport(
        initialPorts: const [
          SerialPortInfo(
            systemPath: 'COM1',
            displayName: 'COM1',
            isAvailable: true,
          ),
        ],
      );
      final dependencies = await bootstrap(
        serviceLocator: container,
        serialTransport: transport,
      );
      final controller = container<TerminalController>();
      final directory = Directory(
        '.cache/terminal-export-${DateTime.now().microsecondsSinceEpoch}',
      );
      final file = File('${directory.path}/receive.txt');
      await tester.runAsync(() => directory.create(recursive: true));
      var pickerInvoked = false;
      addTearDown(() async {
        await tester.runAsync(dependencies.shutdown);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(container.reset);
        await tester.runAsync(() => directory.delete(recursive: true));
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      await tester.runAsync(controller.open);
      await tester.pumpWidget(
        MaterialApp(
          theme: SscomTheme.light(),
          home: Scaffold(
            body: TerminalPanel(
              controller: controller,
              pickExportFile: () async {
                pickerInvoked = true;
                if (outcome == 'failed') {
                  throw const FileSystemException('测试路径不可用');
                }
                return outcome == 'cancelled' ? null : file;
              },
            ),
          ),
        ),
      );
      transport.injectData(Uint8List.fromList(utf8.encode('hello\n')));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, '导出'));
      });
      await tester.pumpAndSettle();
      expect(pickerInvoked, isTrue);
      if (outcome == 'saved') {
        expect(await tester.runAsync(file.readAsString), 'hello');
        await tester.pumpAndSettle();
        expect(find.text('接收内容已导出'), findsOneWidget);
      } else {
        expect(await tester.runAsync(file.exists), isFalse);
        if (outcome == 'failed') {
          expect(find.textContaining('导出接收内容失败'), findsOneWidget);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('接收选项复制当前文本并切换字节数量显示', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const [
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
    );
    final controller = container<TerminalController>();
    addTearDown(() async {
      await tester.runAsync(dependencies.shutdown);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(container.reset);
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.runAsync(controller.open);
    await tester.pumpWidget(
      MaterialApp(
        theme: SscomTheme.light(),
        home: Scaffold(body: TerminalPanel(controller: controller)),
      ),
    );
    transport.injectData(Uint8List.fromList(utf8.encode('hello\n')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpAndSettle();
    expect(find.text('6 B 已接收'), findsOneWidget);
    await tester.tap(find.text('显示接收数量'));
    await tester.pump();
    expect(find.text('6 B 已接收'), findsNothing);
    await tester.tap(find.byTooltip('接收选项'));
    await tester.pumpAndSettle();
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.text('复制接收内容'));
    await tester.pumpAndSettle();
    expect(clipboardText, 'hello');
    expect(find.text('接收内容已复制'), findsOneWidget);
    await tester.tap(find.text('时间戳'));
    await tester.pumpAndSettle();
    expect(controller.state.value.showTimestamp, isTrue);
    final timestampCheckbox = find.descendant(
      of: find.widgetWithText(WorkspaceCheck, '时间戳'),
      matching: find.byType(Checkbox),
    );
    expect(tester.widget<Checkbox>(timestampCheckbox).value, isTrue);
    expect(find.textContaining(']  hello'), findsOneWidget);
    await tester.tap(find.text('时间戳'));
    await tester.pumpAndSettle();
    expect(controller.state.value.showTimestamp, isFalse);
    expect(tester.takeException(), isNull);
  });
}
