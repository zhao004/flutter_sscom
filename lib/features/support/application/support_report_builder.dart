import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/support/domain/app_release_info.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';

/// 构建可供用户审阅和提交的脱敏诊断报告。
///
/// 报告不包含串口原始数据、发送草稿、多字符串名称/内容、固件路径或远端
/// 主机明文。用户可见错误会移除远端主机和常见 Windows 绝对路径后截断。
String buildSupportReport({
  required AppReleaseInfo release,
  required TerminalViewState terminal,
  required MultiSendState multiSend,
  required DateTime generatedAt,
  required String operatingSystemVersion,
}) {
  final generatedUtc = generatedAt.toUtc().toIso8601String();
  final enabledMultiSend = multiSend.entries
      .where((entry) => entry.enabled && entry.payload.trim().isNotEmpty)
      .length;
  final error = _sanitizeError(terminal.errorMessage, terminal.remoteHost);
  return <String>[
    '# SSCOM 诊断报告',
    '',
    '## 发布信息',
    '- 生成时间：$generatedUtc',
    '- 产品：${release.product}',
    '- 版本：${release.displayVersion}',
    '- 发布渠道：${release.channel}',
    '- 串口后端：${release.serialBackend}',
    '- 代码签名：${release.codeSigning}',
    '- 硬件验收：${release.hardwareValidation}',
    '- 真实 ISP 启用：${release.ispRealHardwareEnabled ? '是' : '否'}',
    if (release.ispNote.isNotEmpty) '- ISP 状态：${release.ispNote}',
    '- 发布清单：${release.manifestLoaded ? '已读取' : '不可用，使用开发回退'}',
    '',
    '## 系统环境',
    '- 操作系统：$operatingSystemVersion',
    '- 当前后端：${terminal.backendLabel}',
    '- 模拟后端：${terminal.isSimulatedBackend ? '是' : '否'}',
    '',
    '## 连接与串口',
    '- 连接模式：${_transportLabel(terminal.transportMode)}',
    '- 连接状态：${terminal.status.name}',
    '- 串口端口：${terminal.config.portName.isEmpty ? '未选择' : terminal.config.portName}',
    '- 波特率：${terminal.config.baudRate}',
    '- 数据位：${terminal.config.dataBits.value}',
    '- 校验：${terminal.config.parity.name}',
    '- 停止位：${_stopBitsLabel(terminal.config.stopBits)}',
    '- 流控：${terminal.config.flowControl.name}',
    '- 网络安全策略：${terminal.networkSafetyMode.name}',
    '- 监听地址：${terminal.bindAddress}',
    '- 本地端口：${terminal.localPort}',
    '- 远端端口：${terminal.remotePort}',
    '- 已配置远端主机：${terminal.remoteHost.trim().isEmpty ? '否' : '是'}',
    '- 跟随 UDP 远端：${terminal.followRemoteEndpoint ? '是' : '否'}',
    '',
    '## 终端状态',
    '- 显示模式：${terminal.displayMode.name}',
    '- 时间戳：${terminal.showTimestamp ? '开' : '关'}',
    '- 自动滚动：${terminal.autoScroll ? '开' : '关'}',
    '- 接收字节：${terminal.receivedBytes}',
    '- 发送字节：${terminal.sentBytes}',
    '- 丢弃字节：${terminal.droppedBytes}',
    '- 显示行数：${terminal.lines.length}',
    '- 丢弃行数：${terminal.droppedLines}',
    '- 当前错误：${error ?? '无'}',
    '',
    '## 多字符串状态',
    '- 总条目：${multiSend.entries.length}',
    '- 启用且非空：$enabledMultiSend',
    '- 运行中：${multiSend.isRunning ? '是' : '否'}',
    '- 已完成发送：${multiSend.completedSends}',
    '- 已完成循环：${multiSend.completedCycles}',
    '',
    '## 隐私说明',
    '- 未包含串口原始收发数据。',
    '- 未包含文本/HEX 发送草稿。',
    '- 未包含多字符串名称或内容。',
    '- 未包含固件内容或固件路径。',
    '- 未包含远端主机明文。',
    '- 提交前仍应由用户检查报告内容。',
    '',
  ].join('\n');
}

const String _remoteHostPlaceholder = '<remote-host>';
const String _localPathPlaceholder = '<local-path>';
const int _maxSanitizedErrorLength = 800;
const String _absolutePathPrefixPattern =
    r'(?:[A-Za-z]:[\\/]|\\\\[^\\/\s]+[\\/][^\\/\s]+|//[^/\s]+/[^/\s]+|%[A-Za-z_][A-Za-z0-9_()]*%[\\/])';

String? _sanitizeError(String? message, String remoteHost) {
  if (message == null || message.trim().isEmpty) {
    return null;
  }
  var sanitized = message
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  sanitized = _sanitizeAbsolutePaths(sanitized);
  final host = remoteHost.trim();
  if (host.isNotEmpty) {
    sanitized = sanitized.replaceAll(
      RegExp(RegExp.escape(host), caseSensitive: false),
      _remoteHostPlaceholder,
    );
  }
  sanitized = sanitized.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (sanitized.length > _maxSanitizedErrorLength) {
    sanitized = '${sanitized.substring(0, _maxSanitizedErrorLength)}…';
  }
  return sanitized;
}

/// 移除 Windows 绝对路径、UNC 路径和环境变量根路径。
///
/// 引号内路径可以可靠确定边界；未引用路径本身允许包含空格，无法与后续
/// 普通文本无歧义切分，因此从路径起点保守截断，优先避免隐私泄露。
String _sanitizeAbsolutePaths(String value) {
  final quotedPath = RegExp(
    '"[^"]*$_absolutePathPrefixPattern[^"]*"'
    "|'[^']*$_absolutePathPrefixPattern[^']*'",
    caseSensitive: false,
  );
  final withoutQuotedPaths = value.replaceAll(
    quotedPath,
    _localPathPlaceholder,
  );
  final pathStart = RegExp(
    _absolutePathPrefixPattern,
    caseSensitive: false,
  ).firstMatch(withoutQuotedPaths);
  if (pathStart == null) {
    return withoutQuotedPaths;
  }
  return '${withoutQuotedPaths.substring(0, pathStart.start)}$_localPathPlaceholder';
}

String _stopBitsLabel(SerialStopBits stopBits) {
  return switch (stopBits) {
    SerialStopBits.one => '1',
    SerialStopBits.onePointFive => '1.5',
    SerialStopBits.two => '2',
  };
}

String _transportLabel(TransportMode mode) {
  return switch (mode) {
    TransportMode.serial => '串口',
    TransportMode.tcpClient => 'TCP 客户端',
    TransportMode.tcpServer => 'TCP 服务端',
    TransportMode.udp => 'UDP',
  };
}
