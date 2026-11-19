import 'package:go_router/go_router.dart';

import '../../features/file_transfer/application/file_send_controller.dart';
import '../../features/file_transfer/application/receive_log_controller.dart';
import '../../features/isp/application/isp_controller.dart';
import '../../features/isp/presentation/isp_page.dart';
import '../../features/multi_send/application/multi_send_controller.dart';
import '../../features/settings/application/settings_migration_controller.dart';
import '../../features/settings/presentation/settings_migration_page.dart';
import '../../features/support/infrastructure/release_manifest_loader.dart';
import '../../features/support/presentation/support_page.dart';
import '../../features/terminal/application/terminal_controller.dart';
import '../../features/waveform/application/waveform_controller.dart';
import '../../features/waveform/presentation/waveform_page.dart';
import '../pages/home/home_view.dart';
import 'app_routes.dart';

/// 创建应用路由实例。
///
/// 路由不保存在可变静态字段中，便于测试和多窗口场景分别管理生命周期。
GoRouter createAppRouter({
  required TerminalController controller,
  required FileSendController fileSendController,
  required ReceiveLogController receiveLogController,
  required MultiSendController multiSendController,
  required WaveformController waveformController,
  required IspController ispController,
  SettingsMigrationController? settingsMigrationController,
  IspFirmwareSelectionCallback pickIspFirmware = pickIspFirmwareDefault,
  LegacyIniSelectionCallback pickLegacyIni = pickLegacyIniDefault,
  AppReleaseInfoLoader supportReleaseInfoLoader = loadAppReleaseInfo,
}) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.home,
        name: 'home',
        builder: (context, state) => HomeView(
          controller: controller,
          fileSendController: fileSendController,
          receiveLogController: receiveLogController,
          multiSendController: multiSendController,
          onOpenSettingsMigration: settingsMigrationController == null
              ? null
              : () => context.push(AppRoutes.settingsMigration),
          onOpenSupport: () => context.push(AppRoutes.support),
        ),
      ),
      GoRoute(
        path: AppRoutes.waveform,
        name: 'waveform',
        builder: (context, state) =>
            WaveformPage(controller: waveformController),
      ),
      GoRoute(
        path: AppRoutes.isp,
        name: 'isp',
        builder: (context, state) =>
            IspPage(controller: ispController, pickFirmware: pickIspFirmware),
      ),
      if (settingsMigrationController != null)
        GoRoute(
          path: AppRoutes.settingsMigration,
          name: 'settingsMigration',
          builder: (context, state) => SettingsMigrationPage(
            controller: settingsMigrationController,
            pickLegacyIni: pickLegacyIni,
          ),
        ),
      GoRoute(
        path: AppRoutes.support,
        name: 'support',
        builder: (context, state) => SupportPage(
          terminal: controller,
          multiSendController: multiSendController,
          releaseInfoLoader: supportReleaseInfoLoader,
        ),
      ),
    ],
  );
}
