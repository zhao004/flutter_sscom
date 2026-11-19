import 'dart:io';

/// 当前工作区使用的传输方式。
enum TransportMode {
  /// 串口。
  serial,

  /// TCP 客户端。
  tcpClient,

  /// TCP 服务端。
  tcpServer,

  /// UDP 数据报。
  udp,
}

/// 网络调试通道的安全模式。
enum NetworkSafetyMode {
  /// 默认仅监听本机、单客户端并使用有界接收投影。
  safe,

  /// 保留面向设备调试的原始网络语义。
  rawDebug,
}

/// 串口数据位。
enum SerialDataBits {
  /// 5 位数据。
  five(5),

  /// 6 位数据。
  six(6),

  /// 7 位数据。
  seven(7),

  /// 8 位数据。
  eight(8);

  const SerialDataBits(this.value);

  /// 平台无关的数据位数值。
  final int value;
}

/// 串口停止位。
enum SerialStopBits {
  /// 1 位停止位。
  one,

  /// 1.5 位停止位。
  onePointFive,

  /// 2 位停止位。
  two,
}

/// 串口校验方式。
enum SerialParity {
  /// 无校验。
  none,

  /// 奇校验。
  odd,

  /// 偶校验。
  even,

  /// 标记校验。
  mark,

  /// 空格校验。
  space,
}

/// 串口流控方式。
enum SerialFlowControl {
  /// 无流控。
  none,

  /// RTS/CTS 硬件流控。
  rtsCts,

  /// XON/XOFF 软件流控。
  xonXoff,

  /// DTR/DSR 硬件流控。
  dtrDsr,
}

/// 单个串口的结构化信息。
final class SerialPortInfo {
  /// 创建串口信息。
  const SerialPortInfo({
    required this.systemPath,
    required this.displayName,
    required this.isAvailable,
  });

  /// 操作系统使用的端口路径，例如 `COM5`。
  final String systemPath;

  /// 面向用户显示的端口名称。
  final String displayName;

  /// 枚举时端口是否可用。
  final bool isAvailable;
}

/// 串口打开和配置参数。
final class SerialConfig {
  /// 创建串口配置。
  const SerialConfig({
    required this.portName,
    required this.baudRate,
    this.dataBits = SerialDataBits.eight,
    this.stopBits = SerialStopBits.one,
    this.parity = SerialParity.none,
    this.flowControl = SerialFlowControl.none,
    this.initialDtr = false,
    this.initialRts = false,
  }) : assert(baudRate > 0);

  /// 端口路径。
  final String portName;

  /// 波特率。
  final int baudRate;

  /// 数据位。
  final SerialDataBits dataBits;

  /// 停止位。
  final SerialStopBits stopBits;

  /// 校验方式。
  final SerialParity parity;

  /// 流控方式。
  final SerialFlowControl flowControl;

  /// 打开后 DTR 的默认状态。
  final bool initialDtr;

  /// 打开后 RTS 的默认状态。
  final bool initialRts;

  /// 返回替换部分字段后的串口配置。
  SerialConfig copyWith({
    String? portName,
    int? baudRate,
    SerialDataBits? dataBits,
    SerialStopBits? stopBits,
    SerialParity? parity,
    SerialFlowControl? flowControl,
    bool? initialDtr,
    bool? initialRts,
  }) {
    return SerialConfig(
      portName: portName ?? this.portName,
      baudRate: baudRate ?? this.baudRate,
      dataBits: dataBits ?? this.dataBits,
      stopBits: stopBits ?? this.stopBits,
      parity: parity ?? this.parity,
      flowControl: flowControl ?? this.flowControl,
      initialDtr: initialDtr ?? this.initialDtr,
      initialRts: initialRts ?? this.initialRts,
    );
  }
}

/// 传输工厂的配置基类。
sealed class TransportConfig {
  const TransportConfig();
}

/// 创建串口传输时使用的配置。
final class SerialTransportConfig extends TransportConfig {
  /// 创建串口传输配置。
  const SerialTransportConfig({required this.serial});

  /// 串口参数。
  final SerialConfig serial;
}

/// 创建 TCP 客户端时使用的配置。
final class TcpClientTransportConfig extends TransportConfig {
  /// 创建 TCP 客户端配置。
  const TcpClientTransportConfig({required this.host, required this.port})
    : assert(port > 0 && port <= 65535);

  /// 远端主机名或 IP 地址。
  final String host;

  /// 远端端口。
  final int port;
}

/// 创建 TCP 服务端时使用的配置。
final class TcpServerTransportConfig extends TransportConfig {
  /// 创建 TCP 服务端配置。
  ///
  /// [port] 为零时由操作系统分配临时端口，主要供自动化测试使用。
  const TcpServerTransportConfig({
    required this.bindAddress,
    required this.port,
  }) : assert(port >= 0 && port <= 65535);

  /// 监听地址。
  final String bindAddress;

  /// 监听端口。
  final int port;
}

/// 创建 UDP 传输时使用的配置。
final class UdpTransportConfig extends TransportConfig {
  /// 创建 UDP 配置。
  ///
  /// [localPort] 为零时由操作系统分配临时端口，主要供自动化测试使用。
  const UdpTransportConfig({
    required this.bindAddress,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.followRemoteEndpoint,
  }) : assert(localPort >= 0 && localPort <= 65535),
       assert(remotePort > 0 && remotePort <= 65535);

  /// 本地绑定地址。
  final String bindAddress;

  /// 本地绑定端口。
  final int localPort;

  /// 默认远端主机；为空时只能回复最近发送方。
  final String remoteHost;

  /// 默认远端端口。
  final int remotePort;

  /// 收到数据报后是否把发送目标更新为数据报来源。
  final bool followRemoteEndpoint;
}

/// 判断监听地址是否只接受本机连接。
bool isLoopbackBindAddress(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'^\[|\]$'),
    '',
  );
  if (normalized == 'localhost') {
    return true;
  }
  final address = InternetAddress.tryParse(normalized);
  return address?.isLoopback ?? false;
}

/// 一次发送操作的结果。
final class SendResult {
  /// 创建发送结果。
  const SendResult({
    required this.requestedLength,
    required this.acceptedLength,
    required this.completedAt,
  });

  /// 调用方请求发送的字节数。
  final int requestedLength;

  /// 传输层实际接受的字节数。
  final int acceptedLength;

  /// 发送操作完成时间。
  final DateTime completedAt;

  /// 是否所有请求字节均被接受。
  bool get isComplete => requestedLength == acceptedLength;
}
