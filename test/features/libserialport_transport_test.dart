import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/libserialport_driver.dart';
import 'package:flutter_sscom/features/connection/infrastructure/libserialport_serial_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';

void main() {
  group('LibSerialPortSerialTransport', () {
    test('关闭等待信号操作且不会读取已释放的信号快照', () async {
      final gate = Completer<void>();
      final session = _FakeSession(signalGate: gate);
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: _FakeDriver(session: session),
      );
      addTearDown(transport.dispose);
      await transport.open();
      final setting = transport.setDtr(true);
      final failure = expectLater(setting, throwsA(isA<TransportException>()));
      await Future<void>.delayed(Duration.zero);
      final closing = transport.close();
      await Future<void>.delayed(Duration.zero);
      expect(session.events, isNot(contains('close')));
      gate.complete();
      await failure;
      await closing;
      expect(session.signalReadsAfterClose, 0);
      expect(transport.status, TransportStatus.disconnected);
    });

    test('销毁等待延迟打开并释放迟到会话且可并发重复销毁', () async {
      final gate = Completer<_FakeSession>();
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: _FakeDriver(openGate: gate),
      );
      final opening = transport.open();
      final failure = expectLater(opening, throwsA(isA<TransportException>()));
      final disposing = transport.dispose();
      final session = _FakeSession();
      gate.complete(session);
      await Future.wait([failure, disposing, transport.dispose()]);
      expect(session.events.where((event) => event == 'close'), hasLength(1));
      expect(transport.status, TransportStatus.disconnected);
    });

    test('每次写入有进展后重新计算五秒停滞时间', () {
      fakeAsync((async) {
        final session = _FakeSession(stalled: true, pauseAfterWrite: true);
        final transport = LibSerialPortSerialTransport(
          initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
          driver: _FakeDriver(session: session),
        );
        SendResult? result;
        Object? failure;
        unawaited(() async {
          await transport.open();
          try {
            result = await transport.send(Uint8List(3));
          } catch (error) {
            failure = error;
          }
        }());
        async.flushMicrotasks();
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(seconds: 4));
          session.stalled = false;
          async.elapse(const Duration(milliseconds: 1));
          expect(failure, isNull);
        }
        expect(result?.acceptedLength, 3);
        unawaited(transport.dispose());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('读流正常结束也会释放端口', () async {
      final session = _FakeSession();
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: _FakeDriver(session: session),
      );
      addTearDown(transport.dispose);
      await transport.open();
      final disconnected = transport.events.firstWhere(
        (event) => event is TransportDisconnectedEvent,
      );
      await session.finish();
      await disconnected.timeout(const Duration(seconds: 2));
      expect(transport.status, TransportStatus.disconnected);
      expect(session.events, contains('close'));
    });

    test('打开失败后允许修改参数并重新连接', () async {
      final driver = _FakeDriver(openError: const OSError('busy', 32));
      final transport = LibSerialPortSerialTransport(driver: driver);
      final controller = TerminalController(
        transport: transport,
        textEncoder: const Utf8TextByteEncoder(),
        backendLabel: '测试真实后端',
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.open();
      expect(controller.state.value.status, TransportStatus.error);
      await controller.updateConfig(
        controller.state.value.config.copyWith(baudRate: 9600),
      );
      expect(controller.state.value.errorMessage, isNull);
      expect(controller.state.value.config.baudRate, 9600);
      driver.openError = null;
      await controller.open();
      expect(controller.state.value.isConnected, isTrue);
      expect(driver.openedConfig?.baudRate, 9600);
    });

    test('关闭先终止在途发送再释放会话且并发关闭只通知一次', () async {
      final session = _FakeSession(writeSizes: List.filled(20, 1));
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: _FakeDriver(session: session),
      );
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);
      addTearDown(subscription.cancel);
      addTearDown(transport.dispose);
      await transport.open();
      final sending = transport.send(Uint8List(20));
      final failure = expectLater(sending, throwsA(isA<TransportException>()));
      await Future<void>.delayed(Duration.zero);
      await Future.wait([transport.close(), transport.close()]);
      await failure;
      expect(session.writesAfterClose, 0);
      expect(session.writeCalls, lessThan(20));
      expect(session.events.where((event) => event == 'close'), hasLength(1));
      expect(events.whereType<TransportDisconnectedEvent>(), hasLength(1));
    });

    test('驱动返回超出剩余长度的写入量时失败', () async {
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: _FakeDriver(session: _FakeSession(writeSizes: [99])),
      );
      addTearDown(transport.dispose);
      await transport.open();
      await expectLater(
        transport.send(Uint8List(1)),
        throwsA(isA<TransportException>()),
      );
    });

    test('零进展连续五秒后发送失败', () {
      fakeAsync((async) {
        final session = _FakeSession(stalled: true);
        final transport = LibSerialPortSerialTransport(
          initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
          driver: _FakeDriver(session: session),
        );
        Object? failure;
        unawaited(() async {
          await transport.open();
          try {
            await transport.send(Uint8List(1));
          } catch (error) {
            failure = error;
          }
        }());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(failure, isA<TransportException>());
        unawaited(transport.dispose());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('读流错误释放失败仍断开且可重新打开', () async {
      final session = _FakeSession(closeError: StateError('释放失败'));
      final driver = _FakeDriver(session: session);
      final transport = LibSerialPortSerialTransport(
        initialConfig: const SerialConfig(portName: 'COM9', baudRate: 115200),
        driver: driver,
      );
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);
      addTearDown(subscription.cancel);
      addTearDown(transport.dispose);
      await transport.open();
      session.emitError(const OSError('device removed', 2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transport.status, TransportStatus.disconnected);
      expect(events.whereType<TransportDisconnectedEvent>(), hasLength(1));
      driver.session = _FakeSession();
      await transport.open();
      expect(transport.status, TransportStatus.connected);
    });

    test('通过 driver 完成配置、短写重试、信号控制与有序释放', () async {
      final session = _FakeSession(writeSizes: <int>[1, 2]);
      final driver = _FakeDriver(session: session);
      final transport = LibSerialPortSerialTransport(driver: driver);
      final events = <TransportEvent>[];
      final subscription = transport.events.listen(events.add);
      const config = SerialConfig(
        portName: 'COM9',
        baudRate: 921600,
        parity: SerialParity.even,
        stopBits: SerialStopBits.two,
        flowControl: SerialFlowControl.xonXoff,
        initialDtr: true,
      );

      await transport.configure(config);
      await transport.open();

      expect(transport.status, TransportStatus.connected);
      expect(driver.openedConfig, same(config));
      expect(events.whereType<TransportConnectedEvent>(), hasLength(1));

      final result = await transport.send(Uint8List.fromList(<int>[1, 2, 3]));
      expect(result.acceptedLength, 3);
      expect(session.writeCalls, 2);
      expect(session.events.where((event) => event == 'write').length, 2);

      session.emitData(Uint8List.fromList(<int>[0x41, 0x42]));
      expect(
        events.whereType<TransportDataEvent>().single.bytes,
        orderedEquals(<int>[0x41, 0x42]),
      );

      await transport.setDtr(false);
      await transport.setRts(true);
      expect(session.dtr, isFalse);
      expect(session.rts, isTrue);

      await transport.dispose();
      expect(session.events, containsAllInOrder(<String>['cancel', 'close']));

      await subscription.cancel();
    });

    test('原生打开失败映射为稳定权限错误并进入 error 状态', () {
      fakeAsync((async) {
        final driver = _FakeDriver(
          openError: const OSError('access denied', 5),
        );
        final transport = LibSerialPortSerialTransport(driver: driver);
        Object? failure;
        unawaited(() async {
          try {
            await transport.configure(
              const SerialConfig(portName: 'COM1', baudRate: 115200),
            );
            await transport.open();
          } catch (error) {
            failure = error;
          }
        }());

        async.flushMicrotasks();
        expect(failure, isA<TransportException>());
        expect(
          (failure! as TransportException).error.code,
          TransportErrorCode.permissionDenied,
        );
        expect(transport.status, TransportStatus.error);

        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });

    test('流控占用引脚时拒绝手动 DTR/RTS', () {
      fakeAsync((async) {
        final session = _FakeSession();
        final transport = LibSerialPortSerialTransport(
          driver: _FakeDriver(session: session),
        );
        Object? failure;
        unawaited(() async {
          try {
            await transport.configure(
              const SerialConfig(
                portName: 'COM1',
                baudRate: 115200,
                flowControl: SerialFlowControl.rtsCts,
              ),
            );
            await transport.open();
            await transport.setRts(false);
          } catch (error) {
            failure = error;
          }
        }());

        async.flushMicrotasks();
        expect(failure, isA<TransportException>());
        expect(
          (failure! as TransportException).error.code,
          TransportErrorCode.unsupported,
        );

        unawaited(transport.dispose());
        async.flushMicrotasks();
      });
    });
  });
}

final class _FakeDriver implements LibSerialPortDriver {
  _FakeDriver({this.session, this.openError, this.openGate});

  final Completer<_FakeSession>? openGate;

  _FakeSession? session;
  Object? openError;
  SerialConfig? openedConfig;

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    return const <SerialPortInfo>[
      SerialPortInfo(
        systemPath: 'COM9',
        displayName: 'Fake COM9',
        isAvailable: true,
      ),
    ];
  }

  @override
  Future<LibSerialPortSession> open(SerialConfig config) async {
    openedConfig = config;
    final error = openError;
    if (error != null) {
      throw error;
    }
    return openGate != null
        ? await openGate!.future
        : session ?? _FakeSession();
  }
}

final class _FakeSession implements LibSerialPortSession {
  _FakeSession({
    List<int>? writeSizes,
    this.stalled = false,
    this.closeError,
    this.pauseAfterWrite = false,
    this.signalGate,
  }) : _writeSizes = writeSizes ?? <int>[];

  bool stalled;
  final bool pauseAfterWrite;
  final Completer<void>? signalGate;
  int signalReadsAfterClose = 0;
  final Object? closeError;
  int writesAfterClose = 0;

  final List<int> _writeSizes;
  late final StreamController<Uint8List> _dataController =
      StreamController<Uint8List>(
        sync: true,
        onCancel: () => events.add('cancel'),
      );
  final List<String> events = <String>[];
  int writeCalls = 0;
  bool dtr = false;
  bool rts = false;
  bool _closed = false;

  @override
  Stream<Uint8List> get data => _dataController.stream;

  @override
  SerialSignalState get signals {
    if (_closed) signalReadsAfterClose++;
    return SerialSignalState(cts: true, dsr: true, dtr: dtr, rts: rts);
  }

  void emitData(Uint8List bytes) {
    _dataController.add(bytes);
  }

  void emitError(Object error) => _dataController.addError(error);

  Future<void> finish() => _dataController.close();

  @override
  int write(Uint8List bytes) {
    if (_closed) writesAfterClose++;
    events.add('write');
    writeCalls++;
    if (pauseAfterWrite) {
      if (stalled) return 0;
      stalled = true;
      return 1;
    }
    return stalled
        ? 0
        : _writeSizes.isEmpty
        ? bytes.length
        : _writeSizes.removeAt(0);
  }

  @override
  Future<void> setDtr(bool enabled) async {
    if (signalGate != null) await signalGate!.future;
    dtr = enabled;
    events.add('dtr:$enabled');
  }

  @override
  Future<void> setRts(bool enabled) async {
    rts = enabled;
    events.add('rts:$enabled');
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    events.add('close');
    final hasListener = _dataController.hasListener;
    final closing = _dataController.close();
    if (hasListener) await closing;
    if (closeError != null) throw closeError!;
  }
}
