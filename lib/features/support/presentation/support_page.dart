import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/support/application/support_report_builder.dart';
import 'package:flutter_sscom/features/support/domain/app_release_info.dart';
import 'package:flutter_sscom/features/support/infrastructure/release_manifest_loader.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:signals/signals_flutter.dart';

/// 诊断报告保存路径选择回调。
typedef SupportReportFilePicker = Future<File?> Function();

/// 剪贴板写入回调。
typedef SupportClipboardWriter = Future<void> Function(String text);

/// 默认诊断报告保存路径选择器。
Future<File?> pickSupportReportFileDefault() async {
  final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final location = await getSaveLocation(
    suggestedName: 'SSCOM-diagnostics-$timestamp.md',
    confirmButtonText: '导出诊断报告',
  );
  return location == null ? null : File(location.path);
}

Future<void> _writeClipboardDefault(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}

/// 发布支持、诊断与反馈页面。
class SupportPage extends StatefulWidget {
  /// 创建诊断与反馈页面。
  const SupportPage({
    super.key,
    required this.terminal,
    required this.multiSendController,
    this.releaseInfoLoader = loadAppReleaseInfo,
    this.reportFilePicker = pickSupportReportFileDefault,
    this.clipboardWriter = _writeClipboardDefault,
    this.operatingSystemVersionProvider,
    this.now,
  });

  /// 终端控制器。
  final TerminalController terminal;

  /// 多字符串控制器。
  final MultiSendController multiSendController;

  /// 发布清单加载器。
  final AppReleaseInfoLoader releaseInfoLoader;

  /// 诊断报告保存路径选择器。
  final SupportReportFilePicker reportFilePicker;

  /// 剪贴板写入器。
  final SupportClipboardWriter clipboardWriter;

  /// 操作系统版本提供器。
  final String Function()? operatingSystemVersionProvider;

  /// 报告生成时间提供器。
  final DateTime Function()? now;

  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  late final Future<AppReleaseInfo> _releaseFuture;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _releaseFuture = Future<AppReleaseInfo>.sync(widget.releaseInfoLoader);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('诊断与反馈')),
      body: SafeArea(
        child: FutureBuilder<AppReleaseInfo>(
          future: _releaseFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!snapshot.hasData) {
              return const Center(child: Text('无法读取发布信息'));
            }
            final release = snapshot.data!;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                _ReleaseCard(release: release),
                const SizedBox(height: 10),
                _PrivacyCard(),
                const SizedBox(height: 10),
                _RuntimeCard(
                  terminal: widget.terminal,
                  multiSendController: widget.multiSendController,
                ),
                const SizedBox(height: 10),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '提交反馈',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '先复制或导出脱敏诊断报告，再通过项目发布的 Beta 反馈渠道提交。'
                          '应用不会自动上传报告或遥测。',
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 10,
                          runSpacing: 8,
                          children: <Widget>[
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(_copyReport(release)),
                              icon: const Icon(Icons.copy_outlined),
                              label: const Text('复制诊断信息'),
                            ),
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => unawaited(_exportReport(release)),
                              icon: const Icon(Icons.save_alt_outlined),
                              label: const Text('导出诊断报告'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _copyReport(AppReleaseInfo release) async {
    await _runAction(() async {
      await widget.clipboardWriter(_buildReport(release));
      _showMessage('诊断信息已复制到剪贴板');
    });
  }

  Future<void> _exportReport(AppReleaseInfo release) async {
    late final File target;
    try {
      final selected = await widget.reportFilePicker();
      if (selected == null) {
        return;
      }
      target = selected;
    } catch (error) {
      _showMessage('选择诊断报告路径失败：$error', isError: true);
      return;
    }
    await _runAction(() async {
      await target.writeAsString(_buildReport(release), flush: true);
      _showMessage('诊断报告已导出：${target.path}');
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _showMessage('诊断操作失败：$error', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _buildReport(AppReleaseInfo release) {
    return buildSupportReport(
      release: release,
      terminal: widget.terminal.state.value,
      multiSend: widget.multiSendController.state.value,
      generatedAt: widget.now?.call() ?? DateTime.now(),
      operatingSystemVersion:
          widget.operatingSystemVersionProvider?.call() ??
          Platform.operatingSystemVersion,
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    final colors = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? colors.error : null,
        ),
      );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.release});

  final AppReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('发布信息', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: <Widget>[
                Text('版本：${release.displayVersion}'),
                Text('渠道：${release.channel}'),
                Text('串口后端：${release.serialBackend}'),
                Text('签名：${release.codeSigning}'),
                Text('硬件验收：${release.hardwareValidation}'),
              ],
            ),
            if (!release.manifestLoaded) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '未找到 release-manifest.json，当前使用开发构建回退信息。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
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
          Icon(Icons.privacy_tip_outlined, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '报告只包含发布信息、系统版本、连接参数、计数和脱敏错误。'
              '不会包含串口原始数据、发送草稿、多字符串内容、固件或远端主机明文。'
              '提交前请自行打开报告检查。',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeCard extends StatelessWidget {
  const _RuntimeCard({
    required this.terminal,
    required this.multiSendController,
  });

  final TerminalController terminal;
  final MultiSendController multiSendController;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = terminal.state.value;
        final multiState = multiSendController.state.value;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('当前运行状态', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 20,
                  runSpacing: 8,
                  children: <Widget>[
                    Text('连接：${state.status.name}'),
                    Text('模式：${state.transportMode.name}'),
                    Text('接收：${state.receivedBytes} B'),
                    Text('发送：${state.sentBytes} B'),
                    Text('显示行：${state.lines.length}'),
                    Text('多字符串：${multiState.entries.length} 条'),
                    Text('多发送运行：${multiState.isRunning ? '是' : '否'}'),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
