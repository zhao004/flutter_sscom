import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/app/theme/sscom_theme.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:signals/signals_flutter.dart';

/// 带虚拟化行列表的接收终端。
class TerminalPanel extends StatefulWidget {
  /// 创建接收终端面板。
  const TerminalPanel({
    super.key,
    required this.controller,
    this.pickExportFile = pickTerminalExportFileDefault,
  });

  /// 工作区控制器。
  final TerminalController controller;

  /// 导出路径选择器，可取消，测试中替换以避免打开系统文件对话框。
  final Future<File?> Function() pickExportFile;

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  bool _showReceiveCount = true;
  TerminalController get controller => widget.controller;

  Future<void> _export() async {
    final content = _snapshot();
    if (content.isEmpty) return;
    try {
      final file = await widget.pickExportFile();
      if (file == null || !mounted) return;
      await file.writeAsString(content);
      if (mounted) controller.showNotice('接收内容已导出');
    } catch (error) {
      if (mounted) controller.showNotice('导出接收内容失败：$error');
    }
  }

  String _snapshot() {
    final state = controller.state.value;
    return state.lines
        .map(
          (line) =>
              '${state.showTimestamp ? '${_formatTimestamp(line.timestamp)}  ' : ''}${line.text}',
        )
        .join('\n');
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _snapshot()));
      if (mounted) controller.showNotice('接收内容已复制');
    } catch (error) {
      if (mounted) controller.showNotice('复制接收内容失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = controller.state.value;
        return WorkspaceSurface(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final controls = Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        WorkspaceSegments<TerminalDisplayMode>(
                          segments: const [
                            ButtonSegment(
                              value: TerminalDisplayMode.text,
                              icon: Icon(Icons.title_rounded, size: 19),
                              label: Text('文本'),
                            ),
                            ButtonSegment(
                              value: TerminalDisplayMode.hex,
                              icon: Icon(Icons.grid_view_rounded, size: 17),
                              label: Text('HEX'),
                            ),
                          ],
                          selected: state.displayMode,
                          onChanged: controller.setDisplayMode,
                        ),
                        WorkspaceCheck(
                          label: '时间戳',
                          value: state.showTimestamp,
                          onChanged: controller.setShowTimestamp,
                        ),
                        WorkspaceCheck(
                          label: '自动滚动',
                          value: state.autoScroll,
                          onChanged: controller.setAutoScroll,
                        ),
                        if (constraints.maxWidth > 1000)
                          WorkspaceCheck(
                            label: '显示接收数量',
                            value: _showReceiveCount,
                            onChanged: (value) =>
                                setState(() => _showReceiveCount = value),
                          ),
                      ],
                    );
                    return Row(
                      children: [
                        Expanded(child: controls),
                        if (state.droppedLines > 0)
                          Text(
                            '已裁剪 ${state.droppedLines} 行',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        TextButton.icon(
                          onPressed: controller.clearTerminal,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('清空'),
                        ),
                        if (constraints.maxWidth > 850)
                          TextButton.icon(
                            onPressed: state.lines.isEmpty
                                ? null
                                : () => unawaited(_export()),
                            icon: const Icon(Icons.ios_share_rounded, size: 18),
                            label: const Text('导出'),
                          ),
                        PopupMenuButton<String>(
                          tooltip: '接收选项',
                          icon: const Icon(Icons.tune_rounded, size: 20),
                          onSelected: (value) {
                            if (value == 'copy') unawaited(_copy());
                            if (value == 'export') unawaited(_export());
                            if (value == 'count') {
                              setState(
                                () => _showReceiveCount = !_showReceiveCount,
                              );
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'copy',
                              enabled: state.lines.isNotEmpty,
                              child: const Text('复制接收内容'),
                            ),
                            PopupMenuItem(
                              value: 'export',
                              enabled: state.lines.isNotEmpty,
                              child: const Text('导出接收内容'),
                            ),
                            CheckedPopupMenuItem(
                              value: 'count',
                              checked: _showReceiveCount,
                              child: const Text('显示接收数量'),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (state.noticeMessage != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  padding: const EdgeInsets.only(left: 10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          state.noticeMessage!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭提示',
                        onPressed: controller.dismissNotice,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              if (state.errorMessage != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    state.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7FAFF),
                    border: Border.all(color: SscomTheme.border),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _TerminalListView(
                          lines: state.lines,
                          showTimestamp: state.showTimestamp,
                          autoScroll: state.autoScroll,
                        ),
                      ),
                      if (_showReceiveCount && state.receivedBytes > 0)
                        Positioned(
                          right: 12,
                          bottom: 8,
                          child: Text(
                            '${state.receivedBytes} B 已接收',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
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

class _TerminalListView extends StatefulWidget {
  const _TerminalListView({
    required this.lines,
    required this.showTimestamp,
    required this.autoScroll,
  });

  final List<TerminalLine> lines;
  final bool showTimestamp;
  final bool autoScroll;

  @override
  State<_TerminalListView> createState() => _TerminalListViewState();
}

class _TerminalListViewState extends State<_TerminalListView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _TerminalListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoScroll &&
        (!identical(oldWidget.lines, widget.lines) ||
            oldWidget.showTimestamp != widget.showTimestamp)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (constraints.maxHeight >= 75)
                Icon(
                  Icons.inbox_rounded,
                  size: constraints.maxHeight < 150 ? 42 : 88,
                  color: const Color(0xFFCFDCF0),
                ),
              if (constraints.maxHeight >= 75) const SizedBox(height: 8),
              Text(
                '等待接收数据',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: SscomTheme.muted),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      itemCount: widget.lines.length,
      itemBuilder: (context, index) {
        final line = widget.lines[index];
        final timestamp = widget.showTimestamp
            ? '${_formatTimestamp(line.timestamp)}  '
            : '';
        return SelectableText(
          '$timestamp${line.text}',
          style: const TextStyle(
            fontFamily: 'Consolas',
            fontFamilyFallback: <String>['monospace'],
            fontSize: 13,
            height: 1.35,
          ),
        );
      },
    );
  }
}

String _formatTimestamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  return '[${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
      '${three(value.millisecond)}]';
}

/// 通过系统保存对话框选择接收快照路径，取消时不写入文件。
Future<File?> pickTerminalExportFileDefault() async {
  final location = await getSaveLocation(
    suggestedName: 'sscom-receive.txt',
    confirmButtonText: '导出',
  );
  return location == null ? null : File(location.path);
}
