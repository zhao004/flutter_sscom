import 'package:flutter/material.dart';

import '../../theme/sscom_theme.dart';

import 'package:go_router/go_router.dart';
import 'package:flutter_sscom/features/connection/presentation/connection_toolbar.dart';
import 'package:flutter_sscom/features/file_transfer/application/file_send_controller.dart';
import 'package:flutter_sscom/features/file_transfer/application/receive_log_controller.dart';
import 'package:flutter_sscom/features/file_transfer/presentation/file_transfer_bar.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/multi_send/presentation/multi_send_action.dart';
import 'package:flutter_sscom/features/send/presentation/send_panel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/presentation/terminal_panel.dart';
import 'package:signals/signals_flutter.dart';

import '../../router/app_routes.dart';

/// SSCOM 的 Windows 串口与网络调试工作区。
class HomeView extends StatelessWidget {
  /// 创建调试工作区。
  const HomeView({
    super.key,
    required this.controller,
    required this.fileSendController,
    required this.receiveLogController,
    required this.multiSendController,
    this.pickSendFile = pickSendFileDefault,
    this.pickReceiveFile = pickReceiveFileDefault,
    this.onOpenSettingsMigration,
    this.onOpenSupport,
  });

  /// 页面依赖的长期工作区控制器。
  final TerminalController controller;

  /// 文件发送控制器。
  final FileSendController fileSendController;

  /// 接收落盘控制器。
  final ReceiveLogController receiveLogController;

  /// 多字符串自动发送控制器。
  final MultiSendController multiSendController;

  /// 测试可替换的发送文件选择器。
  final FileSelectionCallback pickSendFile;

  /// 测试可替换的接收日志选择器。
  final FileSelectionCallback pickReceiveFile;

  /// 打开配置迁移向导；持久化不可用时为 `null`。
  final VoidCallback? onOpenSettingsMigration;

