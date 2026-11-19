import 'dart:typed_data';

import 'transport_config.dart';
import 'transport_event.dart';

/// 传输连接状态。
enum TransportStatus {
  /// 未连接。
  disconnected,

  /// 正在连接。
  connecting,

  /// 已连接。
  connected,

  /// 服务端正在监听，等待客户端连接。
  listening,

  /// 正在断开。
  disconnecting,

  /// 上次操作后处于错误状态。
  error,
}

/// 串口、TCP 或 UDP 共用的传输契约。
abstract interface class Transport {
  /// 传输事件广播流。
  Stream<TransportEvent> get events;

  /// 当前连接状态。
  TransportStatus get status;

  /// 打开传输。
  Future<void> open();

  /// 关闭连接；实现必须保证幂等，并允许随后重新打开。
  Future<void> close();

  /// 释放传输及其事件流；重复调用无副作用。
  Future<void> dispose();

  /// 发送原始字节。
  Future<SendResult> send(Uint8List bytes);
}

/// 串口传输契约。
abstract interface class SerialTransport implements Transport {
  /// 枚举当前系统串口。
  Future<List<SerialPortInfo>> listPorts();

  /// 端口列表变化广播流。
  Stream<List<SerialPortInfo>> get portChanges;

  /// 修改串口配置；只能在未连接状态调用。
  Future<void> configure(SerialConfig config);

  /// 设置 DTR 输出状态。
  Future<void> setDtr(bool enabled);

  /// 设置 RTS 输出状态。
  Future<void> setRts(bool enabled);
}

/// 根据配置创建传输实例。
abstract interface class TransportFactory {
  /// 创建指定配置对应的传输。
  Transport create(TransportConfig config);
}
