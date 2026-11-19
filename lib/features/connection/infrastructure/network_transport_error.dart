import 'dart:io';

import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 将底层网络异常映射为稳定的传输错误。
///
/// 错误说明只包含主机、端口和系统错误文本，不记录网络载荷。
TransportError mapNetworkIoError(
  Object error, {
  required TransportErrorCode fallbackCode,
  required String message,
}) {
  if (error is TransportException) {
    return error.error;
  }
  if (error is SocketException) {
    final code = switch (error.osError?.errorCode) {
      5 || 13 => TransportErrorCode.permissionDenied,
      98 || 10048 => TransportErrorCode.portBusy,
      11001 => TransportErrorCode.addressResolutionFailed,
      10049 => TransportErrorCode.bindFailed,
      10061 || 111 => TransportErrorCode.connectionFailed,
      _ => fallbackCode,
    };
    return TransportError(
      code: code,
      message: '$message：${error.message}',
      cause: error,
    );
  }
  return TransportError(
    code: fallbackCode,
    message: '$message：$error',
    cause: error,
  );
}

/// 创建网络传输的状态或参数异常。
TransportException networkTransportException(
  TransportErrorCode code,
  String message,
) {
  return TransportException(TransportError(code: code, message: message));
}
