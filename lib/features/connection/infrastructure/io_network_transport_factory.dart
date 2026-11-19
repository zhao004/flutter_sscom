import 'package:flutter_sscom/core/transport/transport_barrel.dart';

import 'tcp_client_transport.dart';
import 'tcp_server_transport.dart';
import 'udp_transport.dart';

/// 使用 `dart:io` 创建 TCP/UDP 传输。
final class IoNetworkTransportFactory implements TransportFactory {
  /// 创建无状态网络传输工厂。
  const IoNetworkTransportFactory();

  @override
  Transport create(TransportConfig config) {
    return switch (config) {
      TcpClientTransportConfig() => TcpClientTransport(
        host: config.host,
        port: config.port,
      ),
      TcpServerTransportConfig() => TcpServerTransport(
        bindAddress: config.bindAddress,
        port: config.port,
      ),
      UdpTransportConfig() => UdpTransport(
        bindAddress: config.bindAddress,
        localPort: config.localPort,
        remoteHost: config.remoteHost,
        remotePort: config.remotePort,
        followRemoteEndpoint: config.followRemoteEndpoint,
      ),
      SerialTransportConfig() => throw ArgumentError.value(
        config,
        'config',
        '网络传输工厂不能创建串口传输',
      ),
    };
  }
}
