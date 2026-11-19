import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';

/// 终端显示模式。
enum TerminalDisplayMode {
  /// 解码后的文本视图。
  text,

  /// 十六进制与 ASCII 预览视图。
  hex,
}

/// 终端中的一条虚拟化渲染行。
final class TerminalLine {
  /// 创建终端行。
  const TerminalLine({
    required this.text,
    required this.timestamp,
    required this.byteOffset,
  });

  /// 已格式化的显示文本。
  final String text;

  /// 该行首次收到数据的时间。
  final DateTime timestamp;

  /// 文本行对应的大致接收字节偏移；HEX 行表示首字节偏移。
  final int byteOffset;
}

/// 发送请求。
final class SendRequest {
  /// 创建发送请求。
  ///
  /// 输入模式和校验偏好由 [TerminalViewState] 提供。
  const SendRequest({required this.input});

  /// 用户输入。
  final String input;
}

const Object _notSet = Object();

/// 串口与网络工作区的只读表现层状态。
final class TerminalViewState {
  /// 创建终端视图状态。
  TerminalViewState({
    required this.status,
    required List<SerialPortInfo> ports,
    required this.config,
    required this.signals,
    required List<TerminalLine> lines,
    required this.backendLabel,
    required this.isSimulatedBackend,
    this.transportMode = TransportMode.serial,
    this.networkSafetyMode = NetworkSafetyMode.safe,
    this.remoteHost = '',
    this.remotePort = 5001,
    this.bindAddress = '127.0.0.1',
    this.localPort = 5001,
    this.followRemoteEndpoint = true,
    this.connectionDetail,
    this.displayMode = TerminalDisplayMode.text,
    this.showTimestamp = false,
    this.autoScroll = true,
    this.sendMode = SendInputMode.ansiText,
    this.sendChecksumMode = LegacyChecksumMode.none,
    this.sendChecksumStartByte = 1,
    this.sendChecksumTrailingByteCount = 0,
    this.sendAppendCrLf = false,
    this.textDraft = '',
    this.hexDraft = '',
    this.isRefreshingPorts = false,
    this.isOpening = false,
    this.isSending = false,
    this.isExclusiveSend = false,
    this.receivedBytes = 0,
    this.sentBytes = 0,
    this.droppedBytes = 0,
    this.droppedLines = 0,
    this.noticeMessage,
    this.errorMessage,
  }) : ports = List<SerialPortInfo>.unmodifiable(ports),
       lines = List<TerminalLine>.unmodifiable(lines);

  /// 当前连接状态。
  final TransportStatus status;

  /// 最近一次端口枚举结果。
  final List<SerialPortInfo> ports;

  /// 当前串口配置。
  final SerialConfig config;

  /// 最近一次串口信号状态。
  final SerialSignalState signals;

  /// 当前显示模式对应的虚拟化行。
  final List<TerminalLine> lines;

  /// 当前显示模式。
  final TerminalDisplayMode displayMode;

  /// 是否显示逐行时间戳。
  final bool showTimestamp;

  /// 新数据到达时是否自动滚动到底部。
  final bool autoScroll;

  /// 当前发送输入模式。
  final SendInputMode sendMode;

  /// 当前发送校验模式。
  final LegacyChecksumMode sendChecksumMode;

  /// 1-based 校验起始位置。
  final int sendChecksumStartByte;

  /// 从帧尾排除的字节数。
  final int sendChecksumTrailingByteCount;

  /// 文本发送是否追加 CRLF。
  final bool sendAppendCrLf;

  /// 最近文本草稿。
  final String textDraft;

  /// 最近 HEX 草稿。
  final String hexDraft;

  /// 当前后端名称。
  final String backendLabel;

  /// 是否使用内置模拟后端。
  final bool isSimulatedBackend;

  /// 当前传输方式。
  final TransportMode transportMode;

  /// 网络调试通道的安全模式。
  final NetworkSafetyMode networkSafetyMode;

  /// TCP/UDP 远端主机。
  final String remoteHost;

  /// TCP/UDP 远端端口。
  final int remotePort;

  /// TCP 服务端或 UDP 的本地监听地址。
  final String bindAddress;

  /// TCP 服务端或 UDP 的本地端口。
  final int localPort;

  /// UDP 是否跟随最近数据报来源更新发送目标。
  final bool followRemoteEndpoint;

  /// 当前传输的地址、等待连接或断开说明。
  final String? connectionDetail;

  /// 是否正在刷新端口。
  final bool isRefreshingPorts;

  /// 是否正在打开串口。
  final bool isOpening;

  /// 是否正在发送数据。
  final bool isSending;

  /// 是否由 ISP 等独占发送流程持有当前串口。
  final bool isExclusiveSend;

