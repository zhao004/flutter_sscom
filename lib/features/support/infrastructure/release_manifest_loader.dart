import 'dart:convert';
import 'dart:io';

import '../domain/app_release_info.dart';

/// 发布清单加载回调。
typedef AppReleaseInfoLoader = Future<AppReleaseInfo> Function();

/// 从当前可执行文件目录读取 `release-manifest.json`。
///
/// 开发构建、便携运行或清单损坏时返回安全回退信息，不因诊断功能失败而
/// 阻止应用启动或页面打开。
Future<AppReleaseInfo> loadAppReleaseInfo() async {
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final manifest = File(
    '${executableDirectory.path}${Platform.pathSeparator}release-manifest.json',
  );
  return loadAppReleaseInfoFromFile(manifest);
}

/// 从显式文件读取发布清单；测试可注入临时清单。
Future<AppReleaseInfo> loadAppReleaseInfoFromFile(File manifest) async {
  if (!await manifest.exists()) {
    return AppReleaseInfo.development();
  }
  try {
    final text = await manifest.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      return AppReleaseInfo.development();
    }
    return AppReleaseInfo.fromJson(decoded);
  } catch (_) {
    return AppReleaseInfo.development();
  }
}
