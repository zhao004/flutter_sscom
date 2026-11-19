import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/features/connection/infrastructure/serial_read_pump.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('非阻塞读取有界且关闭后不会访问已释放的端口', () {
    fakeAsync((async) {
      var released = false;
      var calls = 0;
      final chunks = <Uint8List>[];
      final reader = SerialReadPump(
        bytesAvailable: () {
          expect(released, isFalse);
          calls++;
          return 100000;
        },
        read: (count) => Uint8List(count),
        readError: () => StateError('读取失败'),
      );
      reader.stream.listen(chunks.add);
      async.elapse(const Duration(milliseconds: 5));
      expect(chunks.single.length, 64 * 1024);
      reader.close();
      released = true;
      async.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('负值或读取异常只发布一次错误并停止访问端口', () {
    for (final throwOnRead in [false, true]) {
      fakeAsync((async) {
        final failure = StateError('设备断开');
        var calls = 0;
        final errors = <Object>[];
        final reader = SerialReadPump(
          bytesAvailable: () {
            calls++;
            return throwOnRead ? 1 : -1;
          },
          read: (_) => throw failure,
          readError: () => failure,
        );
        reader.stream.listen((_) {}, onError: errors.add);
        async.elapse(const Duration(seconds: 1));
        expect(errors, [failure]);
        expect(calls, 1);
        reader.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    }
  });

  test('未订阅和取消订阅后不读取，未订阅时也能关闭', () async {
    final reader = SerialReadPump(
      bytesAvailable: () => throw StateError('不应读取'),
      read: (_) => Uint8List(0),
      readError: () => StateError('读取失败'),
    );
    final subscription = reader.stream.listen((_) {});
    await subscription.cancel();
    await reader.close();
    await reader.close();
    final unused = SerialReadPump(
      bytesAvailable: () => 0,
      read: (_) => Uint8List(0),
      readError: () => StateError('读取失败'),
    );
    await unused.close();
  });
}
