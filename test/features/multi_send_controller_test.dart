import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

const _port = SerialPortInfo(
  systemPath: 'COM1',
  displayName: '测试串口 COM1',
  isAvailable: true,
);

void main() {
  group('MultiSendController', () {
    test('按条目顺序、模式和间隔循环发送并支持停止', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final terminal = _terminal(transport);
        final multiSend = MultiSendController(
          terminal: terminal,
          initialEntries: const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: 'A',
              enabled: true,
              name: '文本 A',
              intervalMs: 100,
            ),
            MultiSendEntry(
              index: 2,
              mode: SendInputMode.hex,
              payload: '42',
              enabled: true,
              name: 'HEX B',
              intervalMs: 50,
            ),
            MultiSendEntry(
              index: 3,
              mode: SendInputMode.ansiText,
              payload: 'skip',
              enabled: false,
              name: '禁用',
              intervalMs: 1,
            ),
          ],
        );
        unawaited(terminal.initialize());
        unawaited(terminal.open());
        async.flushMicrotasks();

        multiSend.start();
        async.flushMicrotasks();
        expect(transport.sentBatches, hasLength(1));
        expect(transport.sentBatches.single, orderedEquals(<int>[0x41]));
        expect(multiSend.state.value.currentEntryIndex, 1);

        async.elapse(const Duration(milliseconds: 99));
        async.flushMicrotasks();
        expect(transport.sentBatches, hasLength(1));

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(transport.sentBatches, hasLength(2));
        expect(transport.sentBatches.last, orderedEquals(<int>[0x42]));

        async.elapse(const Duration(milliseconds: 50));
        async.flushMicrotasks();
        expect(transport.sentBatches, hasLength(3));
        expect(transport.sentBatches.last, orderedEquals(<int>[0x41]));
        expect(multiSend.state.value.completedCycles, 1);
        expect(multiSend.state.value.completedSends, 3);

        unawaited(multiSend.stop());
        async.flushMicrotasks();
        expect(multiSend.state.value.isRunning, isFalse);
        expect(transport.sentBatches, hasLength(3));

        unawaited(multiSend.dispose());
        unawaited(terminal.dispose());
        async.flushMicrotasks();
      });
    });

    test('串口未连接或没有有效条目时拒绝启动', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final terminal = _terminal(transport);
        final multiSend = MultiSendController(
          terminal: terminal,
          initialEntries: const <MultiSendEntry>[],
        );

        multiSend.start();
        expect(multiSend.state.value.isRunning, isFalse);
        expect(multiSend.state.value.errorMessage, contains('连接未建立'));

        unawaited(terminal.initialize());
        unawaited(terminal.open());
        async.flushMicrotasks();
        multiSend.start();
        expect(multiSend.state.value.isRunning, isFalse);
        expect(multiSend.state.value.errorMessage, contains('没有启用'));

        expect(
          multiSend.replaceEntries(const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: 'A',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
          ]),
          isTrue,
        );
        expect(multiSend.state.value.entries, hasLength(1));

        unawaited(multiSend.dispose());
        unawaited(terminal.dispose());
        async.flushMicrotasks();
      });
    });

    test('ISP 独占串口时拒绝启动多字符串发送', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final terminal = _terminal(transport);
        final owner = Object();
        final multiSend = MultiSendController(
          terminal: terminal,
          initialEntries: const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: 'A',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
          ],
        );
        unawaited(terminal.initialize());
        unawaited(terminal.open());
        async.flushMicrotasks();
        expect(terminal.acquireExclusiveSend(owner), isTrue);

        multiSend.start();
        expect(multiSend.state.value.isRunning, isFalse);
        expect(multiSend.state.value.errorMessage, contains('ISP'));
        expect(transport.sentBatches, isEmpty);

        terminal.releaseExclusiveSend(owner);
        unawaited(multiSend.dispose());
        unawaited(terminal.dispose());
        async.flushMicrotasks();
      });
    });

    test('串口断开时自动停止循环', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final terminal = _terminal(transport);
        final multiSend = MultiSendController(
          terminal: terminal,
          initialEntries: const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.hex,
              payload: '01',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
          ],
        );
        unawaited(terminal.initialize());
        unawaited(terminal.open());
        async.flushMicrotasks();
        multiSend.start();
        async.flushMicrotasks();
        expect(transport.sentBatches, hasLength(1));

        transport.simulateDisconnect(reason: '模拟拔出');
        async.flushMicrotasks();
        expect(multiSend.state.value.isRunning, isFalse);
        expect(multiSend.state.value.errorMessage, contains('连接已断开'));

        unawaited(multiSend.dispose());
        unawaited(terminal.dispose());
        async.flushMicrotasks();
      });
    });

    test('条目编辑支持单条启停和顺序调整', () {
      fakeAsync((async) {
        final controller = TerminalController(
          transport: FakeSerialTransport(),
          textEncoder: const Utf8TextByteEncoder(),
          backendLabel: '测试',
        );
        final multiSend = MultiSendController(
          terminal: controller,
          initialEntries: const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: 'A',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
            MultiSendEntry(
              index: 2,
              mode: SendInputMode.hex,
              payload: '42',
              enabled: true,
              name: '',
              intervalMs: 500,
            ),
          ],
        );

        expect(multiSend.setEntryEnabled(1, false), isTrue);
        expect(multiSend.moveEntry(2, -1), isTrue);
        expect(multiSend.state.value.entries.first.index, 2);
        expect(multiSend.state.value.entries.last.enabled, isFalse);

        unawaited(multiSend.dispose());
        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('异常初始条目会被安全过滤或归一化', () {
      fakeAsync((async) {
        final controller = TerminalController(
          transport: FakeSerialTransport(),
          textEncoder: const Utf8TextByteEncoder(),
          backendLabel: '测试',
        );
        final multiSend = MultiSendController(
          terminal: controller,
          initialEntries: const <MultiSendEntry>[
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: 'A',
              enabled: true,
              name: '',
              intervalMs: 0,
            ),
            MultiSendEntry(
              index: 1,
              mode: SendInputMode.ansiText,
              payload: '重复',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
            MultiSendEntry(
              index: 0,
              mode: SendInputMode.ansiText,
              payload: '越界',
              enabled: true,
              name: '',
              intervalMs: 1000,
            ),
          ],
        );

        expect(multiSend.state.value.entries, hasLength(1));
        expect(multiSend.state.value.entries.single.payload, 'A');
        expect(
          multiSend.state.value.entries.single.intervalMs,
          minMultiSendIntervalMs,
        );

        unawaited(multiSend.dispose());
        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });
  });
}

TerminalController _terminal(FakeSerialTransport transport) {
  return TerminalController(
    transport: transport,
    textEncoder: const Utf8TextByteEncoder(),
    backendLabel: '测试后端',
    initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
  );
}
