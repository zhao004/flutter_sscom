import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/buffers/buffers.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';

const _port = SerialPortInfo(
  systemPath: 'COM1',
  displayName: '测试串口 COM1',
  isAvailable: true,
);

void main() {
  group('TerminalController', () {
    test('初始化端口、打开关闭、发送文本并追加 CRLF 与校验', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final controller = _controller(transport);
        unawaited(controller.initialize());
        async.flushMicrotasks();

        expect(controller.state.value.ports, hasLength(1));
        expect(controller.state.value.config.portName, 'COM1');

        unawaited(controller.open());
        async.flushMicrotasks();
        expect(controller.state.value.status, TransportStatus.connected);
        expect(controller.state.value.signals.dtr, isFalse);

        controller
          ..setSendChecksumMode(LegacyChecksumMode.add8)
          ..setSendAppendCrLf(true);
        SendResult? result;
        unawaited(
          controller
              .send(const SendRequest(input: r'A\r'))
              .then((value) => result = value),
        );
        async.flushMicrotasks();

        expect(result, isNotNull);
        expect(
          transport.sentBatches.single,
          orderedEquals(<int>[0x41, 0x0D, 0x0D, 0x0A, 0x65]),
        );
        expect(controller.state.value.sentBytes, 5);

        unawaited(controller.close());
        async.flushMicrotasks();
        expect(controller.state.value.status, TransportStatus.disconnected);

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('跨包 UTF-8 经定时批处理后显示，HEX 视图可切换', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final controller = _controller(transport);
        unawaited(controller.initialize());
        unawaited(controller.open());
        async.flushMicrotasks();

        final bytes = Uint8List.fromList(utf8.encode('你'));
        transport.injectData(Uint8List.fromList(<int>[bytes[0]]));
        async.elapse(const Duration(milliseconds: 33));
        expect(controller.state.value.lines, isEmpty);

        transport.injectData(Uint8List.fromList(bytes.sublist(1)));
        async.elapse(const Duration(milliseconds: 33));
        expect(controller.state.value.lines.single.text, '你');
        expect(controller.state.value.receivedBytes, 3);

        controller.setDisplayMode(TerminalDisplayMode.hex);
        expect(controller.state.value.lines.single.text, contains('E4 BD A0'));

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('原始缓冲和显示行有界，清屏保留会话计数', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final controller = _controller(
          transport,
          policy: BufferPolicy(
            maxRawBytes: 2,
            maxDisplayLines: 2,
            flushInterval: const Duration(milliseconds: 10),
            maxPendingBytes: 32,
            hexBytesPerLine: 4,
          ),
        );
        unawaited(controller.initialize());
        unawaited(controller.open());
        async.flushMicrotasks();

        transport.injectData(Uint8List.fromList(utf8.encode('a\nb\nc\n')));
        async.elapse(const Duration(milliseconds: 10));

        expect(controller.state.value.lines.map((line) => line.text), <String>[
          'b',
          'c',
        ]);
        expect(controller.state.value.droppedBytes, greaterThan(0));
        expect(controller.state.value.droppedLines, greaterThan(0));

        final receivedBeforeClear = controller.state.value.receivedBytes;
        controller.clearTerminal();
        expect(controller.state.value.lines, isEmpty);
        expect(controller.state.value.droppedBytes, 0);
        expect(controller.state.value.receivedBytes, receivedBeforeClear);

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('连接时拒绝配置变更，非法 HEX 和未连接发送给出错误', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final controller = _controller(transport);
        unawaited(controller.initialize());
        async.flushMicrotasks();

        controller.setSendMode(SendInputMode.hex);
        SendResult? disconnectedResult;
        unawaited(
          controller
              .send(const SendRequest(input: '41'))
              .then((value) => disconnectedResult = value),
        );
        async.flushMicrotasks();
        expect(disconnectedResult, isNull);
        expect(controller.state.value.errorMessage, contains('未连接'));

        unawaited(controller.open());
        async.flushMicrotasks();
        unawaited(
          controller.updateConfig(
            const SerialConfig(portName: 'COM1', baudRate: 9600),
          ),
        );
        async.flushMicrotasks();
        expect(controller.state.value.config.baudRate, 115200);
        expect(controller.state.value.errorMessage, contains('连接期间'));

        SendResult? invalidHexResult;
        unawaited(
          controller
              .send(const SendRequest(input: 'GG'))
              .then((value) => invalidHexResult = value),
        );
        async.flushMicrotasks();
        expect(invalidHexResult, isNull);
        expect(controller.state.value.errorMessage, contains('只允许'));

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('ISP 独占期间拒绝关闭、切换模式和修改配置', () {
      fakeAsync((async) {
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
        );
        final controller = _controller(transport);
        final owner = Object();
        unawaited(controller.initialize());
        unawaited(controller.open());
        async.flushMicrotasks();
        expect(controller.acquireExclusiveSend(owner), isTrue);

        unawaited(controller.close());
        async.flushMicrotasks();
        expect(controller.state.value.status, TransportStatus.connected);
        expect(controller.state.value.errorMessage, contains('结束 ISP'));

        unawaited(controller.switchTransportMode(TransportMode.tcpClient));
        async.flushMicrotasks();
        expect(controller.state.value.transportMode, TransportMode.serial);
        expect(controller.state.value.errorMessage, contains('不能切换'));

        unawaited(
          controller.updateConfig(
            const SerialConfig(portName: 'COM1', baudRate: 9600),
          ),
        );
        async.flushMicrotasks();
        expect(controller.state.value.config.baudRate, 115200);
        expect(controller.state.value.errorMessage, contains('不能修改'));

        controller.releaseExclusiveSend(owner);
        unawaited(controller.close());
        async.flushMicrotasks();
        expect(controller.state.value.status, TransportStatus.disconnected);

        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });

    test('传输错误映射到状态，dispose 可重复调用', () {
      fakeAsync((async) {
        const failure = TransportError(
          code: TransportErrorCode.writeFailed,
          message: '模拟写入失败',
        );
        final transport = FakeSerialTransport(
          initialPorts: const <SerialPortInfo>[_port],
          sendError: failure,
        );
        final controller = _controller(transport);
        unawaited(controller.initialize());
        unawaited(controller.open());
        async.flushMicrotasks();

        SendResult? result;
        unawaited(
          controller
              .send(const SendRequest(input: 'A'))
              .then((value) => result = value),
        );
        async.flushMicrotasks();

        expect(result, isNull);
        expect(controller.state.value.errorMessage, '模拟写入失败');
        expect(controller.state.value.isSending, isFalse);

        unawaited(controller.dispose());
        unawaited(controller.dispose());
        async.flushMicrotasks();
      });
    });
  });
}

TerminalController _controller(
  FakeSerialTransport transport, {
  BufferPolicy? policy,
}) {
  return TerminalController(
    transport: transport,
    textEncoder: const Utf8TextByteEncoder(),
    backendLabel: '测试后端',
    bufferPolicy: policy,
    now: () => DateTime(2026, 11, 12, 12, 0, 0),
    initialConfig: const SerialConfig(portName: 'COM1', baudRate: 115200),
  );
}
