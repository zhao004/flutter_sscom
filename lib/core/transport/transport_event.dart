import 'dart:typed_data';

import 'transport_error.dart';

/// 串口输入和控制信号状态。
final class SerialSignalState {
  /// 创建信号状态。
  const SerialSignalState({
    this.cts = false,
    this.dsr = false,
    this.dcd = false,
    this.ri = false,
    this.dtr = false,
    this.rts = false,
  });

  /// CTS 输入状态。
  final bool cts;

  /// DSR 输入状态。
  final bool dsr;

  /// DCD 输入状态。
  final bool dcd;

  /// RI 输入状态。
  final bool ri;

  /// DTR 输出状态。
  final bool dtr;

  /// RTS 输出状态。
  final bool rts;
}

/// 传输层事件基类。
sealed class TransportEvent {
  const TransportEvent(this.occurredAt);

  /// 事件发生时间。
  final DateTime occurredAt;
}

/// 传输已经连接。
final class TransportConnectedEvent extends TransportEvent {
  /// 创建连接事件。
  TransportConnectedEvent({this.detail, DateTime? occurredAt})
    : super(occurredAt ?? DateTime.now());

  /// 可选的连接目标说明。
  final String? detail;
}

/// 传输已开始监听，但尚未建立数据连接。
final class TransportListeningEvent extends TransportEvent {
  /// 创建监听事件。
  TransportListeningEvent({this.detail, DateTime? occurredAt})
    : super(occurredAt ?? DateTime.now());

  /// 可选的监听地址和等待状态说明。
  final String? detail;
}

/// 传输已经断开。
final class TransportDisconnectedEvent extends TransportEvent {
  /// 创建断开事件。
  TransportDisconnectedEvent({this.reason, DateTime? occurredAt})
    : super(occurredAt ?? DateTime.now());

  /// 可选的断开原因。
  final String? reason;
}

/// 收到传输数据。
final class TransportDataEvent extends TransportEvent {
  /// 创建数据事件，并复制输入字节。
  TransportDataEvent(Uint8List bytes, {DateTime? occurredAt})
    : bytes = Uint8List.fromList(bytes),
      super(occurredAt ?? DateTime.now());

  /// 当次收到的数据副本。
  final Uint8List bytes;
}

/// 传输层发生错误。
final class TransportErrorEvent extends TransportEvent {
  /// 创建错误事件。
  TransportErrorEvent(this.error, {DateTime? occurredAt})
    : super(occurredAt ?? DateTime.now());

  /// 结构化错误。
  final TransportError error;
}

/// 串口信号状态发生变化。
final class TransportSignalChangedEvent extends TransportEvent {
  /// 创建信号变化事件。
  TransportSignalChangedEvent(this.signals, {DateTime? occurredAt})
    : super(occurredAt ?? DateTime.now());

  /// 最新信号状态。
  final SerialSignalState signals;
}
