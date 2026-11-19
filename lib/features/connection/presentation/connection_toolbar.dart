import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_sscom/app/theme/sscom_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:signals/signals_flutter.dart';

/// 串口和 TCP/UDP 共用的连接控制栏。
class ConnectionToolbar extends StatefulWidget {
  /// 创建连接控制栏。
  const ConnectionToolbar({super.key, required this.controller});

  /// 工作区控制器。
  final TerminalController controller;

  @override
  State<ConnectionToolbar> createState() => _ConnectionToolbarState();
}

class _ConnectionToolbarState extends State<ConnectionToolbar> {
  late final TextEditingController _bindAddressController;
  late final TextEditingController _remoteHostController;
  late final TextEditingController _localPortController;
  late final TextEditingController _remotePortController;
  late final FocusNode _bindAddressFocus;
  late final FocusNode _remoteHostFocus;
  late final FocusNode _localPortFocus;
  late final FocusNode _remotePortFocus;
  late final void Function() _stateUnsubscribe;

  @override
  void initState() {
    super.initState();
    final state = widget.controller.state.value;
    _bindAddressController = TextEditingController(text: state.bindAddress);
    _remoteHostController = TextEditingController(text: state.remoteHost);
    _localPortController = TextEditingController(text: '${state.localPort}');
    _remotePortController = TextEditingController(text: '${state.remotePort}');
    _bindAddressFocus = FocusNode();
    _remoteHostFocus = FocusNode();
    _localPortFocus = FocusNode();
    _remotePortFocus = FocusNode();
    _stateUnsubscribe = widget.controller.state.subscribe((_) {
      if (mounted) {
        _syncNetworkFields(widget.controller.state.value);
      }
    });
  }

