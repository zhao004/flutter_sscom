import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';

/// 将 [TerminalController] 的有序接收流适配为 ISP 字节通道。
///
/// 写入通过独占发送入口执行，避免其他发送任务插入协议帧；读取在内存队列中
/// 聚合串口分包，只向协议核心暴露完整请求的响应字节。
final class TerminalIspLink implements IspLink {
  /// 创建终端 ISP 通道。
  TerminalIspLink({required this.terminal, required this.owner}) {
    _subscription = terminal.receivedData.listen(_handleData);
  }

  /// 串口工作区控制器。
  final TerminalController terminal;

  /// 独占发送 owner。
  final Object owner;

  final Queue<int> _buffer = Queue<int>();
  StreamSubscription<Uint8List>? _subscription;
  Completer<Uint8List>? _pendingRead;
  int _pendingLength = 0;
  Timer? _pendingTimer;
  bool _closed = false;

  @override
  Future<void> write(Uint8List bytes) async {
    _ensureOpen();
    final result = await terminal.sendBytes(bytes, exclusiveOwner: owner);
    if (result == null) {
      throw IspException(
        code: IspErrorCode.transport,
        message: terminal.state.value.errorMessage ?? 'ISP 串口写入失败',
      );
    }
  }

  @override
  Future<Uint8List> readExact(int length, {required Duration timeout}) {
    _ensureOpen();
    if (length <= 0) {
      throw ArgumentError.value(length, 'length', '读取长度必须大于 0');
    }
    if (_pendingRead != null) {
      throw StateError('TerminalIspLink 同时只允许一个待处理读取');
    }
    if (_buffer.length >= length) {
      return Future<Uint8List>.value(_takeBytes(length));
    }

    final completer = Completer<Uint8List>();
    _pendingRead = completer;
    _pendingLength = length;
    _pendingTimer = Timer(timeout, () {
      final pending = _pendingRead;
      _clearPendingRead();
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          const IspException(
            code: IspErrorCode.timeout,
            message: '等待 bootloader 响应超时',
          ),
        );
      }
    });
    return completer.future;
  }

  @override
  Future<void> clearInput() async {
    _ensureOpen();
    _buffer.clear();
    final pending = _pendingRead;
    _clearPendingRead();
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const IspException(code: IspErrorCode.framing, message: 'ISP 输入已清空'),
      );
    }
  }

  @override
  Future<void> setDtr(bool enabled) => terminal.setDtr(enabled);

  @override
  Future<void> setRts(bool enabled) => terminal.setRts(enabled);

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    final pending = _pendingRead;
    _clearPendingRead();
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const IspException(
          code: IspErrorCode.transport,
          message: 'ISP 串口通道已关闭',
        ),
      );
    }
  }

  void _handleData(Uint8List bytes) {
    if (_closed || bytes.isEmpty) {
      return;
    }
    _buffer.addAll(bytes);
    final pending = _pendingRead;
    if (pending != null && _buffer.length >= _pendingLength) {
      final result = _takeBytes(_pendingLength);
      _clearPendingRead();
      if (!pending.isCompleted) {
        pending.complete(result);
      }
    }
  }

  Uint8List _takeBytes(int length) {
    final result = Uint8List(length);
    for (var index = 0; index < length; index++) {
      result[index] = _buffer.removeFirst();
    }
    return result;
  }

  void _clearPendingRead() {
    _pendingRead = null;
    _pendingLength = 0;
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('TerminalIspLink 已关闭');
    }
  }
}
