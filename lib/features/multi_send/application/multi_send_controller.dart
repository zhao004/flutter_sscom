import 'dart:async';

import 'package:flutter_sscom/core/protocols/protocols.dart';
import 'package:flutter_sscom/features/settings/domain/app_settings.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_controller.dart';
import 'package:flutter_sscom/features/terminal/application/terminal_view_state.dart';
import 'package:signals/signals.dart';

/// 多字符串发送条目上限，与旧版 INI 的 N1..N99 保持一致。
const int maxMultiSendEntries = 99;

/// 单个多字符串条目的最大字符数。
const int maxMultiSendPayloadCharacters = 16 * 1024;

/// 多字符串条目名称的最大字符数。
const int maxMultiSendNameCharacters = 80;

/// 单个条目允许的最小发送间隔。
const int minMultiSendIntervalMs = 1;

/// 单个条目允许的最大发送间隔（24 小时）。
const int maxMultiSendIntervalMs = 24 * 60 * 60 * 1000;

const Object _notSet = Object();

/// 多字符串自动发送状态。
final class MultiSendState {
  /// 创建多字符串自动发送状态。
  MultiSendState({
    required List<MultiSendEntry> entries,
    this.isRunning = false,
    this.currentEntryIndex,
    this.completedSends = 0,
    this.completedCycles = 0,
    this.errorMessage,
  }) : entries = List<MultiSendEntry>.unmodifiable(entries);

  /// 当前条目顺序。
  final List<MultiSendEntry> entries;

  /// 是否正在循环发送。
  final bool isRunning;

  /// 当前正在发送的条目索引；空闲时为 `null`。
  final int? currentEntryIndex;

  /// 本次运行已完成的发送次数。
  final int completedSends;

  /// 本次运行已完成的循环次数。
  final int completedCycles;

  /// 最近一次启动或发送失败说明。
  final String? errorMessage;

  /// 返回替换部分字段后的状态。
  MultiSendState copyWith({
    List<MultiSendEntry>? entries,
    bool? isRunning,
    Object? currentEntryIndex = _notSet,
    int? completedSends,
    int? completedCycles,
    Object? errorMessage = _notSet,
  }) {
    return MultiSendState(
      entries: entries ?? this.entries,
      isRunning: isRunning ?? this.isRunning,
      currentEntryIndex: identical(currentEntryIndex, _notSet)
          ? this.currentEntryIndex
          : currentEntryIndex as int?,
      completedSends: completedSends ?? this.completedSends,
      completedCycles: completedCycles ?? this.completedCycles,
      errorMessage: identical(errorMessage, _notSet)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }
}

/// 按条目顺序循环发送多字符串。
///
/// 启用且内容非空的条目才会参与发送；每个条目发送完成后等待其自身间隔，
/// 一轮结束后自动从头循环，直到用户停止、连接断开或发送失败。
final class MultiSendController {
  /// 创建多字符串控制器。
  MultiSendController({
    required this.terminal,
    required List<MultiSendEntry> initialEntries,
  }) : _entries = _sanitizeInitialEntries(initialEntries) {
    _state = signal<MultiSendState>(MultiSendState(entries: _entries));
    _readonlyState = _state.readonly();
    _terminalUnsubscribe = terminal.state.subscribe(_handleTerminalState);
  }

  /// 发送依赖的终端控制器。
  final TerminalController terminal;

  late final Signal<MultiSendState> _state;
  late final ReadonlySignal<MultiSendState> _readonlyState;
  late final void Function() _terminalUnsubscribe;
  List<MultiSendEntry> _entries;
  Future<void>? _loopFuture;
  Completer<void>? _wake;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;

  /// 只读多字符串状态。
  ReadonlySignal<MultiSendState> get state => _readonlyState;

  /// 开始循环发送启用条目。
  void start() {
    _throwIfDisposed();
    if (_running) {
      return;
    }
    final snapshot = _entries
        .where((entry) => entry.enabled && entry.payload.trim().isNotEmpty)
        .toList(growable: false);
    if (!terminal.state.value.isConnected) {
      _setError('连接未建立，不能启动多字符串发送');
      return;
    }
    if (terminal.state.value.isExclusiveSend) {
      _setError('串口正被 ISP 等独占流程使用，不能启动多字符串发送');
      return;
    }
    if (terminal.state.value.isSending) {
      _setError('终端正在发送数据，不能启动多字符串发送');
      return;
    }
    if (snapshot.isEmpty) {
      _setError('没有启用且内容非空的多字符串条目');
      return;
    }

    _running = true;
    _generation++;
    _state.value = MultiSendState(entries: _entries, isRunning: true);
    final future = _runLoop(snapshot, _generation);
    _loopFuture = future;
    unawaited(future);
  }

