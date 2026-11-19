import 'dart:async';
import 'dart:typed_data';

/// 在所属 isolate 中定时执行非阻塞读取，关闭后不会再次访问原生端口。
///
/// 只在活动会话有订阅时读取数据，不枚举端口或轮询控制信号。单次读取有界，
/// 避免大批输入长时间占用 UI isolate；原生资源由会话在 [close] 后释放。
final class SerialReadPump {
  /// 注入非阻塞端口操作，便于验证取消读取与资源释放的时序。
  SerialReadPump({
    required this.bytesAvailable,
    required this.read,
    required this.readError,
  });

  final int Function() bytesAvailable;
  final Uint8List Function(int count) read;
  final Object Function() readError;

  static const _readInterval = Duration(milliseconds: 5);
  static const _maxReadBytes = 64 * 1024;

  late final _controller = StreamController<Uint8List>.broadcast(
    sync: true,
    onListen: _start,
    onCancel: _stop,
  );
  Timer? _timer;
  bool _closed = false;

  /// 仅包含原始字节和读取错误的接收流。
  Stream<Uint8List> get stream => _controller.stream;

  void _start() {
    if (_closed) return;
    _timer ??= Timer.periodic(_readInterval, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _poll() {
    if (_closed) return;
    try {
      final available = bytesAvailable();
      if (available < 0) throw readError();
      if (available == 0) return;
      final bytes = read(available.clamp(0, _maxReadBytes));
      if (bytes.isNotEmpty) _controller.add(bytes);
    } catch (error, stackTrace) {
      _stop();
      _controller.addError(error, stackTrace);
    }
  }

  /// 同步停止读取，再关闭数据流；重复调用保持幂等。
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    _stop();
    return _controller.close();
  }
}
