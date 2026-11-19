import 'package:flutter/material.dart';

/// 浅蓝工作区的语义颜色与尺寸，集中维护控件视觉约定。
abstract final class SscomTheme {
  static const background = Color(0xFFF0F5FF);
  static const surface = Color(0xFFF9FBFF);
  static const border = Color(0xFFDCE6F6);
  static const ink = Color(0xFF203253);
  static const muted = Color(0xFF8190AC);
  static const blue = Color(0xFF4A96F4);
  static const radius = 16.0;

  /// 工作区内容区的最小逻辑像素高度，为终端保留可阅读的空间。
  static const serialWorkspaceMinHeight = 560.0;
  static const networkWorkspaceMinHeight = 680.0;

  /// 每条提示预留的逻辑像素高度，防止异常状态挤压接收区。
  static const messageHeightAllowance = 64.0;

  /// 使用系统中文字体回退，避免额外字体下载和桌面文字闪烁。
  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: blue,
          brightness: Brightness.light,
        ).copyWith(
          primary: blue,
          onPrimary: Colors.white,
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: const Color(0xFF586B8C),
          outline: muted,
          outlineVariant: border,
          secondaryContainer: const Color(0xFFE8F1FF),
        );
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: border),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamily: 'Microsoft YaHei',
      fontFamilyFallback: const ['Segoe UI', 'sans-serif'],
      textTheme: const TextTheme(
        bodyMedium: TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: 13,
          color: ink,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: 12,
          color: muted,
        ),
        titleSmall: TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF8FAFF),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: outline,
        enabledBorder: outline,
        disabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: const BorderSide(color: blue, width: 1.5),
        ),
        hintStyle: const TextStyle(
          fontFamily: 'Microsoft YaHei',
          color: muted,
          fontSize: 13,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(100, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: surface,
          side: const BorderSide(color: border),
          minimumSize: const Size(80, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          textStyle: const TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: ink, iconSize: 21),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: const BorderSide(color: muted, width: 1.4),
        visualDensity: VisualDensity.compact,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: const Color(0xFFDFECFF),
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: const TextStyle(
          fontFamily: 'Microsoft YaHei',
          color: ink,
          fontSize: 13,
        ),
      ),
      dividerColor: border,
    );
  }
}

/// 带轻阴影的工作区面板，保留浅色底面的边界与层次。
class WorkspaceSurface extends StatelessWidget {
  const WorkspaceSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: SscomTheme.surface,
      borderRadius: BorderRadius.circular(SscomTheme.radius),
      border: Border.all(color: SscomTheme.border),
      boxShadow: const [
        BoxShadow(
          color: Color(0x086A94CE),
          blurRadius: 6,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: child,
  );
}

/// 等宽分段选择器，使用原生按钮保留键盘导航及选中语义。
class WorkspaceSegments<T> extends StatelessWidget {
  const WorkspaceSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<T>(
    segments: segments,
    selected: {selected},
    showSelectedIcon: false,
    onSelectionChanged: onChanged == null
        ? null
        : (values) => onChanged!(values.single),
    style: ButtonStyle(
      visualDensity: VisualDensity.compact,
      minimumSize: const WidgetStatePropertyAll(Size(84, 40)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 18),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      side: const WidgetStatePropertyAll(BorderSide(color: SscomTheme.border)),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Color(0xFF78ADF3)
            : const Color(0xFFF5F8FE),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : SscomTheme.ink,
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// 可点击文字标签扩大复选项命中区域，并保留原生焦点反馈。
class WorkspaceCheck extends StatelessWidget {
  const WorkspaceCheck({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onChanged == null ? null : () => onChanged!(!value),
    borderRadius: BorderRadius.circular(6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false),
        ),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 13,
            color: onChanged == null ? SscomTheme.muted : SscomTheme.ink,
          ),
        ),
        const SizedBox(width: 6),
      ],
    ),
  );
}

/// 设置标签独立于输入框，避免密集连接参数的悬浮标签挤占内容。
class WorkspaceField extends StatelessWidget {
  const WorkspaceField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(
          fontFamily: 'Microsoft YaHei',
          fontSize: 12,
          color: SscomTheme.ink,
        ),
      ),
      const SizedBox(height: 5),
      child,
    ],
  );
}

/// 编辑框右上角的固定浮动提示；校验状态不参与输入框高度计算。
///
/// 标签使用面板底色遮住上边框，预留顶部空间，避免覆盖输入文字或挤动相邻控件。
class WorkspaceInputHint extends StatelessWidget {
  const WorkspaceInputHint({
    super.key,
    required this.label,
    required this.child,
    this.errorText,
  });

  final String label;
  final String? errorText;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = errorText == null
        ? SscomTheme.ink
        : Theme.of(context).colorScheme.error;
    return Stack(
      children: [
        Padding(padding: const EdgeInsets.only(top: 10), child: child),
        Positioned(
          top: 0,
          left: 8,
          right: 8,
          child: Align(
            alignment: Alignment.topRight,
            child: ColoredBox(
              color: SscomTheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: color),
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: errorText!,
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 13,
                          color: color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
