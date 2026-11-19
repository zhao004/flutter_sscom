import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/connection/infrastructure/libserialport_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('libserialport 配置映射', () {
    test('数据位、校验和流控映射稳定', () {
      expect(SerialDataBits.values.map(mapDataBits), <int>[5, 6, 7, 8]);
      expect(SerialParity.values.map(mapParity), <int>[0, 1, 2, 3, 4]);
      expect(SerialFlowControl.values.map(mapFlowControl), <int>[0, 2, 1, 3]);
    });

    test('停止位只接受 libserialport 支持的 1 和 2', () {
      expect(mapStopBits(SerialStopBits.one), 1);
      expect(mapStopBits(SerialStopBits.two), 2);
      expect(
        () => mapStopBits(SerialStopBits.onePointFive),
        throwsUnsupportedError,
      );
    });

    test('Windows 常见 OS 错误码映射为稳定分类', () {
      expect(
        classifyOsErrorCode(2, fallback: TransportErrorCode.unknown),
        TransportErrorCode.portNotFound,
      );
      expect(
        classifyOsErrorCode(5, fallback: TransportErrorCode.unknown),
        TransportErrorCode.permissionDenied,
      );
      expect(
        classifyOsErrorCode(32, fallback: TransportErrorCode.unknown),
        TransportErrorCode.portBusy,
      );
      expect(
        classifyOsErrorCode(170, fallback: TransportErrorCode.unknown),
        TransportErrorCode.portBusy,
      );
      expect(
        classifyOsErrorCode(999, fallback: TransportErrorCode.writeFailed),
        TransportErrorCode.writeFailed,
      );
    });
  });
}