  /// 停止循环发送并等待当前发送操作结束。
  Future<void> stop() async {
    _running = false;
    _generation++;
    _completeWake();
    final loop = _loopFuture;
    _loopFuture = null;
    if (loop != null) {
      try {
        await loop;
      } catch (_) {
        // 循环内部已经把可展示错误写入状态，停止流程不能再次抛出。
      }
    }
    if (!_disposed) {
      _state.value = _state.value.copyWith(
        isRunning: false,
        currentEntryIndex: null,
      );
    }
  }

  /// 用完整条目列表替换当前配置。
  bool replaceEntries(List<MultiSendEntry> entries) {
    _throwIfDisposed();
    if (!_canEdit()) {
      return false;
    }
    _entries = _validateEntries(entries);
    _publishEntries();
    return true;
  }

  /// 新增一个默认条目。
  MultiSendEntry? addEntry() {
    _throwIfDisposed();
    if (!_canEdit()) {
      return null;
    }
    if (_entries.length >= maxMultiSendEntries) {
      _setError('多字符串条目不能超过 $maxMultiSendEntries 条');
      return null;
    }
    final nextIndex = _nextAvailableIndex();
    if (nextIndex == null) {
      _setError('没有可用的多字符串条目编号');
      return null;
    }
    final entry = MultiSendEntry(
      index: nextIndex,
      mode: SendInputMode.ansiText,
      payload: '',
      enabled: true,
      name: '',
      intervalMs: 1000,
    );
    _entries = _validateEntries(<MultiSendEntry>[..._entries, entry]);
    _publishEntries();
    return entry;
  }

  /// 更新指定索引的条目。
  bool updateEntry(MultiSendEntry entry) {
    _throwIfDisposed();
    if (!_canEdit()) {
      return false;
    }
    final position = _entries.indexWhere((item) => item.index == entry.index);
    if (position < 0) {
      _setError('找不到多字符串条目 ${entry.index}');
      return false;
    }
    final replacement = List<MultiSendEntry>.of(_entries)..[position] = entry;
    _entries = _validateEntries(replacement);
    _publishEntries();
    return true;
  }

  /// 删除指定索引的条目。
  bool removeEntry(int index) {
    _throwIfDisposed();
    if (!_canEdit()) {
      return false;
    }
    final position = _entries.indexWhere((item) => item.index == index);
    if (position < 0) {
      return false;
    }
    final remaining = List<MultiSendEntry>.of(_entries)..removeAt(position);
    _entries = _validateEntries(remaining);
    _publishEntries();
    return true;
  }

  /// 上移或下移条目，`delta` 为 -1 或 1。
  bool moveEntry(int index, int delta) {
    _throwIfDisposed();
    if (!_canEdit() || (delta != -1 && delta != 1)) {
      return false;
    }
    final position = _entries.indexWhere((item) => item.index == index);
    final target = position + delta;
    if (position < 0 || target < 0 || target >= _entries.length) {
      return false;
    }
    final reordered = List<MultiSendEntry>.of(_entries);
    final entry = reordered.removeAt(position);
    reordered.insert(target, entry);
    _entries = _validateEntries(reordered);
    _publishEntries();
    return true;
  }

  /// 设置指定条目的启用状态。
  bool setEntryEnabled(int index, bool enabled) {
    for (final entry in _entries) {
      if (entry.index == index) {
        return updateEntry(entry.copyWith(enabled: enabled));
      }
    }
    return false;
  }

  /// 取消订阅、停止循环并释放状态信号。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _running = false;
    _generation++;
    _completeWake();
    _terminalUnsubscribe();
    final loop = _loopFuture;
    _loopFuture = null;
    if (loop != null) {
      try {
        await loop;
      } catch (_) {
        // dispose 必须继续释放信号，不在清理路径重复抛错。
      }
    }
    _state.dispose();
  }

  bool _canEdit() {
    if (_running) {
      _setError('多字符串发送运行中，停止后才能编辑');
      return false;
    }
    return true;
  }

  void _publishEntries() {
    if (_disposed) {
      return;
    }
    _state.value = MultiSendState(
      entries: _entries,
      completedSends: _state.value.completedSends,
      completedCycles: _state.value.completedCycles,
    );
  }

  void _setError(String message) {
    if (_disposed) {
      return;
    }
    _state.value = _state.value.copyWith(
      isRunning: false,
      currentEntryIndex: null,
      errorMessage: message,
    );
  }