  @override
  void dispose() {
    _stateUnsubscribe();
    _bindAddressController.dispose();
    _remoteHostController.dispose();
    _localPortController.dispose();
    _remotePortController.dispose();
    _bindAddressFocus.dispose();
    _remoteHostFocus.dispose();
    _localPortFocus.dispose();
    _remotePortFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final state = widget.controller.state.value;
        final busy =
            state.isOpening ||
            state.isExclusiveSend ||
            state.status == TransportStatus.connecting ||
            state.status == TransportStatus.disconnecting;
        final configurable = state.canConfigure && !busy;
        final networkValid = _networkFieldsValid(state);

        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : state.isTransportActive
                  ? () => unawaited(widget.controller.close())
                  : state.transportMode == TransportMode.serial
                  ? state.config.portName.isEmpty
                        ? null
                        : () => unawaited(widget.controller.open())
                  : networkValid
                  ? () => unawaited(_openNetwork(state))
                  : null,
              icon: Icon(
                state.isTransportActive
                    ? Icons.link_off_rounded
                    : Icons.link_rounded,
                size: 20,
              ),
              label: Text(
                state.isTransportActive
                    ? '关闭'
                    : state.status == TransportStatus.error
                    ? '重试'
                    : state.transportMode == TransportMode.tcpServer
                    ? '监听'
                    : '连接',
              ),
            ),
            if (!state.isNetworkMode) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed:
                    state.isTransportActive || busy || state.isRefreshingPorts
                    ? null
                    : () => unawaited(widget.controller.refreshPorts()),
                icon: state.isRefreshingPorts
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 20),
                label: const Text('刷新'),
              ),
            ],
          ],
        );
        return WorkspaceSurface(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 1200;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 4,
                            height: 19,
                            decoration: BoxDecoration(
                              color: SscomTheme.blue,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 9),
                          const Text(
                            '连接类型',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      WorkspaceSegments<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.memory_outlined, size: 18),
                            label: Text('串口通信'),
                          ),
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.language_rounded, size: 18),
                            label: Text('网络通信'),
                          ),
                        ],
                        selected: state.isNetworkMode,
                        onChanged: busy || state.isSending
                            ? null
                            : (network) => unawaited(
                                widget.controller.switchTransportMode(
                                  network
                                      ? TransportMode.tcpClient
                                      : TransportMode.serial,
                                ),
                              ),
                      ),
                      _TransportBadge(state: state),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: state.status == TransportStatus.error
                              ? const Color(0xFFFFEBEE)
                              : state.isTransportActive
                              ? const Color(0xFFE0F6EB)
                              : const Color(0xFFEDF2FA),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _StatusDot(status: state.status),
                            const SizedBox(width: 7),
                            Text(
                              _statusLabel(state.status),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!wide) actions,
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: state.transportMode == TransportMode.serial
                              ? _serialFields(
                                  state,
                                  configurable,
                                  compact: constraints.maxWidth < 1000,
                                )
                              : [
                                  _EnumField<TransportMode>(
                                    label: '协议',
                                    width: 150,
                                    value: state.transportMode,
                                    values: const [
                                      TransportMode.tcpClient,
                                      TransportMode.tcpServer,
                                      TransportMode.udp,
                                    ],
                                    labelBuilder: _modeLabel,
                                    enabled: configurable,
                                    onChanged: (mode) => unawaited(
                                      widget.controller.switchTransportMode(
                                        mode,
                                      ),
                                    ),
                                  ),
                                  ..._networkFields(state, configurable),
                                ],
                        ),
                      ),
                      if (wide) ...[const SizedBox(width: 16), actions],
                    ],
                  ),
                  if (state.connectionDetail != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.connectionDetail!,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (_showsExternalWarning(state)) ...[
                    const SizedBox(height: 8),
                    _ExternalListenWarning(state: state),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _serialFields(
    TerminalViewState state,
    bool configurable, {
    bool compact = false,
  }) {
    return <Widget>[
      _SerialPortField(
        state: state,
        enabled: configurable,
        width: compact ? 180 : 220,
        onChanged: (portName) =>
            _updateSerialConfig(state.config.copyWith(portName: portName)),
      ),
      _EnumField<int>(
        label: '波特率',
        width: 110,
        value: state.config.baudRate,
        values: <int>{
          state.config.baudRate,
          9600,
          19200,
          38400,
          57600,
          115200,
          230400,
          460800,
          921600,
        }.toList()..sort(),
        labelBuilder: (value) => '$value',
        enabled: configurable,
        onChanged: (value) =>
            _updateSerialConfig(state.config.copyWith(baudRate: value)),
      ),
      _EnumField<SerialDataBits>(
        label: '数据位',
        width: compact ? 70 : 80,
        value: state.config.dataBits,
        values: SerialDataBits.values,
        labelBuilder: (value) => '${value.value}',
        enabled: configurable,
        onChanged: (value) =>
            _updateSerialConfig(state.config.copyWith(dataBits: value)),
      ),
      _EnumField<SerialParity>(
        label: '校验位',
        width: compact ? 80 : 92,
        value: state.config.parity,
        values: SerialParity.values,
        labelBuilder: _parityLabel,
        enabled: configurable,
        onChanged: (value) =>
            _updateSerialConfig(state.config.copyWith(parity: value)),
      ),
      _EnumField<SerialStopBits>(
        label: '停止位',
        width: compact ? 70 : 80,
        value: state.config.stopBits == SerialStopBits.two
            ? SerialStopBits.two
            : SerialStopBits.one,
        values: const <SerialStopBits>[SerialStopBits.one, SerialStopBits.two],
        labelBuilder: (value) => value == SerialStopBits.one ? '1' : '2',
        enabled: configurable,
        onChanged: (value) =>
            _updateSerialConfig(state.config.copyWith(stopBits: value)),
      ),
      _EnumField<SerialFlowControl>(
        label: '流控',
        width: compact ? 90 : 100,
        value: state.config.flowControl,
        values: SerialFlowControl.values,
        labelBuilder: _flowLabel,
        enabled: configurable,
        onChanged: (value) =>
            _updateSerialConfig(state.config.copyWith(flowControl: value)),
      ),
      if (compact)
        PopupMenuButton<String>(
          tooltip: '串口信号',
          icon: const Icon(Icons.tune_rounded, size: 20),
          onSelected: (pin) {
            if (pin == 'dtr') {
              _setDtr(
                state,
                !(state.isConnected
                    ? state.signals.dtr
                    : state.config.initialDtr),
              );
            }
            if (pin == 'rts') {
              _setRts(
                state,
                !(state.isConnected
                    ? state.signals.rts
                    : state.config.initialRts),
              );
            }
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'dtr',
              checked: state.isConnected
                  ? state.signals.dtr
                  : state.config.initialDtr,
              enabled: _pinEnabled(
                state: state,
                conflictingFlow: SerialFlowControl.dtrDsr,
              ),
              child: const Text('DTR'),
            ),
            CheckedPopupMenuItem(
              value: 'rts',
              checked: state.isConnected
                  ? state.signals.rts
                  : state.config.initialRts,
              enabled: _pinEnabled(
                state: state,
                conflictingFlow: SerialFlowControl.rtsCts,
              ),
              child: const Text('RTS'),
            ),
          ],
        )
      else ...[
        _PinChip(
          label: 'DTR',
          selected: state.isConnected
              ? state.signals.dtr
              : state.config.initialDtr,
          enabled: _pinEnabled(
            state: state,
            conflictingFlow: SerialFlowControl.dtrDsr,
          ),
          onSelected: (enabled) => _setDtr(state, enabled),
        ),
        _PinChip(
          label: 'RTS',
          selected: state.isConnected
              ? state.signals.rts
              : state.config.initialRts,
          enabled: _pinEnabled(
            state: state,
            conflictingFlow: SerialFlowControl.rtsCts,
          ),
          onSelected: (enabled) => _setRts(state, enabled),
        ),
      ],
    ];
  }

  List<Widget> _networkFields(TerminalViewState state, bool configurable) {
    final usesBindAddress =
        state.transportMode == TransportMode.tcpServer ||
        state.transportMode == TransportMode.udp;
    final usesRemoteHost =
        state.transportMode == TransportMode.tcpClient ||
        state.transportMode == TransportMode.udp;
    final remoteHostRequired =
        state.transportMode == TransportMode.tcpClient ||
        (state.transportMode == TransportMode.udp &&
            !state.followRemoteEndpoint);
    return <Widget>[
      if (usesBindAddress)
        _SettingTextField(
          key: ValueKey<String>('bind-${state.transportMode.name}'),
          controller: _bindAddressController,
          focusNode: _bindAddressFocus,
          label: '监听地址',
          width: 190,
          enabled: configurable,
          onChanged: (value) => _updateNetworkField(bindAddress: value),
          errorText: _valueIsEmpty(_bindAddressController.text) ? '必填' : null,
        ),
      if (usesBindAddress)
        _PortSettingField(
          controller: _localPortController,
          focusNode: _localPortFocus,
          label: '本地端口',
          enabled: configurable,
          onChanged: (value) => _updateNetworkPort(localPort: value),
          isValid: _isValidPort(_localPortController.text),
        ),
      if (usesRemoteHost)
        _SettingTextField(
          key: ValueKey<String>('remote-${state.transportMode.name}'),
          controller: _remoteHostController,
          focusNode: _remoteHostFocus,
          label: state.transportMode == TransportMode.udp ? '远端主机（可空）' : '远端主机',
          width: 210,
          enabled: configurable,
          onChanged: (value) => _updateNetworkField(remoteHost: value),
          errorText:
              remoteHostRequired && _valueIsEmpty(_remoteHostController.text)
              ? '必填'
              : null,
        ),
      if (usesRemoteHost)
        _PortSettingField(
          controller: _remotePortController,
          focusNode: _remotePortFocus,
          label: '远端端口',
          enabled: configurable,
          onChanged: (value) => _updateNetworkPort(remotePort: value),
          isValid: _isValidPort(_remotePortController.text),
        ),
      _EnumField<NetworkSafetyMode>(
        label: '网络策略',
        width: 155,
        value: state.networkSafetyMode,
        values: NetworkSafetyMode.values,
        labelBuilder: (mode) =>
            mode == NetworkSafetyMode.safe ? 'Safe' : 'Raw/Debug',
        enabled: configurable,
        onChanged: (mode) =>
            widget.controller.updateNetworkSettings(safetyMode: mode),
      ),
      if (state.transportMode == TransportMode.udp)
        FilterChip(
          label: const Text('跟随数据报来源'),
          selected: state.followRemoteEndpoint,
          onSelected: configurable
              ? (selected) => widget.controller.updateNetworkSettings(
                  followRemoteEndpoint: selected,
                )
              : null,
        ),
    ];
  }

  Future<void> _openNetwork(TerminalViewState state) async {
    if (!_networkFieldsValid(state)) {
      return;
    }
    if (_showsExternalWarning(state)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认对外监听'),
          content: Text(
            '即将监听 ${state.bindAddress}:${state.localPort}，该地址可被其他设备访问。\n\n'
            '当前网络通道不提供 TLS 或身份认证，请仅用于受控调试网络。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('仍然监听'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    await widget.controller.open();
  }

  bool _networkFieldsValid(TerminalViewState state) {
    if (!state.isNetworkMode) {
      return true;
    }
    final localPortValid = _isValidPort(_localPortController.text);
    final remotePortValid = _isValidPort(_remotePortController.text);
    if (state.networkSafetyMode == NetworkSafetyMode.safe &&
        _listensExternally(state) &&
        !_valueIsEmpty(_bindAddressController.text)) {
      return false;
    }
    return switch (state.transportMode) {
      TransportMode.serial => true,
      TransportMode.tcpClient =>
        !_valueIsEmpty(_remoteHostController.text) && remotePortValid,
      TransportMode.tcpServer =>
        !_valueIsEmpty(_bindAddressController.text) && localPortValid,
      TransportMode.udp =>
        !_valueIsEmpty(_bindAddressController.text) &&
            localPortValid &&
            remotePortValid &&
            (state.followRemoteEndpoint ||
                !_valueIsEmpty(_remoteHostController.text)),
    };
  }

  bool _showsExternalWarning(TerminalViewState state) {
    return _listensExternally(state) &&
        !_valueIsEmpty(_bindAddressController.text);
  }

  bool _listensExternally(TerminalViewState state) {
    final listensLocally =
        state.transportMode == TransportMode.tcpServer ||
        state.transportMode == TransportMode.udp;
    return listensLocally &&
        !_valueIsEmpty(_bindAddressController.text) &&
        !isLoopbackBindAddress(_bindAddressController.text);
  }

  void _syncNetworkFields(TerminalViewState state) {
    if (!_bindAddressFocus.hasFocus &&
        _bindAddressController.text != state.bindAddress) {
      _bindAddressController.text = state.bindAddress;
    }
    if (!_remoteHostFocus.hasFocus &&
        _remoteHostController.text != state.remoteHost) {
      _remoteHostController.text = state.remoteHost;
    }
    final localPort = '${state.localPort}';
    if (!_localPortFocus.hasFocus && _localPortController.text != localPort) {
      _localPortController.text = localPort;
    }
    final remotePort = '${state.remotePort}';
    if (!_remotePortFocus.hasFocus &&
        _remotePortController.text != remotePort) {
      _remotePortController.text = remotePort;
    }
  }

  void _updateNetworkField({String? bindAddress, String? remoteHost}) {
    setState(() {});
    widget.controller.updateNetworkSettings(
      bindAddress: bindAddress,
      remoteHost: remoteHost,
    );
  }

  void _updateNetworkPort({int? localPort, int? remotePort}) {
    setState(() {});
    widget.controller.updateNetworkSettings(
      localPort: localPort,
      remotePort: remotePort,
    );
  }

  void _updateSerialConfig(SerialConfig config) {
    unawaited(widget.controller.updateConfig(config));
  }

  void _setDtr(TerminalViewState state, bool enabled) {
    if (state.isConnected) {
      unawaited(widget.controller.setDtr(enabled));
    } else {
      _updateSerialConfig(state.config.copyWith(initialDtr: enabled));
    }
  }

  void _setRts(TerminalViewState state, bool enabled) {
    if (state.isConnected) {
      unawaited(widget.controller.setRts(enabled));
    } else {
      _updateSerialConfig(state.config.copyWith(initialRts: enabled));
    }
  }

  bool _pinEnabled({
    required TerminalViewState state,
    required SerialFlowControl conflictingFlow,
  }) {
    if (state.isExclusiveSend) {
      return false;
    }
    if (state.status == TransportStatus.error) {
      return false;
    }
    if (state.isConnected && state.config.flowControl == conflictingFlow) {
      return false;
    }
    return state.canConfigure || state.isConnected;
  }
}

/// 判断端口文本框是否包含合法端口。
bool _isValidPort(String value) {
  final port = int.tryParse(value.trim());
  return port != null && port >= 1 && port <= 65535;
}

/// 判断设置文本是否为空。
bool _valueIsEmpty(String value) => value.trim().isEmpty;

/// 输入边框直接反映校验状态，不使用会在底部占位的 errorText。
OutlineInputBorder _networkInputBorder(
  BuildContext context,
  bool invalid, {
  bool focused = false,
}) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(9),
  borderSide: BorderSide(
    color: invalid
        ? Theme.of(context).colorScheme.error
        : focused
        ? SscomTheme.blue
        : SscomTheme.border,
    width: focused ? 1.5 : 1,
  ),
);

class _PortSettingField extends StatelessWidget {
  const _PortSettingField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.enabled,
    required this.onChanged,
    required this.isValid,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final bool enabled;
  final ValueChanged<int?> onChanged;
  final bool isValid;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: WorkspaceInputHint(
        label: label,
        errorText: isValid ? null : '1–65535',
        child: Semantics(
          label: label,
          child: TextField(
            key: ValueKey<String>('network-field-$label'),
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              enabledBorder: _networkInputBorder(context, !isValid),
              focusedBorder: _networkInputBorder(
                context,
                !isValid,
                focused: true,
              ),
              isDense: true,
            ),
            onChanged: (value) {
              // 空值也通知父级重算校验状态，避免连接按钮保留旧的有效状态。
              onChanged(int.tryParse(value));
            },
          ),
        ),
      ),
    );
  }
}

