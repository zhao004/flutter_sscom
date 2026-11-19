import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/app/app.dart';
import 'package:flutter_sscom/app/bootstrap.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/isp/application/isp_controller.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/support/domain/app_release_info.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import '../support/fake_serial_transport.dart';
import '../support/fake_transport.dart';
import '../support/in_memory_settings_repository.dart';

const String _stm32SampleHex = '''
:020000040800F2
:080000000100002005000008CA
:0400000508000001EE
:00000001FF
''';

void main() {
  testWidgets('显式测试后端渲染完整串口工作区', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();

    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.text('SSCOM'), findsOneWidget);
    expect(find.text('测试串口后端'), findsOneWidget);
    expect(find.text('测试串口 COM9'), findsOneWidget);
    expect(find.text('等待接收数据'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '连接'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '发送'), findsOneWidget);
    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('接收落盘'), findsOneWidget);
    expect(find.text('多字符串'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('使用 Fake Transport 完成打开、发送和接收显示', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: '测试串口 COM1',
          isAvailable: true,
        ),
      ],
    );

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.text('测试串口后端'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '关闭'), findsOneWidget);

    await tester.enterText(find.byType(TextField), r'A\r');
    await tester.pump();
    final sendButtonFinder = find.widgetWithText(FilledButton, '发送');
    expect(tester.widget<FilledButton>(sendButtonFinder).onPressed, isNotNull);
    await tester.tap(sendButtonFinder);
    await tester.pumpAndSettle();
    expect(transport.sentBatches, hasLength(1));
    expect(transport.sentBatches.single, orderedEquals(<int>[0x41, 0x0D]));

    await tester.enterText(find.byType(TextField), 'B');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(transport.sentBatches, hasLength(2));
    expect(transport.sentBatches.last, orderedEquals(<int>[0x42]));

    transport.injectData(Uint8List.fromList(utf8.encode('hello\n')));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('hello'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动设置恢复串口、显示模式和发送草稿', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final settings = AppSettings(
      serial: const SerialConfig(portName: 'COM1', baudRate: 1200),
      terminal: const TerminalPreferences(
        displayMode: TerminalDisplayMode.hex,
        showTimestamp: true,
      ),
      send: const SendPreferences(mode: SendInputMode.hex, hexDraft: 'AA 55'),
    );
    final repository = InMemorySettingsRepository(settings: settings);

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
      settingsRepository: repository,
      settings: settings,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    final controller = container<TerminalController>();
    expect(controller.state.value.config.baudRate, 1200);
    expect(controller.state.value.displayMode, TerminalDisplayMode.hex);
    expect(controller.state.value.showTimestamp, isTrue);
    expect(controller.state.value.sendMode, SendInputMode.hex);
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller?.text, 'AA 55');
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有可用端口时禁用打开按钮', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport();

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    final openButton = find.widgetWithText(FilledButton, '连接');
    expect(openButton, findsOneWidget);
    expect(tester.widget<FilledButton>(openButton).onPressed, isNull);
  });

  testWidgets('多字符串编辑器加载设置条目并可取消', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final settings = AppSettings(
      serial: const SerialConfig(portName: 'COM1', baudRate: 115200),
      multiSend: const <MultiSendEntry>[
        MultiSendEntry(
          index: 1,
          mode: SendInputMode.hex,
          payload: 'AA 55',
          enabled: true,
          name: '命令 A',
          intervalMs: 500,
        ),
      ],
    );

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
      settings: settings,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('多字符串'));
    await tester.tap(find.text('多字符串'));
    await tester.pumpAndSettle();

    expect(find.text('多字符串发送'), findsOneWidget);
    expect(find.text('命令 A'), findsOneWidget);
    expect(find.text('AA 55'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('多字符串发送'), findsNothing);
  });

  testWidgets('保存并启动多字符串后发送条目并可停止', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final settings = AppSettings(
      serial: const SerialConfig(portName: 'COM1', baudRate: 115200),
      multiSend: const <MultiSendEntry>[
        MultiSendEntry(
          index: 1,
          mode: SendInputMode.ansiText,
          payload: 'A',
          enabled: true,
          name: '命令 A',
          intervalMs: 1000,
        ),
      ],
    );

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
      settings: settings,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('多字符串'));
    await tester.tap(find.text('多字符串'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并启动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(transport.sentBatches, isNotEmpty);
    expect(transport.sentBatches.first, orderedEquals(<int>[0x41]));
    expect(find.text('停止多发送'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '发送文件'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('停止多发送'));
    await tester.pumpAndSettle();
    expect(find.text('多字符串'), findsOneWidget);
  });

  testWidgets('波形页面显示独立降采样统计且不影响返回主工作区', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
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
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();

    transport.injectData(Uint8List.fromList(<int>[1, 2, 3, 4]));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byTooltip('波形'));
    await tester.pumpAndSettle();

    expect(find.text('波形'), findsOneWidget);
    expect(find.text('累计 4 个样本'), findsOneWidget);
    expect(find.text('绘制 4 个区间'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('SSCOM'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ISP 模拟器完成固件加载、设备识别、确认烧录和校验', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    var pickerInvoked = false;
    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
      pickIspFirmware: () async {
        pickerInvoked = true;
        return File('test/fixtures/firmware/stm32_sample.hex');
      },
      ispFirmwareReader: (_) async =>
          Uint8List.fromList(utf8.encode(_stm32SampleHex)),
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('ISP'));
    await tester.pumpAndSettle();
    expect(find.text('ISP 编程'), findsOneWidget);

    await tester.tap(find.text('当前串口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STM32 模拟器').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('模拟器不访问串口'), findsOneWidget);

    final ispController = container<IspController>();
    final loadButton = find.widgetWithText(OutlinedButton, '选择 Intel HEX');
    await tester.ensureVisible(loadButton);
    await tester.tap(loadButton);
    await tester.pumpAndSettle();
    expect(pickerInvoked, isTrue);
    expect(ispController.state.value.firmwareError, isNull);
    expect(ispController.state.value.image?.totalBytes, 8);
    expect(find.text('8 字节'), findsOneWidget);

    final detectButton = find.widgetWithText(OutlinedButton, '识别设备');
    await tester.ensureVisible(detectButton);
    await tester.tap(detectButton);
    await tester.pumpAndSettle();
    expect(find.text('产品 ID 0x0410'), findsOneWidget);

    final programButton = find.widgetWithText(FilledButton, '擦除并烧录');
    await tester.ensureVisible(programButton);
    await tester.tap(programButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('确认擦除并烧录'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(FilledButton, '确认擦除并烧录'));
    await tester.pumpAndSettle();

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('烧录与校验完成，设备仍停留在 bootloader'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('配置迁移向导读取旧 INI 并显示可审阅预览', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final settings = AppSettings(
      serial: const SerialConfig(portName: 'COM9', baudRate: 115200),
    );
    final repository = InMemorySettingsRepository(settings: settings);
    var pickerInvoked = false;
    const legacyText = 'N1080=,COM99\nN1081=,115200\nN1053,A,hello\nN1055,A\n';
    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
      settingsRepository: repository,
      settingsBackupDirectory: Directory(
        '.cache/test-settings-migration-widget/'
        '${DateTime.now().microsecondsSinceEpoch}',
      ),
      settings: settings,
      pickLegacyIni: () async {
        pickerInvoked = true;
        return File('test/fixtures/legacy/sscom51_compat/minimal_missing.ini');
      },
      legacyIniReader: (_) async => Uint8List.fromList(utf8.encode(legacyText)),
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('配置迁移'));
    await tester.pumpAndSettle();
    expect(find.text('配置迁移向导'), findsOneWidget);

    final selectButton = find.widgetWithText(OutlinedButton, '选择 sscom51.ini');
    await tester.tap(selectButton);
    await tester.pumpAndSettle();

    expect(pickerInvoked, isTrue);
    expect(find.text('迁移预览'), findsOneWidget);
    expect(find.textContaining('COM99'), findsOneWidget);
    expect(find.textContaining('当前会话已断开'), findsOneWidget);
    final applyButton = find.text('备份并保存迁移设置');
    await tester.ensureVisible(applyButton);
    await tester.tap(applyButton);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('确认导入旧配置'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(repository.saveCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非回环监听显示警告并在取消后保持未连接', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final transport = FakeSerialTransport(
      initialPorts: const <SerialPortInfo>[
        SerialPortInfo(
          systemPath: 'COM1',
          displayName: 'COM1',
          isAvailable: true,
        ),
      ],
    );
    final networkFactory = RecordingTransportFactory();
    final settings = AppSettings(
      serial: const SerialConfig(portName: 'COM1', baudRate: 115200),
      network: const NetworkPreferences(
        mode: TransportMode.tcpServer,
        safetyMode: NetworkSafetyMode.rawDebug,
        bindAddress: '0.0.0.0',
        localPort: 6001,
      ),
    );

    final dependencies = await bootstrap(
      serviceLocator: container,
      serialTransport: transport,
      networkTransportFactory: networkFactory,
      settings: settings,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.textContaining('非本机回环地址'), findsOneWidget);
    expect(find.text('Raw/Debug'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '监听'));
    await tester.pumpAndSettle();

    expect(find.text('确认对外监听'), findsOneWidget);
    expect(find.textContaining('不提供 TLS 或身份认证'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('确认对外监听'), findsNothing);
    expect(find.text('未连接'), findsOneWidget);
    expect(networkFactory.configs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('诊断入口打开发布支持页面', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
      supportReleaseInfoLoader: () async => const AppReleaseInfo(
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
      ),
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('诊断与反馈'));
    await tester.pumpAndSettle();

    expect(find.text('诊断与反馈'), findsOneWidget);
    expect(find.text('发布信息'), findsOneWidget);
    expect(find.textContaining('不会包含串口原始数据'), findsOneWidget);
    expect(find.text('复制诊断信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面窗口缩放保留工作区与紧凑串口信号入口', (tester) async {
    final container = GetIt.asNewInstance();
    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
    );
    _addCleanup(tester, container, dependencies);
    await _setViewSize(tester, const Size(1624, 930));
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();
    for (final size in [const Size(1280, 720), const Size(900, 600)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.text('通信调试'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '发送'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    final controller = container<TerminalController>();
    final previousDtr = controller.state.value.config.initialDtr;
    await tester.tap(find.byTooltip('串口信号'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, 'DTR'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(controller.state.value.config.initialDtr, !previousDtr);
    await tester.runAsync(() async {
      await tester.tap(find.text('网络通信'));
    });
    await tester.pumpAndSettle();
    expect(controller.state.value.transportMode, TransportMode.tcpClient);
    expect(find.text('远端主机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('900x600 连接详情、提示、错误和 UDP 警告不挤压终端', (tester) async {
    await _setViewSize(tester, const Size(900, 600));
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
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    final controller = container<TerminalController>();
    controller.showNotice('接收内容已导出');
    transport.injectError(
      TransportError(code: TransportErrorCode.disconnected, message: '测试连接异常'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '发送'));
    expect(
      find.widgetWithText(FilledButton, '发送').hitTestable(),
      findsOneWidget,
    );
    await tester.runAsync(
      () => controller.switchTransportMode(TransportMode.udp),
    );
    controller.dismissNotice();
    controller.updateNetworkSettings(
      bindAddress: '0.0.0.0',
      safetyMode: NetworkSafetyMode.rawDebug,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('非本机回环地址'));
    expect(find.textContaining('非本机回环地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空网络端口立即刷新校验与连接按钮', (tester) async {
    await _setViewSize(tester, const Size(1280, 800));
    final container = GetIt.asNewInstance();
    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
      settings: AppSettings(
        network: const NetworkPreferences(
          mode: TransportMode.tcpClient,
          remoteHost: '127.0.0.1',
          remotePort: 5001,
        ),
      ),
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();
    final connect = find.widgetWithText(FilledButton, '连接');
    expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
    final portField = find.byKey(const ValueKey<String>('network-field-远端端口'));
    final originalRect = tester.getRect(portField);
    await tester.enterText(portField, '');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);
    expect(find.byTooltip('1–65535'), findsOneWidget);
    expect(tester.getRect(portField), originalRect);
    final hintRect = tester.getRect(find.text('远端端口'));
    expect(hintRect.right, lessThanOrEqualTo(originalRect.right));
    expect(hintRect.center.dx, greaterThan(originalRect.center.dx));
    expect(hintRect.bottom, lessThanOrEqualTo(originalRect.top + 12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('900x600 紧凑桌面尺寸不产生布局溢出', (tester) async {
    await _setViewSize(tester, const Size(900, 600));
    final container = GetIt.asNewInstance();

    final dependencies = await bootstrap(
      serialTransport: _workspaceTransport(),
      serviceLocator: container,
    );
    _addCleanup(tester, container, dependencies);
    await tester.pumpWidget(App(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.text('测试串口后端'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('多字符串'));
    await tester.tap(find.text('多字符串'));
    await tester.pumpAndSettle();
    expect(find.text('多字符串发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setViewSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

void _addCleanup(
  WidgetTester tester,
  GetIt container,
  AppDependencies dependencies,
) {
  addTearDown(() async {
    await tester.runAsync(dependencies.shutdown);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await container.reset();
    });
  });
}

/// 独立测试会话保证工作区测试不会枚举本机设备。
FakeSerialTransport _workspaceTransport() => FakeSerialTransport(
  initialPorts: const [
    SerialPortInfo(
      systemPath: 'COM9',
      displayName: '测试串口 COM9',
      isAvailable: true,
    ),
  ],
);
