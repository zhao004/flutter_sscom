import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sscom/core/isp/isp_protocol.dart';
import 'package:flutter_sscom/core/transport/transport_barrel.dart';
import 'package:flutter_sscom/features/isp/application/isp_controller.dart';
import 'package:signals/signals_flutter.dart';

/// ISP 固件选择回调。
typedef IspFirmwareSelectionCallback = Future<File?> Function();

/// 选择 Intel HEX 固件。
Future<File?> pickIspFirmwareDefault() async {
  final file = await openFile(
    confirmButtonText: '选择 Intel HEX',
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(label: 'Intel HEX', extensions: <String>['hex', 'ihx']),
    ],
  );
  return file == null ? null : File(file.path);
}

/// ISP 独立工作区。
class IspPage extends StatelessWidget {
  /// 创建 ISP 页面。
  const IspPage({
    super.key,
    required this.controller,
    this.pickFirmware = pickIspFirmwareDefault,
  });

  /// ISP 控制器。
  final IspController controller;

  /// 可替换的固件选择器。
  final IspFirmwareSelectionCallback pickFirmware;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ISP 编程')),
      body: SafeArea(
        child: SignalBuilder(
          builder: (context) {
            final state = controller.state.value;
            return ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                const _ExperimentalWarning(),
                const SizedBox(height: 10),
                _TargetCard(controller: controller),
                const SizedBox(height: 10),
                if (state.family == IspTargetFamily.stc15)
                  const _StcBlockedCard()
                else ...<Widget>[
                  _ConnectionRequirements(controller: controller),
                  const SizedBox(height: 10),
                  _FirmwareCard(
                    controller: controller,
                    pickFirmware: pickFirmware,
                  ),
                  const SizedBox(height: 10),
                  _DeviceCard(controller: controller),
                  const SizedBox(height: 10),
                  _ProgramCard(controller: controller),
                ],
                if (state.message != null ||
                    state.errorMessage != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _MessageCard(
                    message: state.message,
                    error: state.errorMessage,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.controller});

  final IspController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state.value;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 210,
              child: DropdownButtonFormField<IspTargetFamily>(
                key: ValueKey<String>('isp-family-${state.family.name}'),
                isExpanded: true,
                initialValue: state.family,
                decoration: const InputDecoration(
                  labelText: '目标系列',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<IspTargetFamily>>[
                  DropdownMenuItem<IspTargetFamily>(
                    value: IspTargetFamily.stm32Gd32,
                    child: Text('STM32 / GD32'),
                  ),
                  DropdownMenuItem<IspTargetFamily>(
                    value: IspTargetFamily.stc15,
                    child: Text('STC / IAP15'),
                  ),
                ],
                onChanged: state.isBusy
                    ? null
                    : (family) {
                        if (family != null) {
                          unawaited(controller.setFamily(family));
                        }
                      },
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<IspConnectionSource>(
                key: ValueKey<String>(
                  'isp-source-${state.connectionSource.name}',
                ),
                isExpanded: true,
                initialValue: state.connectionSource,
                decoration: const InputDecoration(
                  labelText: '连接来源',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<IspConnectionSource>>[
                  DropdownMenuItem<IspConnectionSource>(
                    value: IspConnectionSource.hardware,
                    child: Text('当前串口'),
                  ),
                  DropdownMenuItem<IspConnectionSource>(
                    value: IspConnectionSource.stm32Simulator,
                    child: Text('STM32 模拟器'),
                  ),
                ],
                onChanged: state.isBusy || state.family == IspTargetFamily.stc15
                    ? null
                    : (source) {
                        if (source != null) {
                          unawaited(controller.setConnectionSource(source));
                        }
                      },
              ),
            ),
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<int>(
                key: ValueKey<String>('isp-flash-${state.flashSizeKiB}'),
                isExpanded: true,
                initialValue: state.flashSizeKiB,
                decoration: const InputDecoration(
                  labelText: 'Flash 容量',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <int>[16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
                    .map(
                      (size) => DropdownMenuItem<int>(
                        value: size,
                        child: Text('$size KiB'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: state.isBusy
                    ? null
                    : (size) {
                        if (size != null) {
                          unawaited(controller.setFlashSizeKiB(size));
                        }
                      },
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<IspResetMode>(
                key: ValueKey<String>('isp-reset-${state.resetMode.name}'),
                isExpanded: true,
                initialValue: state.resetMode,
                decoration: const InputDecoration(
                  labelText: '进入 bootloader',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const <DropdownMenuItem<IspResetMode>>[
                  DropdownMenuItem<IspResetMode>(
                    value: IspResetMode.manual,
                    child: Text('手动复位'),
                  ),
                  DropdownMenuItem<IspResetMode>(
                    value: IspResetMode.dtrLowPulse,
                    child: Text('DTR 低脉冲'),
                  ),
                  DropdownMenuItem<IspResetMode>(
                    value: IspResetMode.rtsLowPulse,
                    child: Text('RTS 低脉冲'),
                  ),
                ],
                onChanged: state.isBusy
                    ? null
                    : (mode) {
                        if (mode != null) {
                          controller.setResetMode(mode);
                        }
                      },
              ),
            ),
            FilterChip(
              label: const Text('校验后启动程序'),
              selected: state.runAfterProgramming,
              onSelected: state.isBusy
                  ? null
                  : controller.setRunAfterProgramming,
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionRequirements extends StatelessWidget {
  const _ConnectionRequirements({required this.controller});

  final IspController controller;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isSimulator =
            controller.state.value.connectionSource ==
            IspConnectionSource.stm32Simulator;
        final terminal = controller.terminal.state.value;
        final connected =
            terminal.transportMode == TransportMode.serial &&
            terminal.isConnected;
        final uartValid =
            terminal.config.dataBits == SerialDataBits.eight &&
            terminal.config.stopBits == SerialStopBits.one &&
            terminal.config.parity == SerialParity.even;
        final colors = Theme.of(context).colorScheme;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('硬件准备', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (isSimulator)
                  const Text('模拟器不访问串口，可直接完成识别、烧录和回读校验。')
                else ...<Widget>[
                  _RequirementRow(
                    satisfied: connected,
                    text: connected ? '串口已连接' : '请先在主工作区连接串口',
                  ),
                  _RequirementRow(
                    satisfied: uartValid,
                    text: uartValid
                        ? '当前串口参数为 8E1'
                        : 'STM/GD32 bootloader 要求 8 数据位、偶校验、1 停止位',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '请将 BOOT0 置为 bootloader 有效电平；手动复位模式会在点击识别后持续发送同步字节，请在此期间复位设备。',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FirmwareCard extends StatelessWidget {
  const _FirmwareCard({required this.controller, required this.pickFirmware});

  final IspController controller;
  final IspFirmwareSelectionCallback pickFirmware;

  @override
  Widget build(BuildContext context) {
    final state = controller.state.value;
    final image = state.image;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('固件文件', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => unawaited(_pickAndLoad(context)),
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('选择 Intel HEX'),
                ),
              ],
            ),
            if (state.firmwareName != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(state.firmwareName!),
              if (image != null) ...<Widget>[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 20,
                  runSpacing: 4,
                  children: <Widget>[
                    Text('${image.totalBytes} 字节'),
                    Text('${image.segmentCount} 个地址段'),
                    Text(
                      '0x${image.minimumAddress.toRadixString(16).toUpperCase()}–'
                      '0x${(image.maximumAddressExclusive - 1).toRadixString(16).toUpperCase()}',
                    ),
                    if (image.entryPoint != null)
                      Text(
                        '入口 0x${image.entryPoint!.toRadixString(16).toUpperCase()}',
                      ),
                  ],
                ),
              ],
            ] else
              const SizedBox(height: 8),
            if (state.firmwareError != null)
              Text(
                state.firmwareError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (state.validationError != null && image != null)
              Text(
                state.validationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndLoad(BuildContext context) async {
    final file = await pickFirmware();
    if (file != null) {
      await controller.loadFirmware(file);
    }
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.controller});

  final IspController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state.value;
    final info = state.deviceInfo;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('目标识别', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: state.isBusy
                      ? null
                      : () => unawaited(controller.inspectDevice()),
                  icon: const Icon(Icons.usb),
                  label: Text(info == null ? '识别设备' : '重新识别'),
                ),
              ],
            ),
            if (info == null)
              const Text('识别操作只读取 bootloader 版本、命令集和设备 ID，不会擦除 Flash。')
            else
              Wrap(
                spacing: 20,
                runSpacing: 4,
                children: <Widget>[
                  Text(
                    '产品 ID 0x${info.productIdValue.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                  ),
                  Text(
                    'bootloader 0x${info.bootloaderVersion.toRadixString(16).toUpperCase()}',
                  ),
                  Text('命令 ${info.commands.length} 项'),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({required this.controller});

  final IspController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state.value;
    final progressLabel = _progressLabel(state.progressPhase);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('烧录与校验', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(_phaseLabel(state.phase)),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: state.progress),
            const SizedBox(height: 6),
            Text(
              state.totalBytes <= 0
                  ? progressLabel
                  : '$progressLabel ${state.completedBytes}/${state.totalBytes} 字节',
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                if (state.isBusy)
                  OutlinedButton.icon(
                    onPressed: controller.cancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('取消'),
                  )
                else if (state.deviceInfo != null)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(controller.endSession()),
                    icon: const Icon(Icons.link_off),
                    label: const Text('结束会话'),
                  ),
                FilledButton.icon(
                  onPressed: state.canProgram
                      ? () => unawaited(_confirmAndProgram(context, state))
                      : null,
                  icon: const Icon(Icons.memory),
                  label: const Text('擦除并烧录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmAndProgram(
    BuildContext context,
    IspViewState state,
  ) async {
    final info = state.deviceInfo;
    final image = state.image;
    if (info == null || image == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('确认擦除并烧录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('该操作会先全片擦除目标 Flash，然后写入并回读校验固件。'),
            const SizedBox(height: 10),
            Text(
              '目标：STM32/GD32（${state.connectionSource == IspConnectionSource.stm32Simulator ? '模拟器' : '当前串口'}）',
            ),
            Text(
              '产品 ID：0x${info.productIdValue.toRadixString(16).padLeft(4, '0').toUpperCase()}',
            ),
            Text('固件：${state.firmwareName ?? '-'}'),
            Text(
              '地址：0x${image.minimumAddress.toRadixString(16).toUpperCase()}–'
              '0x${(image.maximumAddressExclusive - 1).toRadixString(16).toUpperCase()}',
            ),
            Text('Flash 容量：${state.flashSizeKiB} KiB'),
            Text('完成后启动：${state.runAfterProgramming ? '是' : '否'}'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认擦除并烧录'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await controller.program();
    }
  }
}

class _ExperimentalWarning extends StatelessWidget {
  const _ExperimentalWarning();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber, color: colors.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ISP 仍处于实验阶段，尚未完成真实硬件在环验收。仅用于可恢复的测试设备；'
              '错误的 BOOT0、复位极性或串口参数可能导致烧录失败。',
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _StcBlockedCard extends StatelessWidget {
  const _StcBlockedCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'STC / IAP15 烧录尚未启用',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              '旧版入口只确认了同步包、数据包长度和 ACK 分支，尚未获得可复现的串口 trace、'
              '型号矩阵与真实设备验证。为避免错误擦写，本版本不提供未经确认的 STC 烧录。',
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({this.message, this.error});

  final String? message;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isError = error != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        error ?? message ?? '',
        style: TextStyle(
          color: isError
              ? colors.onErrorContainer
              : colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _RequirementRow extends StatelessWidget {
  const _RequirementRow({required this.satisfied, required this.text});

  final bool satisfied;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(
          satisfied ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 18,
          color: satisfied
              ? Colors.green
              : Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

String _phaseLabel(IspPhase phase) {
  return switch (phase) {
    IspPhase.idle => '未开始',
    IspPhase.detecting => '识别中',
    IspPhase.ready => '已就绪',
    IspPhase.erasing => '擦除中',
    IspPhase.writing => '写入中',
    IspPhase.verifying => '校验中',
    IspPhase.starting => '启动中',
    IspPhase.completed => '已完成',
    IspPhase.failed => '失败',
    IspPhase.cancelled => '已取消',
  };
}

String _progressLabel(IspOperationPhase? phase) {
  return switch (phase) {
    null => '等待开始',
    IspOperationPhase.detecting => '正在识别',
    IspOperationPhase.erasing => '正在擦除',
    IspOperationPhase.writing => '正在写入',
    IspOperationPhase.verifying => '正在校验',
    IspOperationPhase.starting => '正在启动',
    IspOperationPhase.completed => '操作完成',
  };
}