class _SettingTextField extends StatelessWidget {
  const _SettingTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.width,
    required this.enabled,
    required this.onChanged,
    required this.errorText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final double width;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: WorkspaceInputHint(
        label: label,
        errorText: errorText,
        child: Semantics(
          label: label,
          child: TextField(
            key: ValueKey<String>('network-field-$label'),
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            decoration: InputDecoration(
              enabledBorder: _networkInputBorder(context, errorText != null),
              focusedBorder: _networkInputBorder(
                context,
                errorText != null,
                focused: true,
              ),
              isDense: true,
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _SerialPortField extends StatelessWidget {
  const _SerialPortField({
    required this.state,
    required this.width,
    required this.enabled,
    required this.onChanged,
  });

  final TerminalViewState state;
  final double width;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final availablePaths = state.ports.map((port) => port.systemPath).toSet();
    final selected = availablePaths.contains(state.config.portName)
        ? state.config.portName
        : null;
    return SizedBox(
      width: width,
      child: WorkspaceField(
        label: '串口',
        child: DropdownButtonFormField<String>(
          key: ValueKey<String>(
            'port-${state.config.portName}-${availablePaths.length}',
          ),
          initialValue: selected,
          isExpanded: true,
          style: const TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 13,
            color: SscomTheme.ink,
          ),
          decoration: const InputDecoration(isDense: true),
          hint: Text(state.ports.isEmpty ? '无可用串口' : '选择串口'),
          items: state.ports
              .map(
                (port) => DropdownMenuItem<String>(
                  value: port.systemPath,
                  child: Text(
                    port.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (value) {
                  if (value != null) {
                    onChanged(value);
                  }
                }
              : null,
        ),
      ),
    );
  }
}

class _EnumField<T> extends StatelessWidget {
  const _EnumField({
    required this.label,
    required this.width,
    required this.value,
    required this.values,
    required this.labelBuilder,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final double width;
  final T value;
  final List<T> values;
  final String Function(T value) labelBuilder;
  final bool enabled;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: WorkspaceField(
        label: label,
        child: DropdownButtonFormField<T>(
          key: ValueKey<String>('$label-$value'),
          initialValue: value,
          isExpanded: true,
          style: const TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 13,
            color: SscomTheme.ink,
          ),
          decoration: InputDecoration(isDense: true),
          items: values
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text(
                    labelBuilder(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (selected) {
                  if (selected != null) {
                    onChanged(selected);
                  }
                }
              : null,
        ),
      ),
    );
  }
}

class _PinChip extends StatelessWidget {
  const _PinChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      showCheckmark: false,
      selected: selected,
      onSelected: enabled ? onSelected : null,
    );
  }
}

class _TransportBadge extends StatelessWidget {
  const _TransportBadge({required this.state});

  final TerminalViewState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (
      label,
      tooltip,
      background,
      foreground,
    ) = switch (state.transportMode) {
      TransportMode.serial when state.isSimulatedBackend => (
        '模拟模式',
        '当前为回环演示，不代表真实串口硬件行为',
        colorScheme.secondaryContainer,
        colorScheme.onSecondaryContainer,
      ),
      TransportMode.serial => (
        '实验性后端',
        '真实串口后端尚未完成硬件验收',
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      TransportMode.tcpClient ||
      TransportMode.tcpServer ||
      TransportMode.udp => (
        '网络',
        '网络通道无 TLS 与认证，仅用于受控调试网络',
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foreground),
        ),
      ),
    );
  }
}

class _ExternalListenWarning extends StatelessWidget {
  const _ExternalListenWarning({required this.state});

  final TerminalViewState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber, color: colors.onErrorContainer, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.networkSafetyMode == NetworkSafetyMode.safe
                  ? 'Safe 模式禁止监听非本机回环地址 '
                        '${state.bindAddress}:${state.localPort}；'
                        '如确需对外监听，请切换为 Raw/Debug 并重新确认风险。'
                  : '将监听非本机回环地址 '
                        '${state.bindAddress}:${state.localPort}，'
                        '打开前必须确认网络环境和访问来源。',
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final TransportStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TransportStatus.connected => Colors.green,
      TransportStatus.listening => Colors.blue,
      TransportStatus.connecting ||
      TransportStatus.disconnecting => Colors.orange,
      TransportStatus.error => Theme.of(context).colorScheme.error,
      TransportStatus.disconnected => Colors.grey,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

String _statusLabel(TransportStatus status) {
  return switch (status) {
    TransportStatus.disconnected => '未连接',
    TransportStatus.connecting => '连接中',
    TransportStatus.connected => '已连接',
    TransportStatus.listening => '监听中',
    TransportStatus.disconnecting => '断开中',
    TransportStatus.error => '错误',
  };
}

String _modeLabel(TransportMode mode) {
  return switch (mode) {
    TransportMode.serial => '串口',
    TransportMode.tcpClient => 'TCP 客户端',
    TransportMode.tcpServer => 'TCP 服务端',
    TransportMode.udp => 'UDP',
  };
}

String _parityLabel(SerialParity parity) {
  return switch (parity) {
    SerialParity.none => '无',
    SerialParity.odd => '奇',
    SerialParity.even => '偶',
    SerialParity.mark => '标记',
    SerialParity.space => '空格',
  };
}

String _flowLabel(SerialFlowControl flowControl) {
  return switch (flowControl) {
    SerialFlowControl.none => '无',
    SerialFlowControl.rtsCts => 'RTS/CTS',
    SerialFlowControl.xonXoff => 'XON/XOFF',
    SerialFlowControl.dtrDsr => 'DTR/DSR',
  };
}
