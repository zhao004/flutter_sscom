import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'libserialport_serial_transport.dart';
import 'simulated_serial_transport.dart';

/// 可用串口后端类型。
enum SerialBackendKind {
  /// 内置回环模拟后端。
  simulated,

  /// 实验性 flutter_libserialport 后端。
  libserialport,
}

/// 启动阶段选定的串口后端。
final class SerialBackendSelection {
  /// 创建后端选择结果。
  const SerialBackendSelection({
    required this.transport,
    required this.label,
    required this.isSimulated,
  });

  /// 已创建的传输实例。
  final SerialTransport transport;

  /// 面向 UI 的后端名称。
  final String label;

  /// 是否为模拟后端。
  final bool isSimulated;
}

/// 从编译期环境变量创建串口后端。
///
/// 默认使用真实串口；无硬件演示需显式指定
/// `--dart-define=SSCOM_SERIAL_BACKEND=simulated`。
SerialBackendSelection createSerialBackendFromEnvironment() {
  const backendName = String.fromEnvironment(
    'SSCOM_SERIAL_BACKEND',
    defaultValue: 'libserialport',
  );
  return createSerialBackend(backendName);
}

/// 根据稳定名称创建串口后端。
SerialBackendSelection createSerialBackend(String backendName) {
  final kind = resolveSerialBackendKind(backendName);
  return switch (kind) {
    SerialBackendKind.simulated => SerialBackendSelection(
      transport: SimulatedSerialTransport(),
      label: '模拟串口',
      isSimulated: true,
    ),
    SerialBackendKind.libserialport => SerialBackendSelection(
      transport: LibSerialPortSerialTransport(),
      label: 'libserialport 0.6.0（实验性）',
      isSimulated: false,
    ),
  };
}

/// 将后端名称解析为枚举；未知值立即失败。
SerialBackendKind resolveSerialBackendKind(String backendName) {
  return switch (backendName.trim().toLowerCase()) {
    'simulated' => SerialBackendKind.simulated,
    'libserialport' => SerialBackendKind.libserialport,
    _ => throw ArgumentError.value(
      backendName,
      'SSCOM_SERIAL_BACKEND',
      '仅支持 simulated 或 libserialport',
    ),
  };
}
