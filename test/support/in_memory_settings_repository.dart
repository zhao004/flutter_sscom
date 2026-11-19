import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/settings/infrastructure/json_settings_repository.dart';

/// 内存设置仓库，供设置和组合根测试使用。
final class InMemorySettingsRepository implements SettingsRepository {
  /// 创建内存仓库。
  InMemorySettingsRepository({this.settings});

  /// 当前保存的设置。
  AppSettings? settings;

  /// 读取次数。
  int loadCount = 0;

  /// 保存次数。
  int saveCount = 0;

  /// 非空时模拟保存失败。
  Object? saveError;

  @override
  Future<AppSettings?> load() async {
    loadCount++;
    return settings;
  }

  @override
  Future<void> save(AppSettings settings) async {
    saveCount++;
    final error = saveError;
    if (error != null) {
      throw error;
    }
    this.settings = settings;
  }
}
