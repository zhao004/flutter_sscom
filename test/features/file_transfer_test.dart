import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/file_transfer/application/file_send_controller.dart';
import 'package:flutter_sscom/features/file_transfer/application/receive_log_controller.dart';
import 'package:flutter_sscom/features/file_transfer/infrastructure/receive_log_writer.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_serial_transport.dart';
import '../support/fake_transport.dart';

const _port = SerialPortInfo(
  systemPath: 'COM1',
  displayName: '测试串口 COM1',
  isAvailable: true,
);

void main() {
  group('文件传输', () {
    late Directory directory;

    setUp(() async {
      directory = Directory(
        '.cache/test-file-transfer/${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('文件分块发送并处理传输层短写', () async {
      final bytes = Uint8List.fromList(List<int>.generate(11, (i) => i + 1));
      final file = File('${directory.path}/payload.bin');
      await file.writeAsBytes(bytes, flush: true);
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[_port],
        maxSendChunk: 2,
      );
      final terminal = _terminal(transport);
      final fileSend = FileSendController(terminal: terminal, chunkSize: 3);
      addTearDown(() async {
        await fileSend.dispose();
        await terminal.dispose();
      });

      await terminal.initialize();
      await terminal.open();
      await fileSend.start(file);

      expect(fileSend.state.value.phase, FileSendPhase.completed);
      expect(fileSend.state.value.sentBytes, bytes.length);
      expect(fileSend.state.value.progress, 1);
      expect(
        transport.sentBatches.expand((batch) => batch),
        orderedEquals(bytes),
      );
    });

    test('取消受阻文件发送会关闭连接并回收文件句柄', () async {
      final file = await File('${directory.path}/blocked.bin')
          .writeAsBytes([1, 2, 3]);
      final factory = RecordingTransportFactory(blockSends: true);
      final terminal = TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试网络',
        networkTransportFactory: factory,
        initialTransportMode: TransportMode.tcpClient,
        initialRemoteHost: '127.0.0.1',
        initialRemotePort: 6001,
      );
      final fileSend = FileSendController(terminal: terminal);
      await terminal.initialize();
      await terminal.open();
      final operation = fileSend.start(file);
      await factory.transports.single.sendStarted.future;
      try {
        await fileSend.cancel().timeout(const Duration(seconds: 2));
        await operation;
        expect(fileSend.state.value.phase, FileSendPhase.cancelled);
        expect(fileSend.state.value.sentBytes, 0);
        expect(terminal.state.value.isSending, isFalse);
        expect(factory.transports.single.isDisposed, isTrue);
        await file.rename('${directory.path}/released.bin');
      } finally {
        await factory.transports.single.close();
        await operation;
        await fileSend.dispose();
        await terminal.dispose();
      }
    });

    test('取消尚未发送分块的文件任务不打断其他发送', () async {
      final file = await File('${directory.path}/queued.bin').writeAsBytes([1]);
      final factory = RecordingTransportFactory(blockSends: true);
      final terminal = TerminalController(
        transport: FakeSerialTransport(),
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试网络',
        networkTransportFactory: factory,
        initialTransportMode: TransportMode.tcpClient,
        initialRemoteHost: '127.0.0.1',
        initialRemotePort: 6001,
      );
      final fileSend = FileSendController(terminal: terminal);
      await terminal.initialize();
      await terminal.open();
      final otherSend = terminal.sendBytes(Uint8List.fromList([2]));
      await factory.transports.single.sendStarted.future;
      final operation = fileSend.start(file);
      try {
        await fileSend.cancel().timeout(const Duration(seconds: 2));
        await operation;
        expect(fileSend.state.value.phase, FileSendPhase.cancelled);
        expect(factory.transports.single.wasClosed, isFalse);
        expect(terminal.state.value.isSending, isTrue);
      } finally {
        await terminal.close();
        await otherSend;
        await operation;
        await fileSend.dispose();
        await terminal.dispose();
      }
    });

    test('ISP 独占串口时拒绝发送文件', () async {
      final file = File('${directory.path}/blocked.bin');
      await file.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3]), flush: true);
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[_port],
      );
      final terminal = _terminal(transport);
      final fileSend = FileSendController(terminal: terminal);
      final owner = Object();
      addTearDown(() async {
        terminal.releaseExclusiveSend(owner);
        await fileSend.dispose();
        await terminal.dispose();
      });

      await terminal.initialize();
      await terminal.open();
      expect(terminal.acquireExclusiveSend(owner), isTrue);
      await fileSend.start(file);

      expect(fileSend.state.value.phase, FileSendPhase.failed);
      expect(fileSend.state.value.errorMessage, contains('ISP'));
      expect(transport.sentBatches, isEmpty);
    });

    test('接收日志顺序落盘并可停止关闭', () async {
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[_port],
      );
      final terminal = _terminal(transport);
      final receiveLog = ReceiveLogController(terminal: terminal);
      final logFile = File('${directory.path}/receive.log');
      addTearDown(() async {
        await receiveLog.dispose();
        await terminal.dispose();
      });

      await terminal.initialize();
      await terminal.open();
      await receiveLog.start(logFile);
      final first = Uint8List.fromList(<int>[0x01, 0x02]);
      final second = Uint8List.fromList(<int>[0x03, 0x04, 0x05]);
      transport.injectData(first);
      transport.injectData(second);
      await receiveLog.stop();

      expect(receiveLog.state.value.isLogging, isFalse);
      expect(receiveLog.state.value.bytesWritten, 5);
      expect(
        await logFile.readAsBytes(),
        orderedEquals(<int>[...first, ...second]),
      );
    });

    test('文件发送可取消且不会继续发送后续分块', () async {
      final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final file = File('${directory.path}/cancel.bin');
      await file.writeAsBytes(bytes, flush: true);
      final transport = FakeSerialTransport(
        initialPorts: const <SerialPortInfo>[_port],
        maxSendChunk: 1,
        sendDelay: const Duration(milliseconds: 5),
      );
      final terminal = _terminal(transport);
      final fileSend = FileSendController(terminal: terminal, chunkSize: 1);
      addTearDown(() async {
        await fileSend.dispose();
        await terminal.dispose();
      });

      await terminal.initialize();
      await terminal.open();
      final operation = fileSend.start(file);
      await Future<void>.delayed(const Duration(milliseconds: 12));
      await fileSend.cancel();
      await operation;

      expect(fileSend.state.value.phase, FileSendPhase.cancelled);
      expect(fileSend.state.value.sentBytes, lessThan(bytes.length));
    });

    test('接收日志待写队列有上限并拒绝无限积压', () async {
      final writer = ReceiveLogWriter(
        file: File('${directory.path}/bounded.log'),
        maxPendingBytes: 2,
      );
      await writer.open();
      addTearDown(writer.close);

      final first = writer.append(Uint8List.fromList(<int>[1, 2]));
      expect(
        () => writer.append(Uint8List.fromList(<int>[3])),
        throwsA(isA<ReceiveLogOverflowException>()),
      );
      await first;
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
