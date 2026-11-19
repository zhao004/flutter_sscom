import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_sscom/core/buffers/buffers.dart';
import 'package:flutter_test/flutter_test.dart';

const _window = Duration(milliseconds: 100);

void main() {
  group('ByteBatchScheduler', () {
    test('拒绝非法构造参数', () {
      expect(
        () => ByteBatchScheduler(
          flushInterval: Duration.zero,
          maxPendingBytes: 1,
          onBatch: (_) {},
        ),
        throwsArgumentError,
      );
      expect(
        () => ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 0,
          onBatch: (_) {},
        ),
        throwsArgumentError,
      );
    });

    test('从首批数据开始固定窗口，不在后续追加时重置', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final scheduler = ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 8,
          onBatch: (batch) => batches.add(batch.toList()),
        );

        scheduler.add(_bytes(<int>[1]));
        async.elapse(const Duration(milliseconds: 90));
        scheduler.add(_bytes(<int>[2]));
        async.elapse(const Duration(milliseconds: 9));
        expect(batches, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(batches, hasLength(1));
        expect(batches.single, orderedEquals(<int>[1, 2]));
        scheduler.dispose();
      });
    });

    test('恰好达到最大待处理字节数时立即刷新', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final scheduler = ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 3,
          onBatch: (batch) => batches.add(batch.toList()),
        );

        scheduler.add(_bytes(<int>[1, 2, 3]));
        expect(scheduler.pendingLength, 0);
        expect(batches, hasLength(1));
        expect(batches.single, orderedEquals(<int>[1, 2, 3]));

        async.elapse(const Duration(seconds: 1));
        expect(batches, hasLength(1));
        scheduler.dispose();
      });
    });

    test('跨多个上限的单次追加依次发出完整批次并保留尾部', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final scheduler = ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 3,
          onBatch: (batch) => batches.add(batch.toList()),
        );

        scheduler.add(_bytes(<int>[1, 2, 3, 4, 5, 6, 7]));
        expect(batches, hasLength(2));
        expect(batches[0], orderedEquals(<int>[1, 2, 3]));
        expect(batches[1], orderedEquals(<int>[4, 5, 6]));
        expect(scheduler.pendingLength, 1);

        async.elapse(_window);
        expect(batches, hasLength(3));
        expect(batches[2], orderedEquals(<int>[7]));
        scheduler.dispose();
      });
    });

    test('手动刷新立即发出并取消计时器', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final scheduler = ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 8,
          onBatch: (batch) => batches.add(batch.toList()),
        );

        scheduler.flushNow();
        expect(batches, isEmpty);

        scheduler.add(_bytes(<int>[1, 2]));
        scheduler.flushNow();
        expect(batches, hasLength(1));
        expect(batches.single, orderedEquals(<int>[1, 2]));

        async.elapse(_window);
        expect(batches, hasLength(1));
        scheduler.dispose();
      });
    });

    test('销毁后取消计时器、丢弃待发数据且禁止后续操作', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final scheduler = ByteBatchScheduler(
          flushInterval: _window,
          maxPendingBytes: 8,
          onBatch: (batch) => batches.add(batch.toList()),
        );

        scheduler.add(_bytes(<int>[1]));
        scheduler.dispose();
        async.elapse(_window);

        expect(batches, isEmpty);
        expect(scheduler.pendingLength, 0);
        expect(() => scheduler.add(_bytes(<int>[2])), throwsStateError);
        expect(scheduler.flushNow, throwsStateError);
        expect(scheduler.dispose, returnsNormally);
      });
    });
  });
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);
