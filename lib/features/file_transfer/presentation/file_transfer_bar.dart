import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../application/file_send_controller.dart';
import '../application/receive_log_controller.dart';
import '../../multi_send/application/multi_send_controller.dart';

/// 文件选择回调。
typedef FileSelectionCallback = Future<File?> Function();

/// 文件发送和接收落盘的紧凑工具栏。
class FileTransferBar extends StatelessWidget {
  /// 创建文件传输工具栏。
  const FileTransferBar({
    super.key,
    required this.fileSendController,
    required this.receiveLogController,
    required this.multiSendController,
    this.pickSendFile = pickSendFileDefault,
    this.pickReceiveFile = pickReceiveFileDefault,
    this.trailing,
  });

  /// 文件发送控制器。
  final FileSendController fileSendController;

  /// 接收落盘控制器。
  final ReceiveLogController receiveLogController;

  /// 多字符串发送状态，用于避免文件发送与其交错。
  final MultiSendController multiSendController;

  /// 发送文件选择回调，测试可注入替身。
  final FileSelectionCallback pickSendFile;

  /// 接收日志路径选择回调，测试可注入替身。
  final FileSelectionCallback pickReceiveFile;

  /// 同面板中的多字符串入口。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final sendState = fileSendController.state.value;
        final logState = receiveLogController.state.value;
        final terminalState = fileSendController.terminal.state.value;
        final connected = terminalState.isConnected;
        final exclusive = terminalState.isExclusiveSend;
        final multiSending = multiSendController.state.value.isRunning;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
          child: Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed:
                    sendState.isRunning ||
                        multiSending ||
                        !connected ||
                        exclusive
                    ? null
                    : () => unawaited(_selectAndSendFile(context)),
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('发送文件'),
              ),
              if (sendState.phase != FileSendPhase.idle) ...<Widget>[
                const SizedBox(width: 10),
                Expanded(
                  child: _FileSendProgress(
                    state: sendState,
                    onCancel: sendState.isRunning
                        ? () => unawaited(fileSendController.cancel())
                        : null,
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () =>
                    unawaited(_toggleReceiveLog(context, logState.isLogging)),
                icon: Icon(
                  logState.isLogging
                      ? Icons.stop_circle_outlined
                      : Icons.save_alt_outlined,
                  size: 18,
                ),
                label: Text(logState.isLogging ? '停止落盘' : '接收落盘'),
              ),
              ?trailing,
              if (logState.isLogging) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '${logState.bytesWritten} B',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (logState.errorMessage != null) ...<Widget>[
                const SizedBox(width: 8),
                Tooltip(
                  message: logState.errorMessage!,
                  child: Icon(
                    Icons.error_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _selectAndSendFile(BuildContext context) async {
    if (fileSendController.terminal.state.value.isExclusiveSend) {
      fileSendController.terminal.showNotice('ISP 独占串口期间不能发送文件');
      return;
    }
    try {
      final file = await pickSendFile();
      if (file == null || !context.mounted) {
        return;
      }
      if (fileSendController.terminal.state.value.isExclusiveSend) {
        fileSendController.terminal.showNotice('ISP 独占串口期间不能发送文件');
        return;
      }
      await fileSendController.start(file);
    } catch (error) {
      if (context.mounted) {
        fileSendController.terminal.showNotice('选择发送文件失败：$error');
      }
    }
  }

  Future<void> _toggleReceiveLog(BuildContext context, bool isLogging) async {
    if (isLogging) {
      try {
        await receiveLogController.stop();
      } catch (error) {
        if (context.mounted) {
          receiveLogController.terminal.showNotice('停止接收落盘失败：$error');
        }
      }
      return;
    }
    try {
      final file = await pickReceiveFile();
      if (file == null || !context.mounted) {
        return;
      }
      await receiveLogController.start(file);
    } catch (error) {
      if (context.mounted) {
        receiveLogController.terminal.showNotice('选择接收日志路径失败：$error');
      }
    }
  }
}

class _FileSendProgress extends StatelessWidget {
  const _FileSendProgress({required this.state, this.onCancel});

  final FileSendState state;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final label =
        state.errorMessage ??
        '${state.fileName ?? '文件'}  ${state.sentBytes}/${state.totalBytes} B';
    return Row(
      children: <Widget>[
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            value: state.totalBytes > 0 ? state.progress : null,
            minHeight: 6,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: state.errorMessage == null
                  ? null
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ),
        if (onCancel != null)
          IconButton(
            tooltip: '取消发送',
            onPressed: onCancel,
            icon: const Icon(Icons.cancel_outlined, size: 18),
          ),
      ],
    );
  }
}

/// 默认发送文件选择器。
Future<File?> pickSendFileDefault() async {
  final file = await openFile(confirmButtonText: '选择发送文件');
  return file == null ? null : File(file.path);
}

/// 默认接收日志路径选择器。
Future<File?> pickReceiveFileDefault() async {
  final timestamp = DateTime.now().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final location = await getSaveLocation(
    suggestedName: 'sscom-receive-$timestamp.log',
    confirmButtonText: '开始记录',
  );
  return location == null ? null : File(location.path);
}
