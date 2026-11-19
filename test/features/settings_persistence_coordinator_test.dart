import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/application/settings_persistence_coordinator.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';
import '../support/in_memory_settings_repository.dart';

void main() {
  group('SettingsPersistenceCoordinator', () {
    test('偏好连续变化只触发一次防抖保存并保留完整设置', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[
            SerialPortInfo(
              systemPath: 'COM1',
              displayName: 'COM1',
              isAvailable: true,
            ),
          ],
        );
        final controller = TerminalController(
          transport: transport,
          textEncoder: const Utf8TextByteEncoder(),
          backendLabel: '测试',
          initialConfig: const SerialConfig(
            portName: 'COM1',
            baudRate: 9600,
            parity: SerialParity.even,
          ),
          initialTransportMode: TransportMode.tcpClient,
          initialNetworkSafetyMode: NetworkSafetyMode.rawDebug,
          initialRemoteHost: '127.0.0.1',
          initialRemotePort: 6000,
          initialBindAddress: '0.0.0.0',
          initialLocalPort: 6001,
          initialFollowRemoteEndpoint: false,
        );
        unawaited(controller.initialize());
        async.flushMicrotasks();
        final initialSettings = AppSettings.defaults();
        final repository = InMemorySettingsRepository(
          settings: initialSettings,
        );
        final coordinator = SettingsPersistenceCoordinator(
          repository: repository,
          controller: controller,
          initialSettings: initialSettings,
          debounce: const Duration(milliseconds: 100),
        );

        controller.setDisplayMode(TerminalDisplayMode.hex);
        controller.setShowTimestamp(true);
        controller.setSendMode(SendInputMode.hex);
        controller.setSendChecksumMode(LegacyChecksumMode.xor8);
        controller.updateSendDraft('01 02');
        async.flushMicrotasks();

        async.elapse(const Duration(milliseconds: 99));
        expect(repository.saveCount, 0);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();

        expect(repository.saveCount, 1);
        expect(repository.settings?.serial.baudRate, 9600);
        expect(
          repository.settings?.terminal.displayMode,
          TerminalDisplayMode.hex,
        );
        expect(repository.settings?.terminal.showTimestamp, isTrue);
        expect(repository.settings?.send.mode, SendInputMode.hex);
        expect(repository.settings?.send.checksumMode, LegacyChecksumMode.xor8);
        expect(repository.settings?.send.hexDraft, '01 02');
        expect(repository.settings?.network.mode, TransportMode.tcpClient);
        expect(
          repository.settings?.network.safetyMode,
          NetworkSafetyMode.rawDebug,
        );
        expect(repository.settings?.network.bindAddress, '0.0.0.0');
        expect(repository.settings?.network.remotePort, 6000);
        expect(repository.settings?.network.localPort, 6001);
        expect(repository.settings?.network.followRemoteEndpoint, isFalse);

        unawaited(coordinator.dispose());
        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('dispose 在防抖窗口结束前刷新待保存设置', () {
      fakeAsync((async) {
        final controller = TerminalController(
          transport: FakeSerialTransport(),
          textEncoder: const Utf8TextByteEncoder(),
          backendLabel: '测试',
        );
        unawaited(controller.initialize());
        async.flushMicrotasks();
        final repository = InMemorySettingsRepository();
        final coordinator = SettingsPersistenceCoordinator(
          repository: repository,
          controller: controller,
          initialSettings: AppSettings.defaults(),
          debounce: const Duration(seconds: 1),
        );

        controller.updateSendDraft('立即保存');
        async.flushMicrotasks();
        unawaited(coordinator.dispose());
        async.flushMicrotasks();

        expect(repository.saveCount, 1);
        expect(repository.settings?.send.textDraft, '立即保存');

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('多字符串条目变化触发防抖保存', () {
      fakeAsync((async) {
        final controller = TerminalController(
          transport: FakeSerialTransport(),
          textEncoder: const Utf8TextByteEncoder(),
          backendLabel: '测试',
        );
        final multiSend = MultiSendController(
          terminal: controller,
          initialEntries: const <MultiSendEntry>[],
        );
        final initialSettings = AppSettings.defaults();
        final repository = InMemorySettingsRepository(
          settings: initialSettings,
        );
        final coordinator = SettingsPersistenceCoordinator(
          repository: repository,
          controller: controller,
          multiSendController: multiSend,
          initialSettings: initialSettings,
          debounce: const Duration(milliseconds: 100),
        );

        expect(
          multiSend.replaceEntries(const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.hex,
              payload: '01 02',
              enabled: true,
              name: '命令',
              intervalMs: 250,
            ),
          ]),
          isTrue,
        );
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();

        expect(repository.saveCount, 1);
        expect(repository.settings?.multiSend.single.name, '命令');
        expect(repository.settings?.multiSend.single.intervalMs, 250);

        unawaited(coordinator.dispose());
        unawaited(multiSend.dispose());
        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
