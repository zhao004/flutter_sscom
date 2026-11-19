import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/settings/application/settings_migration_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:signals/signals_flutter.dart';

/// 旧 INI 文件选择回调。
typedef LegacyIniSelectionCallback = Future<File?> Function();

/// 选择旧版 `sscom51.ini`。
Future<File?> pickLegacyIniDefault() async {
  final file = await openFile(
    confirmButtonText: '选择 sscom51.ini',
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(label: 'SSCOM 配置', extensions: <String>['ini']),
    ],
  );
  return file == null ? null : File(file.path);
}

/// 配置迁移向导页面。
class SettingsMigrationPage extends StatelessWidget {
  /// 创建配置迁移向导。
  const SettingsMigrationPage({
    super.key,
    required this.controller,
    this.pickLegacyIni = pickLegacyIniDefault,
  });

  /// 迁移控制器。
  final SettingsMigrationController controller;

  /// 可替换的旧配置选择器。
  final LegacyIniSelectionCallback pickLegacyIni;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配置迁移向导')),
      body: SafeArea(
        child: SignalBuilder(
          builder: (context) {
            final state = controller.state.value;
            final result = state.result;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                const _MigrationNotice(),
                const SizedBox(height: 10),
                _SourceCard(
                  state: state,
                  onSelect: state.isBusy
                      ? null
                      : () => unawaited(_selectFile()),
                ),
                if (state.isBusy) ...<Widget>[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(),
                ],
                if (result != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _SafetyCard(controller: controller),
                  const SizedBox(height: 10),
                  _PreviewCard(
                    state: state,
                    onApply:
                        state.isBusy ||
                            state.phase == SettingsMigrationPhase.completed ||
                            controller.coordinator.isSuspended
                        ? null
                        : () => unawaited(_confirmAndApply(context, state)),
                  ),
                ],
                if (state.errorMessage != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _MessageCard(text: state.errorMessage!, isError: true),
                ],
                if (state.phase ==
                    SettingsMigrationPhase.completed) ...<Widget>[
                  const SizedBox(height: 10),
                  _CompletedCard(state: state),
                ] else if (state.message != null &&
                    !state.isBusy &&
                    state.errorMessage == null) ...<Widget>[
                  const SizedBox(height: 10),
                  _MessageCard(text: state.message!),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _selectFile() async {
    final file = await pickLegacyIni();
    if (file != null) {
      await controller.inspectFile(file);
    }
  }

  Future<void> _confirmAndApply(
    BuildContext context,
    SettingsMigrationState state,
  ) async {
    final result = state.result;
    if (result == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('确认导入旧配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('源文件：${state.sourceName ?? '-'}'),
              const SizedBox(height: 6),
              Text('串口：${_serialSummary(state)}'),
              Text('连接模式：${_networkLabel(result.settings.network.mode)}'),
              Text(
                '终端显示：${_displayLabel(result.settings.terminal.displayMode)}',
              ),
              Text('多字符串：${result.settings.multiSend.length} 条'),
              Text(
                '迁移警告：${result.warnings.length} 条；'
                '未知键：${result.unknownEntries.length} 个',
              ),
              const SizedBox(height: 10),
              const Text(
                '确认后会先备份原始 INI，再保存新的 settings.json。'
                '当前运行实例不会热应用设置，必须重启 SSCOM；'
                '为防止退出时覆盖迁移结果，当前会话的自动保存会暂停。',
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('备份并保存'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await controller.apply();
    }
  }
}

class _MigrationNotice extends StatelessWidget {
  const _MigrationNotice();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本向导以只读方式解析旧 sscom51.ini，不改写或删除源文件。'
              '保存前必须断开所有串口/网络连接并结束 ISP 会话；'
              '保存成功后需要重启 SSCOM 才能完整应用设置。',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.state, required this.onSelect});

  final SettingsMigrationState state;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('旧配置文件', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: onSelect,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('选择 sscom51.ini'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (state.sourceName == null)
              const Text('请选择旧版 SSCOM 配置文件。')
            else ...<Widget>[
              Text(state.sourceName!),
              const SizedBox(height: 4),
              Text(
                state.sourcePath ?? '',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard({required this.controller});

  final SettingsMigrationController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final terminal = controller.terminal.state.value;
        final safe = controller.isSessionSafe;
        final colors = Theme.of(context).colorScheme;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: safe ? colors.secondaryContainer : colors.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                safe ? Icons.check_circle_outline : Icons.link_off,
                color: safe
                    ? colors.onSecondaryContainer
                    : colors.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  safe
                      ? '当前会话已断开，可以安全保存迁移结果。'
                      : '当前连接或 ISP 会话仍在活动：${_activeReason(terminal)}。'
                            '请先关闭连接并结束 ISP 会话。',
                  style: TextStyle(
                    color: safe
                        ? colors.onSecondaryContainer
                        : colors.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.state, required this.onApply});

  final SettingsMigrationState state;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final result = state.result!;
    final warnings = result.warnings;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('迁移预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: <Widget>[
                Text('串口：${_serialSummary(state)}'),
                Text('连接模式：${_networkLabel(result.settings.network.mode)}'),
                Text(
                  '显示：${_displayLabel(result.settings.terminal.displayMode)}',
                ),
                Text('多字符串：${result.settings.multiSend.length} 条'),
                Text('警告：${warnings.length} 条'),
                Text('未知键：${result.unknownEntries.length} 个'),
                Text('重复键：${result.duplicateKeys.length} 个'),
              ],
            ),
            if (warnings.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('查看 ${warnings.length} 条迁移警告'),
                children: <Widget>[
                  for (final warning in warnings)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${warning.code.id}'
                          '${warning.key == null ? '' : ' · ${warning.key}'}'
                          '：${warning.message}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (result.unknownEntries.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('查看 ${result.unknownEntries.length} 个未导入键'),
                children: <Widget>[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      (result.unknownEntries.keys.toList()..sort()).join(', '),
                    ),
                  ),
                ],
              ),
            ],
            if (result.duplicateKeys.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('重复键采用首次出现的值：${result.duplicateKeys.join(', ')}'),
            ],
            const SizedBox(height: 10),
            Text(
              '缓冲容量、窗口位置、主题和语言等设置会写入 JSON，但需要重启后才能由启动流程读取。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: onApply,
                icon: const Icon(Icons.save_outlined),
                label: const Text('备份并保存迁移设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletedCard extends StatelessWidget {
  const _CompletedCard({required this.state});

  final SettingsMigrationState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('迁移结果已保存', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('请完整退出 SSCOM 并重新启动，以应用新的串口、网络和界面设置。'),
          if (state.backupPath != null) ...<Widget>[
            const SizedBox(height: 8),
            Text('原始文件备份：${state.backupPath}'),
          ],
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isError
              ? colors.onErrorContainer
              : colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

String _serialSummary(SettingsMigrationState state) {
  final serial = state.result!.settings.serial;
  final port = serial.portName.trim().isEmpty ? '未指定端口' : serial.portName;
  return '$port · ${serial.baudRate} baud';
}

String _networkLabel(TransportMode mode) {
  return switch (mode) {
    TransportMode.serial => '串口',
    TransportMode.tcpClient => 'TCP 客户端',
    TransportMode.tcpServer => 'TCP 服务端',
    TransportMode.udp => 'UDP',
  };
}

String _displayLabel(TerminalDisplayMode mode) {
  return switch (mode) {
    TerminalDisplayMode.text => '文本',
    TerminalDisplayMode.hex => 'HEX',
  };
}

String _activeReason(TerminalViewState state) {
  if (state.isExclusiveSend) {
    return 'ISP 独占串口';
  }
  if (state.isSending) {
    return '正在发送数据';
  }
  if (state.isOpening) {
    return '正在打开连接';
  }
  return '连接或监听中';
}
