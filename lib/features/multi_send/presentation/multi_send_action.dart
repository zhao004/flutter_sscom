import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/features/file_transfer/application/file_send_controller.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:signals/signals_flutter.dart';

/// 多字符串编辑和启停入口。
class MultiSendAction extends StatelessWidget {
  /// 创建多字符串入口。
  const MultiSendAction({
    super.key,
    required this.controller,
    required this.fileSendController,
  });

  /// 多字符串控制器。
  final MultiSendController controller;

  /// 文件发送状态，用于阻止自动发送和文件发送交错。
  final FileSendController fileSendController;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = controller.state.value;
        final exclusive = controller.terminal.state.value.isExclusiveSend;
        return TextButton.icon(
          onPressed: state.isRunning
              ? () => unawaited(controller.stop())
              : exclusive
              ? null
              : () => _showEditor(context),
          icon: Icon(
            state.isRunning ? Icons.stop_circle_outlined : Icons.repeat,
            size: 18,
          ),
          label: Text(state.isRunning ? '停止多发送' : '多字符串'),
        );
      },
    );
  }

  Future<void> _showEditor(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => MultiSendDialog(
        controller: controller,
        fileSendController: fileSendController,
      ),
    );
  }
}

/// 多字符串条目编辑对话框。
class MultiSendDialog extends StatefulWidget {
  /// 创建编辑对话框。
  const MultiSendDialog({
    super.key,
    required this.controller,
    required this.fileSendController,
  });

  /// 多字符串控制器。
  final MultiSendController controller;

  /// 文件发送状态。
  final FileSendController fileSendController;

  @override
  State<MultiSendDialog> createState() => _MultiSendDialogState();
}

class _MultiSendDialogState extends State<MultiSendDialog> {
  late final List<_DraftEntry> _drafts;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _drafts = widget.controller.state.value.entries
        .where(
          (entry) =>
              entry.enabled ||
              entry.name.isNotEmpty ||
              entry.payload.isNotEmpty,
        )
        .map(_DraftEntry.new)
        .toList();
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  void _addDraft() {
    if (_drafts.length >= maxMultiSendEntries) {
      setState(() => _errorMessage = '最多支持 $maxMultiSendEntries 条多字符串');
      return;
    }
    final used = <int>{for (final draft in _drafts) draft.index};
    var nextIndex = 1;
    while (used.contains(nextIndex)) {
      nextIndex++;
    }
    setState(() {
      _drafts.add(
        _DraftEntry(
          MultiSendEntry(
            index: nextIndex,
            mode: SendInputMode.ansiText,
            payload: '',
            enabled: true,
            name: '',
            intervalMs: 1000,
          ),
        ),
      );
      _errorMessage = null;
    });
  }

  void _removeDraft(_DraftEntry draft) {
    setState(() {
      _drafts.remove(draft);
      draft.dispose();
    });
  }

  void _moveDraft(_DraftEntry draft, int delta) {
    final position = _drafts.indexOf(draft);
    final target = position + delta;
    if (position < 0 || target < 0 || target >= _drafts.length) {
      return;
    }
    setState(() {
      _drafts.removeAt(position);
      _drafts.insert(target, draft);
    });
  }