  /// 会话累计接收字节数。
  final int receivedBytes;

  /// 会话累计发送字节数。
  final int sentBytes;

  /// 因原始环形缓冲上限累计丢弃的字节数。
  final int droppedBytes;

  /// 当前视图因行数上限累计丢弃的行数。
  final int droppedLines;

  /// 最近一次非致命启动或迁移提示。
  final String? noticeMessage;

  /// 最近一次可展示错误。
  final String? errorMessage;

  /// 是否已连接。
  bool get isConnected => status == TransportStatus.connected;

  /// 传输是否已开始打开、监听或连接。
  bool get isTransportActive => switch (status) {
    TransportStatus.connecting ||
    TransportStatus.connected ||
    TransportStatus.listening ||
    TransportStatus.disconnecting => true,
    TransportStatus.disconnected || TransportStatus.error => false,
  };

  /// 是否正在使用 TCP 或 UDP。
  bool get isNetworkMode => transportMode != TransportMode.serial;

  /// 是否允许修改串口参数。
  bool get canConfigure =>
      status == TransportStatus.disconnected || status == TransportStatus.error;

  /// 返回替换部分字段后的状态。
  TerminalViewState copyWith({
    TransportStatus? status,
    List<SerialPortInfo>? ports,
    SerialConfig? config,
    SerialSignalState? signals,
    List<TerminalLine>? lines,
    TerminalDisplayMode? displayMode,
    bool? showTimestamp,
    bool? autoScroll,
    SendInputMode? sendMode,
    LegacyChecksumMode? sendChecksumMode,
    int? sendChecksumStartByte,
    int? sendChecksumTrailingByteCount,
    bool? sendAppendCrLf,
    String? textDraft,
    String? hexDraft,
    String? backendLabel,
    bool? isSimulatedBackend,
    TransportMode? transportMode,
    NetworkSafetyMode? networkSafetyMode,
    String? remoteHost,
    int? remotePort,
    String? bindAddress,
    int? localPort,
    bool? followRemoteEndpoint,
    Object? connectionDetail = _notSet,
    bool? isRefreshingPorts,
    bool? isOpening,
    bool? isSending,
    bool? isExclusiveSend,
    int? receivedBytes,
    int? sentBytes,
    int? droppedBytes,
    int? droppedLines,
    Object? noticeMessage = _notSet,
    Object? errorMessage = _notSet,
  }) {
    return TerminalViewState(
      status: status ?? this.status,
      ports: ports ?? this.ports,
      config: config ?? this.config,
      signals: signals ?? this.signals,
      lines: lines ?? this.lines,
      displayMode: displayMode ?? this.displayMode,
      showTimestamp: showTimestamp ?? this.showTimestamp,
      autoScroll: autoScroll ?? this.autoScroll,
      sendMode: sendMode ?? this.sendMode,
      sendChecksumMode: sendChecksumMode ?? this.sendChecksumMode,
      sendChecksumStartByte:
          sendChecksumStartByte ?? this.sendChecksumStartByte,
      sendChecksumTrailingByteCount:
          sendChecksumTrailingByteCount ?? this.sendChecksumTrailingByteCount,
      sendAppendCrLf: sendAppendCrLf ?? this.sendAppendCrLf,
      textDraft: textDraft ?? this.textDraft,
      hexDraft: hexDraft ?? this.hexDraft,
      backendLabel: backendLabel ?? this.backendLabel,
      isSimulatedBackend: isSimulatedBackend ?? this.isSimulatedBackend,
      transportMode: transportMode ?? this.transportMode,
      networkSafetyMode: networkSafetyMode ?? this.networkSafetyMode,
      remoteHost: remoteHost ?? this.remoteHost,
      remotePort: remotePort ?? this.remotePort,
      bindAddress: bindAddress ?? this.bindAddress,
      localPort: localPort ?? this.localPort,
      followRemoteEndpoint: followRemoteEndpoint ?? this.followRemoteEndpoint,
      connectionDetail: identical(connectionDetail, _notSet)
          ? this.connectionDetail
          : connectionDetail as String?,
      isRefreshingPorts: isRefreshingPorts ?? this.isRefreshingPorts,
      isOpening: isOpening ?? this.isOpening,
      isSending: isSending ?? this.isSending,
      isExclusiveSend: isExclusiveSend ?? this.isExclusiveSend,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      sentBytes: sentBytes ?? this.sentBytes,
      droppedBytes: droppedBytes ?? this.droppedBytes,
      droppedLines: droppedLines ?? this.droppedLines,
      noticeMessage: identical(noticeMessage, _notSet)
          ? this.noticeMessage
          : noticeMessage as String?,
      errorMessage: identical(errorMessage, _notSet)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}
