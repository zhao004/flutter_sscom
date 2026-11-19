import 'package:flutter_sscom/features/connection/infrastructure/serial_backend_factory.dart';
import 'package:flutter_sscom/features/connection/infrastructure/simulated_serial_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_sscom/features/connection/infrastructure/libserialport_serial_transport.dart';

void main() {
  group('串口后端选择', () {
    test('普通启动默认创建真实后端且不打开设备', () async {
      final selection = createSerialBackendFromEnvironment();
      expect(selection.transport, isA<LibSerialPortSerialTransport>());
      expect(selection.isSimulated, isFalse);
      await selection.transport.dispose();
    });
    test('后端名称大小写和空白不敏感', () {
      expect(
        resolveSerialBackendKind(' simulated '),
        SerialBackendKind.simulated,
      );
      expect(
        resolveSerialBackendKind('LIBSERIALPORT'),
        SerialBackendKind.libserialport,
      );
    });

    test('未知后端立即失败', () {
      expect(
        () => resolveSerialBackendKind('native-service'),
        throwsArgumentError,
      );
    });

    test('显式选择仍可创建模拟后端', () {
      final selection = createSerialBackend('simulated');
      expect(selection.transport, isA<SimulatedSerialTransport>());
      expect(selection.label, '模拟串口');
      expect(selection.isSimulated, isTrue);
    });
  });
}
