import 'dart:async';
import 'dart:convert';

import 'package:flutter_sscom/features/multi_send/application/multi_send_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';

import '../domain/app_settings.dart';
import '../infrastructure/json_settings_repository.dart';

/// 监听控制器偏好变化并以防抖方式保存设置。
final class SettingsPersistenceCoordinator {
  /// 创建持久化协调器。
  SettingsPersistenceCoordinator({
    required this.repository,
    required this.controller,
    required AppSettings initialSettings,
    this.multiSendController,
    this.debounce = const Duration(milliseconds: 500),
  }) : _settings = initialSettings,
       _lastFingerprint = _fingerprint(initialSettings) {
    _subscribe();
  }

  final SettingsRepository repository;
  final TerminalController controller;
  final MultiSendController? multiSendController;
  final Duration debounce;

  void Function()? _unsubscribe;
  void Function()? _multiSendUnsubscribe;
  AppSettings _settings;
  String _lastFingerprint;
  Timer? _timer;
  Future<void>? _saveChain;
  bool _dirty = false;
  bool _suspended = false;
  bool _disposed = false;

  /// 当前准备写入的完整设置。
  AppSettings get settings => _settings;

  /// 是否已为迁移结果暂停当前运行实例的自动保存。
  bool get isSuspended => _suspended;

  /// 保存迁移结果，并暂停当前运行实例的后续自动保存。
  ///
  /// 手动迁移要求重启应用才能完整生效。迁移文件必须先写入磁盘，但旧运行
  /// 实例仍持有启动时设置；若继续监听控制器变化，退出时的防抖保存会覆盖
  /// 迁移结果，因此保存成功后保持挂起，直到进程退出。
  Future<void> replaceForRestart(AppSettings settings) async {
    if (_disposed) {
      throw StateError('SettingsPersistenceCoordinator 已销毁');
    }
    if (_suspended) {
      throw StateError('设置持久化已暂停，请重启应用');
    }

    _suspended = true;
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    _unsubscribe?.call();
    _multiSendUnsubscribe?.call();
    _unsubscribe = null;
    _multiSendUnsubscribe = null;

    final pendingSave = _saveChain;
    if (pendingSave != null) {
      await pendingSave;
    }

    try {
      await repository.save(settings);
      _settings = settings;
      _lastFingerprint = _fingerprint(settings);
    } catch (_) {
      _resumeSubscriptions();
      rethrow;
    }
  }

  void _subscribe() {
    _unsubscribe = controller.state.subscribe(_handleState);
    _multiSendUnsubscribe = multiSendController?.state.subscribe(
      _handleMultiSend,
    );
  }

  void _resumeSubscriptions() {
    if (_disposed) {
      return;
    }
    _suspended = false;
    _lastFingerprint = _fingerprint(_settings);
    _subscribe();
  }

  void _handleState(TerminalViewState state) {
    if (_disposed || _suspended) {
      return;
    }
    _updateSettings(_merge(_settings, state));
  }

  void _handleMultiSend(MultiSendState state) {
    if (_disposed || _suspended) {
      return;
    }
    _updateSettings(_settings.copyWith(multiSend: state.entries));
  }

  void _updateSettings(AppSettings next) {
    final merged = next;
    final fingerprint = _fingerprint(merged);
    if (fingerprint == _lastFingerprint) {
      return;
    }
    _settings = merged;
    _lastFingerprint = fingerprint;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      unawaited(flush());
    });
  }

  /// 立即写入未保存的设置。
  Future<void> flush() {
    if (_suspended) {
      return _saveChain ?? Future<void>.value();
    }
    _timer?.cancel();
    _timer = null;
    if (!_dirty) {
      return _saveChain ?? Future<void>.value();
    }
    _dirty = false;
    final snapshot = _settings;
    final previous = _saveChain;
    final operation = previous == null
        ? repository.save(snapshot)
        : previous.then((_) => repository.save(snapshot));
    _saveChain = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (!_disposed) {
          controller.showNotice('设置保存失败：$error');
        }
      },
    );
    return operation;
  }

  /// 停止计时器，取消订阅并刷新待保存设置。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = null;

    if (_suspended) {
      final pendingSave = _saveChain;
      if (pendingSave != null) {
        try {
          await pendingSave;
        } catch (_) {
          // 成功迁移后不再写回旧运行实例状态。
        }
      }
      _disposed = true;
      return;
    }

    _unsubscribe?.call();
    _multiSendUnsubscribe?.call();
    _unsubscribe = null;
    _multiSendUnsubscribe = null;
    try {
      if (_dirty) {
        await flush();
      } else {
        final pendingSave = _saveChain;
        if (pendingSave != null) {
          await pendingSave;
        }
      }
    } catch (_) {
      // 保存失败已通过 notice 暴露，销毁流程不能因此跳过其他资源。
    } finally {
      _disposed = true;
    }
  }

  AppSettings _merge(AppSettings base, TerminalViewState state) {
    return base.copyWith(
      serial: state.config,
      terminal: TerminalPreferences(
        displayMode: state.displayMode,
        showTimestamp: state.showTimestamp,
        autoScroll: state.autoScroll,
        packetSplitEnabled: base.terminal.packetSplitEnabled,
        packetSplitTimeoutMs: base.terminal.packetSplitTimeoutMs,
        maxRawBytes: base.terminal.maxRawBytes,
      ),
      send: SendPreferences(
        mode: state.sendMode,
        textDraft: state.textDraft,
        hexDraft: state.hexDraft,
        appendCrLf: state.sendAppendCrLf,
        checksumMode: state.sendChecksumMode,
        checksumStartByte: state.sendChecksumStartByte,
        checksumTrailingByteCount: state.sendChecksumTrailingByteCount,
        repeatIntervalMs: base.send.repeatIntervalMs,
      ),
      network: NetworkPreferences(
        mode: state.transportMode,
        safetyMode: state.networkSafetyMode,
        bindAddress: state.bindAddress,
        remoteHost: state.remoteHost,
        remotePort: state.remotePort,
        localPort: state.localPort,
        followRemoteEndpoint: state.followRemoteEndpoint,
      ),
    );
  }

  static String _fingerprint(AppSettings settings) {
    final json = settings.toJson();
    return jsonEncode(<String, Object?>{
      'serial': json['serial'],
      'terminal': json['terminal'],
      'send': json['send'],
      'multiSend': json['multiSend'],
      'network': json['network'],
    });
  }
}
