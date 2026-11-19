import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_sscom/app/theme/sscom_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/features/file_transfer/application/file_send_controller.dart';
import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:signals/signals_flutter.dart';

/// 文本/HEX 发送输入面板。
class SendPanel extends StatefulWidget {
  /// 创建发送面板。
  const SendPanel({
    super.key,
    required this.controller,
    required this.fileSendController,
    required this.multiSendController,
  });

  /// 工作区控制器。
  final TerminalController controller;

  /// 文件发送状态，用于阻止手工发送与文件发送交错。
  final FileSendController fileSendController;

  /// 多字符串发送状态，用于阻止手动发送交错。
  final MultiSendController multiSendController;

  @override
  State<SendPanel> createState() => _SendPanelState();
}

class _SendPanelState extends State<SendPanel> {
  final TextEditingController _inputController = TextEditingController();
  String? _inputError;
  bool _syncingText = false;

  @override
  void initState() {
    super.initState();
    final state = widget.controller.state.value;
    _inputController.text = _draftFor(state, state.sendMode);
    _inputController.addListener(_handleInputChanged);
  }

  @override
  void dispose() {
    _inputController
      ..removeListener(_handleInputChanged)
      ..dispose();
    super.dispose();
  }

  void _handleInputChanged() {
    if (_syncingText) {
      return;
    }
    widget.controller.updateSendDraft(_inputController.text);
    if (_inputError != null) {
      setState(() => _inputError = null);
    } else {
      setState(() {});
    }
  }

  Future<void> _send() async {
    final state = widget.controller.state.value;
    final fileSending = widget.fileSendController.state.value.isRunning;
    final multiSending = widget.multiSendController.state.value.isRunning;
    if (!state.isConnected ||
        state.isSending ||
        state.isExclusiveSend ||
        fileSending ||
        multiSending ||
        _inputController.text.isEmpty) {
      return;
    }
    setState(() => _inputError = null);
    final result = await widget.controller.send(
      SendRequest(input: _inputController.text),
    );
    if (!mounted || result != null) {
      return;
    }
    setState(() {
      _inputError = widget.controller.state.value.errorMessage;
    });
  }

  void _changeMode(SendInputMode nextMode) {
    final state = widget.controller.state.value;
    if (state.sendMode == nextMode) {
      return;
    }
    widget.controller.updateSendDraft(_inputController.text);
    widget.controller.setSendMode(nextMode);
    _syncText(_draftFor(widget.controller.state.value, nextMode));
    setState(() => _inputError = null);
  }

  void _syncText(String value) {
    _syncingText = true;
    _inputController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _syncingText = false;
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = widget.controller.state.value;
        final fileSending = widget.fileSendController.state.value.isRunning;
        final multiSending = widget.multiSendController.state.value.isRunning;
        final inputLocked = state.isSending || state.isExclusiveSend;
        final canSend =
            state.isConnected &&
            !inputLocked &&
            !fileSending &&
            !multiSending &&
            _inputController.text.isNotEmpty;
        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(
              LogicalKeyboardKey.enter,
              control: true,
            ): () =>
                unawaited(_send()),
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  WorkspaceSegments<SendInputMode>(
                    segments: const [
                      ButtonSegment(
                        value: SendInputMode.ansiText,
                        icon: Icon(Icons.title_rounded, size: 19),
                        label: Text('文本'),
                      ),
                      ButtonSegment(
                        value: SendInputMode.hex,
                        icon: Icon(Icons.grid_view_rounded, size: 17),
                        label: Text('HEX'),
                      ),
                    ],
                    selected: state.sendMode,
                    onChanged: inputLocked ? null : _changeMode,
                  ),
                  const SizedBox(width: 18),
                  const Text('校验'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 133,
                    child: DropdownButtonFormField<LegacyChecksumMode>(
                      key: ValueKey<LegacyChecksumMode>(state.sendChecksumMode),
                      initialValue: state.sendChecksumMode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                      ),
                      items: LegacyChecksumMode.values
                          .map(
                            (mode) => DropdownMenuItem(
                              value: mode,
                              child: Text(
                                _checksumLabel(mode),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: inputLocked
                          ? null
                          : (mode) {
                              if (mode != null) {
                                widget.controller.setSendChecksumMode(mode);
                              }
                            },
                    ),
                  ),
                  const SizedBox(width: 14),
                  WorkspaceCheck(
                    label: '追加 CRLF',
                    value: state.sendAppendCrLf,
                    onChanged:
                        state.sendMode == SendInputMode.hex || inputLocked
                        ? null
                        : widget.controller.setSendAppendCrLf,
                  ),
                  const Spacer(),
                  if (MediaQuery.sizeOf(context).width >= 1100)
                    Text(
                      'Ctrl + Enter 发送',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: SscomTheme.ink),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        enabled: !inputLocked,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        keyboardType: TextInputType.multiline,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontFamilyFallback: ['Microsoft YaHei', 'monospace'],
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText: state.sendMode == SendInputMode.ansiText
                              ? r'输入要发送的内容，支持 \r \n \xHH 等转义'
                              : '输入 HEX，例如：01 03 00 00 00 0A',
                          errorText: _inputError,
                          alignLabelWithHint: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 110,
                      height: 44,
                      child: FilledButton.icon(
                        onPressed: canSend ? () => unawaited(_send()) : null,
                        icon: state.isSending
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.near_me_outlined, size: 21),
                        label: const Text('发送'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _draftFor(TerminalViewState state, SendInputMode mode) {
  return switch (mode) {
    SendInputMode.ansiText => state.textDraft,
    SendInputMode.hex => state.hexDraft,
  };
}

String _checksumLabel(LegacyChecksumMode mode) {
  return switch (mode) {
    LegacyChecksumMode.none => '无',
    LegacyChecksumMode.modbusCrc16 => 'Modbus CRC16',
    LegacyChecksumMode.ccittCrc16 => 'CCITT CRC16',
    LegacyChecksumMode.crc32 => 'CRC32',
    LegacyChecksumMode.add8TwosComplement => 'ADD8 补码',
    LegacyChecksumMode.add8 => 'ADD8',
    LegacyChecksumMode.xor8 => 'XOR8',
    LegacyChecksumMode.add16 => 'ADD16',
  };
}
