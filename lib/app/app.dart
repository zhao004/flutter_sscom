import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme/sscom_theme.dart';

/// 应用启动所需的组合依赖。
///
/// 该对象由组合根创建后显式传给 [App]，避免 Widget 直接访问全局服务容器。
final class AppDependencies {
  /// 创建一个不可变的应用依赖集合。
  const AppDependencies({required this.router, required this.shutdown});

  /// 当前应用生命周期内唯一的 GoRouter 实例。
  final GoRouter router;

  /// 关闭串口、计时器和事件订阅的幂等回调。
  final Future<void> Function() shutdown;
}

/// SSCOM 的应用根组件。
class App extends StatefulWidget {
  /// 使用组合根准备好的依赖构建应用。
  const App({super.key, required this.dependencies});

  /// 启动阶段生成的依赖集合。
  final AppDependencies dependencies;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await widget.dependencies.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    // 正常退出由 onExitRequested 等待 shutdown；组件卸载时可能仍有
    // SignalBuilder 订阅，不能在这里并发销毁控制器状态。测试和嵌入场景
    // 需要显式调用 AppDependencies.shutdown() 后再重置组合容器。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SSCOM',
      debugShowCheckedModeBanner: false,
      routerConfig: widget.dependencies.router,
      theme: SscomTheme.light(),
    );
  }
}