  Future<void> _runLoop(List<MultiSendEntry> entries, int generation) async {
    try {
      while (_isActive(generation)) {
        for (final entry in entries) {
          if (!_isActive(generation)) {
            return;
          }
          _state.value = _state.value.copyWith(
            currentEntryIndex: entry.index,
            errorMessage: null,
          );
          final result = await terminal.sendFormatted(
            input: entry.payload,
            mode: entry.mode,
            appendCrLf: false,
          );
          if (!_isActive(generation)) {
            return;
          }
          if (result == null) {
            _fail(terminal.state.value.errorMessage ?? '多字符串发送失败');
            return;
          }
          _state.value = _state.value.copyWith(
            completedSends: _state.value.completedSends + 1,
          );
          await _delay(entry.intervalMs, generation);
        }
        if (!_isActive(generation)) {
          return;
        }
        _state.value = _state.value.copyWith(
          completedCycles: _state.value.completedCycles + 1,
        );
      }
    } catch (error) {
      if (_isActive(generation)) {
        _fail(error.toString());
      }
    } finally {
      if (generation == _generation && _running) {
        _running = false;
        if (!_disposed) {
          _state.value = _state.value.copyWith(
            isRunning: false,
            currentEntryIndex: null,
          );
        }
      }
    }
  }

  Future<void> _delay(int milliseconds, int generation) {
    if (!_isActive(generation)) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _wake = completer;
    final timer = Timer(Duration(milliseconds: milliseconds), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      if (identical(_wake, completer)) {
        _wake = null;
      }
    });
  }

  bool _isActive(int generation) =>
      !_disposed && _running && generation == _generation;

  void _fail(String message) {
    _running = false;
    _generation++;
    _completeWake();
    _setError(message);
  }

  void _completeWake() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }

  void _handleTerminalState(TerminalViewState state) {
    if (_running && !state.isConnected) {
      _fail('连接已断开，多字符串发送已停止');
    }
  }

  int? _nextAvailableIndex() {
    final used = <int>{for (final entry in _entries) entry.index};
    for (var index = 1; index <= maxMultiSendEntries; index++) {
      if (!used.contains(index)) {
        return index;
      }
    }
    return null;
  }

  static List<MultiSendEntry> _validateEntries(List<MultiSendEntry> entries) {
    if (entries.length > maxMultiSendEntries) {
      throw ArgumentError.value(
        entries.length,
        'entries',
        '多字符串条目不能超过 $maxMultiSendEntries 条',
      );
    }
    final indexes = <int>{};
    final validated = <MultiSendEntry>[];
    for (final entry in entries) {
      if (entry.index < 1 || entry.index > maxMultiSendEntries) {
        throw ArgumentError.value(entry.index, 'index', '条目编号必须为 1 到 99');
      }
      if (!indexes.add(entry.index)) {
        throw ArgumentError.value(entry.index, 'index', '条目编号不能重复');
      }
      if (entry.intervalMs < minMultiSendIntervalMs ||
          entry.intervalMs > maxMultiSendIntervalMs) {
        throw ArgumentError.value(
          entry.intervalMs,
          'intervalMs',
          '发送间隔必须在 $minMultiSendIntervalMs 到 '
              '$maxMultiSendIntervalMs ms 之间',
        );
      }
      if (entry.payload.length > maxMultiSendPayloadCharacters) {
        throw ArgumentError.value(
          entry.payload.length,
          'payload',
          '多字符串内容不能超过 $maxMultiSendPayloadCharacters 个字符',
        );
      }
      if (entry.name.length > maxMultiSendNameCharacters) {
        throw ArgumentError.value(
          entry.name.length,
          'name',
          '多字符串名称不能超过 $maxMultiSendNameCharacters 个字符',
        );
      }
      validated.add(entry);
    }
    return List<MultiSendEntry>.unmodifiable(validated);
  }

  static List<MultiSendEntry> _sanitizeInitialEntries(
    List<MultiSendEntry> entries,
  ) {
    final indexes = <int>{};
    final result = <MultiSendEntry>[];
    for (final entry in entries.take(maxMultiSendEntries)) {
      if (entry.index < 1 ||
          entry.index > maxMultiSendEntries ||
          !indexes.add(entry.index)) {
        continue;
      }
      result.add(
        entry.copyWith(
          payload: entry.payload.length > maxMultiSendPayloadCharacters
              ? entry.payload.substring(0, maxMultiSendPayloadCharacters)
              : entry.payload,
          name: entry.name.length > maxMultiSendNameCharacters
              ? entry.name.substring(0, maxMultiSendNameCharacters)
              : entry.name,
          intervalMs: entry.intervalMs
              .clamp(minMultiSendIntervalMs, maxMultiSendIntervalMs)
              .toInt(),
        ),
      );
    }
    return List<MultiSendEntry>.unmodifiable(result);
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('MultiSendController 已销毁');
    }
  }
}