  /// 打开诊断与反馈页面。
  final VoidCallback? onOpenSupport;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height < 700;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _WorkspaceHeader(onHelp: onOpenSupport),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WorkspaceNavigation(
                    onMultiSend: () => showDialog<void>(
                      context: context,
                      builder: (_) => MultiSendDialog(
                        controller: multiSendController,
                        fileSendController: fileSendController,
                      ),
                    ),
                    onWaveform: () => context.push(AppRoutes.waveform),
                    onIsp: () => context.push(AppRoutes.isp),
                    onSettings:
                        onOpenSettingsMigration ?? () => _showSettings(context),
                    settingsTooltip: onOpenSettingsMigration == null
                        ? '设置中心'
                        : '配置迁移',
                    onSupport: onOpenSupport,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 12, 10),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // 面板不足时滚动内容区，避免连接详情和异常提示挤掉终端；状态栏始终固定。
                          final workspace = Column(
                            children: [
                              ConnectionToolbar(controller: controller),
                              const SizedBox(height: 10),
                              Expanded(
                                child: TerminalPanel(controller: controller),
                              ),
                              const SizedBox(height: 10),
                              WorkspaceSurface(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  children: [
                                    SizedBox(
                                      height: compact ? 100 : 155,
                                      child: SendPanel(
                                        controller: controller,
                                        fileSendController: fileSendController,
                                        multiSendController:
                                            multiSendController,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    FileTransferBar(
                                      fileSendController: fileSendController,
                                      receiveLogController:
                                          receiveLogController,
                                      multiSendController: multiSendController,
                                      pickSendFile: pickSendFile,
                                      pickReceiveFile: pickReceiveFile,
                                      trailing: MultiSendAction(
                                        controller: multiSendController,
                                        fileSendController: fileSendController,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                          return Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, contentConstraints) {
                                    return SignalBuilder(
                                      builder: (context) {
                                        final state = controller.state.value;
                                        final minimumHeight =
                                            (state.isNetworkMode
                                                ? SscomTheme
                                                      .networkWorkspaceMinHeight
                                                : SscomTheme
                                                      .serialWorkspaceMinHeight) +
                                            (state.noticeMessage == null
                                                ? 0
                                                : SscomTheme
                                                      .messageHeightAllowance) +
                                            (state.errorMessage == null
                                                ? 0
                                                : SscomTheme
                                                      .messageHeightAllowance);
                                        return SingleChildScrollView(
                                          child: SizedBox(
                                            height:
                                                contentConstraints.maxHeight <
                                                    minimumHeight
                                                ? minimumHeight
                                                : contentConstraints.maxHeight,
                                            child: workspace,
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 10),
                              _StatusBar(
                                controller: controller,
                                multiSendController: multiSendController,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置中心'),
        content: const Text('串口与网络参数可在连接区域调整；显示和发送偏好会随工作区保存。当前会话未启用旧版配置迁移。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({this.onHelp});
  final VoidCallback? onHelp;

  @override
  Widget build(BuildContext context) => Container(
    height: MediaQuery.sizeOf(context).height < 700 ? 64 : 80,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 26),
    decoration: const BoxDecoration(
      color: SscomTheme.surface,
      border: Border(bottom: BorderSide(color: SscomTheme.border)),
    ),
    child: Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFA7D2F3), Color(0xFF508FDC)],
            ),
            borderRadius: BorderRadius.circular(13),
            boxShadow: const [
              BoxShadow(
                color: Color(0x195291D8),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 37),
        ),
        const SizedBox(width: 16),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'SSCOM',
                  style: TextStyle(
                    fontFamily: 'Segoe UI',
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF101E3C),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE4EFFF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'v1.0.0',
                    style: TextStyle(
                      fontSize: 11,
                      color: SscomTheme.blue,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              '串口 / 网络调试工具',
              style: TextStyle(fontSize: 12, color: Color(0xFF536586)),
            ),
          ],
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: onHelp,
          icon: const Icon(Icons.help_outline_rounded, size: 19),
          label: const Text('帮助'),
        ),
      ],
    ),
  );
}

class _WorkspaceNavigation extends StatelessWidget {
  const _WorkspaceNavigation({
    required this.onMultiSend,
    required this.onWaveform,
    required this.onIsp,
    required this.onSettings,
    required this.settingsTooltip,
    this.onSupport,
  });
  final VoidCallback onMultiSend;
  final VoidCallback onWaveform;
  final VoidCallback onIsp;
  final VoidCallback onSettings;
  final String settingsTooltip;
  final VoidCallback? onSupport;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: MediaQuery.sizeOf(context).width < 1000 ? 70 : 78,
    child: Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                _NavigationItem(
                  label: '通信调试',
                  icon: Icons.home_outlined,
                  selected: true,
                  onTap: () {},
                ),
                _NavigationItem(
                  label: '发送脚本',
                  icon: Icons.near_me_outlined,
                  onTap: onMultiSend,
                ),
                _NavigationItem(
                  label: '数据分析',
                  tooltip: '波形',
                  icon: Icons.bar_chart_rounded,
                  onTap: onWaveform,
                ),
                _NavigationItem(
                  label: '工具箱',
                  tooltip: 'ISP',
                  icon: Icons.inventory_2_outlined,
                  onTap: onIsp,
                ),
                _NavigationItem(
                  label: '设置中心',
                  tooltip: settingsTooltip,
                  icon: Icons.settings_outlined,
                  onTap: onSettings,
                ),
                _NavigationItem(
                  label: '关于',
                  tooltip: '诊断与反馈',
                  icon: Icons.info_outline_rounded,
                  onTap: onSupport,
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Icon(
            Icons.terminal_rounded,
            size: 30,
            color: Color(0xFFBFDAFA),
          ),
        ),
      ],
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.tooltip,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? label,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 4, 4),
      child: Material(
        color: selected ? const Color(0xFF6AA8E4) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 54,
            width: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: selected ? Colors.white : SscomTheme.ink,
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : SscomTheme.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.controller,
    required this.multiSendController,
  });

  final TerminalController controller;
  final MultiSendController multiSendController;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = controller.state.value;
        final multiState = multiSendController.state.value;
        return Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.memory_outlined,
                size: 17,
                color: SscomTheme.ink,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  state.backendLabel,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (multiState.isRunning) ...<Widget>[
                Text(
                  '多发送 ${multiState.currentEntryIndex ?? '-'} '
                  '· ${multiState.completedSends} 次   ',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              ],
              Text(
                'RX: ${state.receivedBytes} B     '
                'TX: ${state.sentBytes} B     '
                '丢弃: ${state.droppedBytes} B',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
