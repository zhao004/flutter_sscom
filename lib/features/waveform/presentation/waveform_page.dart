import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';

import '../application/waveform_controller.dart';
import '../domain/waveform_buffer.dart';

/// 独立波形页面。
///
/// 页面只消费 [WaveformController] 的降采样快照；终端仍在后台接收数据，波形
/// 暂停、清空或页面退出都不会改变终端和接收日志状态。
class WaveformPage extends StatelessWidget {
  /// 创建波形页面。
  const WaveformPage({super.key, required this.controller});

  /// 波形控制器。
  final WaveformController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('波形'),
        actions: <Widget>[
          SignalBuilder(
            builder: (context) {
              final paused = controller.state.value.isPaused;
              return TextButton.icon(
                onPressed: () => controller.setPaused(!paused),
                icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                label: Text(paused ? '继续' : '暂停'),
              );
            },
          ),
          IconButton(
            tooltip: '清空波形',
            onPressed: controller.clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SignalBuilder(
            builder: (context) {
              final state = controller.state.value;
              return Card(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: Row(
                        children: <Widget>[
                          const Text('原始字节 0–255'),
                          const SizedBox(width: 12),
                          Chip(
                            avatar: Icon(
                              state.isPaused
                                  ? Icons.pause_circle_outline
                                  : Icons.circle,
                              size: 16,
                              color: state.isPaused
                                  ? Theme.of(context).colorScheme.tertiary
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            label: Text(state.isPaused ? '已暂停' : '实时'),
                            visualDensity: VisualDensity.compact,
                          ),
                          const Spacer(),
                          if (state.discardedSamples > 0)
                            Text(
                              '窗口已裁剪 ${state.discardedSamples} 个旧样本',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _WaveformPainter(
                              buckets: state.buckets,
                              lineColor: Theme.of(context).colorScheme.primary,
                              rangeColor: Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.24),
                              gridColor: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                              textColor: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              textStyle: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!state.hasSamples)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text(
                          '等待接收数据',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                      child: Wrap(
                        spacing: 24,
                        runSpacing: 6,
                        children: <Widget>[
                          Text('累计 ${state.totalSamples} 个样本'),
                          Text('窗口 ${state.windowSamples} 个样本'),
                          Text('绘制 ${state.buckets.length} 个区间'),
                          Text('最新 ${state.latestSample ?? '-'}'),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.buckets,
    required this.lineColor,
    required this.rangeColor,
    required this.gridColor,
    required this.textColor,
    required this.textStyle,
  });

  final List<WaveformBucket> buckets;
  final Color lineColor;
  final Color rangeColor;
  final Color gridColor;
  final Color textColor;
  final TextStyle? textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const horizontalLabelWidth = 34.0;
    const verticalPadding = 8.0;
    final plotRect = Rect.fromLTWH(
      horizontalLabelWidth,
      verticalPadding,
      math.max(0, size.width - horizontalLabelWidth - 4),
      math.max(0, size.height - verticalPadding * 2),
    );
    if (plotRect.width <= 0 || plotRect.height <= 0) {
      return;
    }

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final y = plotRect.top + plotRect.height * index / 4;
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );
    }
    _paintLabel(canvas, '255', Offset(0, plotRect.top - 6));
    _paintLabel(canvas, '0', Offset(10, plotRect.bottom - 8));

    if (buckets.isEmpty) {
      return;
    }

    final rangePaint = Paint()
      ..color = rangeColor
      ..strokeWidth = 1;
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var index = 0; index < buckets.length; index++) {
      final bucket = buckets[index];
      final x = buckets.length == 1
          ? plotRect.center.dx
          : plotRect.left + plotRect.width * index / (buckets.length - 1);
      final minY = _valueToY(bucket.minimum, plotRect);
      final maxY = _valueToY(bucket.maximum, plotRect);
      canvas.drawLine(Offset(x, minY), Offset(x, maxY), rangePaint);
      final y = _valueToY(bucket.last, plotRect);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);
    if (buckets.length == 1) {
      final x = plotRect.center.dx;
      final y = _valueToY(buckets.single.last, plotRect);
      canvas.drawCircle(Offset(x, y), 2.4, Paint()..color = lineColor);
    }
  }

  double _valueToY(int value, Rect rect) {
    return rect.bottom - rect.height * value.clamp(0, 255) / 255;
  }

  void _paintLabel(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: (textStyle ?? const TextStyle()).copyWith(color: textColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return !identical(oldDelegate.buckets, buckets) ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.rangeColor != rangeColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.textStyle != textStyle;
  }
}
