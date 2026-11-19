/// SSCOM 发布构建信息。
final class AppReleaseInfo {
  /// 创建发布信息。
  const AppReleaseInfo({
    required this.product,
    required this.version,
    required this.buildNumber,
    required this.displayVersion,
    required this.channel,
    required this.serialBackend,
    required this.codeSigning,
    required this.hardwareValidation,
    required this.ispRealHardwareEnabled,
    required this.ispNote,
    required this.manifestLoaded,
  });

  /// 开发环境或发布清单不可用时的安全回退。
  factory AppReleaseInfo.development() {
    return const AppReleaseInfo(
      product: 'SSCOM',
      version: 'dev',
      buildNumber: '0',
      displayVersion: '开发构建',
      channel: 'development',
      serialBackend: 'compile-time default',
      codeSigning: 'unsigned-development',
      hardwareValidation: 'pending',
      ispRealHardwareEnabled: false,
      ispNote: '真实硬件状态未知；请查看当前构建说明。',
      manifestLoaded: false,
    );
  }

  /// 从发布清单 JSON 创建信息。
  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    final version = _readString(json['version'], 'unknown');
    final buildNumber = _readString(json['buildNumber'], '0');
    return AppReleaseInfo(
      product: _readString(json['product'], 'SSCOM'),
      version: version,
      buildNumber: buildNumber,
      displayVersion: _readString(
        json['displayVersion'],
        '$version+$buildNumber',
      ),
      channel: _readString(json['channel'], 'unknown'),
      serialBackend: _readString(json['serialBackend'], 'unknown'),
      codeSigning: _readString(json['codeSigning'], 'unknown'),
      hardwareValidation: _readString(json['hardwareValidation'], 'pending'),
      ispRealHardwareEnabled:
          json['ispRealHardwareEnabled'] is bool &&
          json['ispRealHardwareEnabled'] as bool,
      ispNote: _readString(json['ispNote'], ''),
      manifestLoaded: true,
    );
  }

  /// 产品名。
  final String product;

  /// 语义版本。
  final String version;

  /// 构建号。
  final String buildNumber;

  /// 面向用户显示的完整版本。
  final String displayVersion;

  /// 发布渠道。
  final String channel;

  /// 构建时选择的串口后端。
  final String serialBackend;

  /// 代码签名状态。
  final String codeSigning;

  /// 硬件验收状态。
  final String hardwareValidation;

  /// 是否启用真实硬件 ISP。
  final bool ispRealHardwareEnabled;

  /// ISP 状态说明。
  final String ispNote;

  /// 是否成功读取发布清单。
  final bool manifestLoaded;
}

String _readString(Object? value, String fallback) {
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  if (value is num) {
    return value.toString();
  }
  return fallback;
}