  void _save({required bool start}) {
    final entries = <MultiSendEntry>[];
    for (final draft in _drafts) {
      final interval = int.tryParse(draft.intervalController.text.trim());
      if (interval == null ||
          interval < minMultiSendIntervalMs ||
          interval > maxMultiSendIntervalMs) {
        setState(() {
          _errorMessage =
              '条目 ${draft.index} 的间隔必须为 '
              '$minMultiSendIntervalMs 到 $maxMultiSendIntervalMs ms';
        });
        return;
      }
      entries.add(draft.toEntry(interval));
    }
    try {
      if (!widget.controller.replaceEntries(entries)) {
        setState(
          () => _errorMessage = widget.controller.state.value.errorMessage,
        );
        return;
      }
    } on ArgumentError catch (error) {
      setState(() => _errorMessage = error.message?.toString() ?? '$error');
      return;
    }
    if (start) {
      if (widget.fileSendController.state.value.isRunning) {
        setState(() => _errorMessage = '文件发送进行中，不能启动多字符串发送');
        return;
      }
      if (widget.controller.terminal.state.value.isExclusiveSend) {
        setState(() => _errorMessage = 'ISP 独占串口期间不能启动多字符串发送');
        return;
      }
      widget.controller.start();
      final state = widget.controller.state.value;
      if (!state.isRunning && state.errorMessage != null) {
        setState(() => _errorMessage = state.errorMessage);
        return;
      }
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 600),
        child: SizedBox(
          width: 820,
          height: 600,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '多字符串发送',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    Text(
                      '顺序执行 · 每项间隔后循环',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '按列表顺序发送启用且内容非空的条目。取消或关闭时不会自动启动。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_errorMessage != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _addDraft,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加条目'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => _save(start: false),
                      child: const Text('保存'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _save(start: true),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('保存并启动'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _drafts.isEmpty
                      ? Center(
                          child: Text(
                            '还没有多字符串条目',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        )
                      : ListView.separated(
                          itemCount: _drafts.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final draft = _drafts[index];
                            return _DraftEntryEditor(
                              key: ValueKey<int>(draft.index),
                              draft: draft,
                              canMoveUp: index > 0,
                              canMoveDown: index < _drafts.length - 1,
                              onChanged: () =>
                                  setState(() => _errorMessage = null),
                              onRemove: () => _removeDraft(draft),
                              onMoveUp: () => _moveDraft(draft, -1),
                              onMoveDown: () => _moveDraft(draft, 1),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DraftEntry {
  _DraftEntry(MultiSendEntry entry)
    : index = entry.index,
      enabled = entry.enabled,
      mode = entry.mode,
      nameController = TextEditingController(text: entry.name),
      payloadController = TextEditingController(text: entry.payload),
      intervalController = TextEditingController(
        text: entry.intervalMs.toString(),
      );

  final int index;
  bool enabled;
  SendInputMode mode;
  final TextEditingController nameController;
  final TextEditingController payloadController;
  final TextEditingController intervalController;

  MultiSendEntry toEntry(int intervalMs) {
    return MultiSendEntry(
      index: index,
      mode: mode,
      payload: payloadController.text,
      enabled: enabled,
      name: nameController.text.trim(),
      intervalMs: intervalMs,
    );
  }

  void dispose() {
    nameController.dispose();
    payloadController.dispose();
    intervalController.dispose();
  }
}

class _DraftEntryEditor extends StatelessWidget {
  const _DraftEntryEditor({
    super.key,
    required this.draft,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final _DraftEntry draft;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Checkbox(
                  value: draft.enabled,
                  onChanged: (value) {
                    draft.enabled = value ?? false;
                    onChanged();
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: draft.nameController,
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(
                      labelText: '名称（可选）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<SendInputMode>(
                    initialValue: draft.mode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '模式',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const <DropdownMenuItem<SendInputMode>>[
                      DropdownMenuItem(
                        value: SendInputMode.ansiText,
                        child: Text('文本'),
                      ),
                      DropdownMenuItem(
                        value: SendInputMode.hex,
                        child: Text('HEX'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        draft.mode = value;
                        onChanged();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 105,
                  child: TextField(
                    controller: draft.intervalController,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    onChanged: (_) => onChanged(),
                    decoration: const InputDecoration(
                      labelText: '间隔 ms',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '上移',
                  onPressed: canMoveUp ? onMoveUp : null,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: '下移',
                  onPressed: canMoveDown ? onMoveDown : null,
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: draft.payloadController,
              onChanged: (_) => onChanged(),
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontFamily: 'Consolas'),
              decoration: InputDecoration(
                labelText: draft.mode == SendInputMode.ansiText
                    ? '发送文本（支持 \\r \\n \\xHH）'
                    : 'HEX 内容（例如 01 03 00 00）',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
