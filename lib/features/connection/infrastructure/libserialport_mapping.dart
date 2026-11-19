import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 将核心数据位映射为 libserialport 数值。
int mapDataBits(SerialDataBits dataBits) => dataBits.value;

/// 将核心校验方式映射为 libserialport 数值。
int mapParity(SerialParity parity) {
  return switch (parity) {
    SerialParity.none => 0,
    SerialParity.odd => 1,
    SerialParity.even => 2,
    SerialParity.mark => 3,
    SerialParity.space => 4,
  };
}

/// 将核心停止位映射为 libserialport 数值。
///
/// libserialport 的公开实现只可靠支持 1 和 2 个停止位。
int mapStopBits(SerialStopBits stopBits) {
  return switch (stopBits) {
    SerialStopBits.one => 1,
    SerialStopBits.two => 2,
    SerialStopBits.onePointFive => throw UnsupportedError(
      'libserialport 后端不支持 1.5 停止位',
    ),
  };
}

/// 将核心流控方式映射为 libserialport 数值。
int mapFlowControl(SerialFlowControl flowControl) {
  return switch (flowControl) {
    SerialFlowControl.none => 0,
    SerialFlowControl.xonXoff => 1,
    SerialFlowControl.rtsCts => 2,
    SerialFlowControl.dtrDsr => 3,
  };
}

/// 将操作系统错误码映射为稳定的传输错误分类。
TransportErrorCode classifyOsErrorCode(
  int? errorCode, {
  required TransportErrorCode fallback,
}) {
  return switch (errorCode) {
    2 || 3 => TransportErrorCode.portNotFound,
    5 => TransportErrorCode.permissionDenied,
    32 || 170 => TransportErrorCode.portBusy,
    _ => fallback,
  };
}
