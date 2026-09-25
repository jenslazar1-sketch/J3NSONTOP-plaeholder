import 'package:flutter/material.dart';

import 'j3_colors.dart';
import 'j3_spacing.dart';
import 'j3_typography.dart';

/// Builds the dark red/black Material theme for an accent preset.
abstract final class J3Theme {
  static ThemeData build(AccentPreset accent) {
    final a = accent.accent;
    final scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: a,
      onPrimary: J3Colors.background,
      primaryContainer: accent.accentDeep,
      onPrimaryContainer: J3Colors.text,
      secondary: accent.accentText,
      onSecondary: J3Colors.background,
      secondaryContainer: J3Colors.selection,
      onSecondaryContainer: J3Colors.text,
      tertiary: J3Colors.info,
      onTertiary: J3Colors.background,
      error: J3Colors.error,
      onError: J3Colors.background,
      errorContainer: const Color(0xFF3A0A12),
      onErrorContainer: J3Colors.text,
      surface: J3Colors.surface,
      onSurface: J3Colors.text,
      onSurfaceVariant: J3Colors.textSecondary,
      surfaceContainerLowest: J3Colors.background,
      surfaceContainerLow: J3Colors.inputFill,
      surfaceContainer: J3Colors.surface,
      surfaceContainerHigh: J3Colors.surfaceRaised,
      surfaceContainerHighest: J3Colors.surfaceHigh,
      outline: J3Colors.borderStrong,
      outlineVariant: J3Colors.border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: J3Colors.text,
      onInverseSurface: J3Colors.background,
      inversePrimary: accent.accentDeep,
    );

    const textTheme = TextTheme(
      displayLarge: J3Type.display,
      displayMedium: J3Type.display,
      displaySmall: J3Type.headline,
      headlineLarge: J3Type.headline,
      headlineMedium: J3Type.headline,
      headlineSmall: J3Type.title,
      titleLarge: J3Type.title,
      titleMedium: J3Type.subtitle,
      titleSmall: J3Type.label,
      bodyLarge: J3Type.body,
      bodyMedium: J3Type.body,
      bodySmall: J3Type.bodySecondary,
      labelLarge: J3Type.label,
      labelMedium: J3Type.caption,
      labelSmall: J3Type.caption,
    );

    OutlineInputBorder outline(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: J3Radius.medium,
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: J3Colors.background,
      canvasColor: J3Colors.background,
      fontFamily: J3Type.ui,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      splashFactory: InkRipple.splashFactory,
      focusColor: a.withValues(alpha: 0.22),
      hoverColor: a.withValues(alpha: 0.08),
      highlightColor: a.withValues(alpha: 0.12),
      splashColor: a.withValues(alpha: 0.16),
      dividerColor: J3Colors.border,
      dividerTheme: const DividerThemeData(color: J3Colors.border, thickness: 1, space: 1),
      iconTheme: const IconThemeData(color: J3Colors.textSecondary, size: 20),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: a,
        selectionColor: a.withValues(alpha: 0.35),
        selectionHandleColor: a,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: J3Colors.inputFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        labelStyle: J3Type.bodySecondary,
        floatingLabelStyle: J3Type.caption.copyWith(color: accent.accentText),
        hintStyle: J3Type.bodySecondary.copyWith(color: J3Colors.textMuted),
        helperStyle: J3Type.caption,
        errorStyle: J3Type.caption.copyWith(color: J3Colors.error),
        errorMaxLines: 4,
        border: outline(J3Colors.border),
        enabledBorder: outline(J3Colors.border),
        focusedBorder: outline(a, 1.6),
        errorBorder: outline(J3Colors.error),
        focusedErrorBorder: outline(J3Colors.error, 1.6),
        disabledBorder: outline(J3Colors.border.withValues(alpha: 0.5)),
      ),
      cardTheme: const CardThemeData(
        color: J3Colors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: J3Radius.medium,
          side: BorderSide(color: J3Colors.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: J3Colors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: J3Radius.large,
          side: BorderSide(color: a.withValues(alpha: 0.6)),
        ),
        titleTextStyle: J3Type.title,
        contentTextStyle: J3Type.body,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: J3Colors.surface,
        modalBackgroundColor: J3Colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          side: BorderSide(color: a.withValues(alpha: 0.5)),
        ),
        showDragHandle: true,
        dragHandleColor: J3Colors.borderStrong,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: J3Colors.surfaceRaised,
        contentTextStyle: J3Type.body,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: J3Radius.medium,
          side: BorderSide(color: a.withValues(alpha: 0.6)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: J3Colors.surfaceHigh,
          borderRadius: J3Radius.small,
          border: Border.all(color: a.withValues(alpha: 0.5)),
        ),
        textStyle: J3Type.caption.copyWith(color: J3Colors.text),
        waitDuration: const Duration(milliseconds: 450),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged)
              ? a.withValues(alpha: 0.8)
              : J3Colors.borderStrong,
        ),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? J3Colors.text : J3Colors.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent.accentDeep : J3Colors.surfaceHigh,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? a : J3Colors.borderStrong,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent.accentDeep : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(J3Colors.text),
        side: WidgetStateBorderSide.resolveWith(
          (s) => BorderSide(color: s.contains(WidgetState.selected) ? a : J3Colors.borderStrong, width: 1.5),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? a : J3Colors.borderStrong),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: a,
        inactiveTrackColor: J3Colors.surfaceHigh,
        thumbColor: J3Colors.text,
        overlayColor: a.withValues(alpha: 0.2),
        valueIndicatorColor: accent.accentDeep,
        valueIndicatorTextStyle: J3Type.caption.copyWith(color: J3Colors.text),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: a,
        linearTrackColor: J3Colors.surfaceHigh,
        circularTrackColor: J3Colors.surfaceHigh,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: J3Colors.surfaceRaised,
        selectedColor: accent.accentDeep,
        disabledColor: J3Colors.surface,
        labelStyle: J3Type.caption.copyWith(color: J3Colors.text),
        secondaryLabelStyle: J3Type.caption.copyWith(color: J3Colors.text),
        side: const BorderSide(color: J3Colors.border),
        checkmarkColor: J3Colors.text,
        shape: const RoundedRectangleBorder(borderRadius: J3Radius.small),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accent.accentDeep : J3Colors.inputFill,
          ),
          foregroundColor: const WidgetStatePropertyAll(J3Colors.text),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(color: s.contains(WidgetState.selected) ? a : J3Colors.border),
          ),
          textStyle: const WidgetStatePropertyAll(J3Type.label),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: J3Radius.medium)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent.accentDeep,
          foregroundColor: J3Colors.text,
          disabledBackgroundColor: J3Colors.surfaceHigh,
          disabledForegroundColor: J3Colors.textDisabled,
          minimumSize: const Size(48, 44),
          textStyle: J3Type.label,
          shape: RoundedRectangleBorder(
            borderRadius: J3Radius.medium,
            side: BorderSide(color: a),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: J3Colors.text,
          minimumSize: const Size(48, 44),
          textStyle: J3Type.label,
          side: const BorderSide(color: J3Colors.borderStrong),
          shape: const RoundedRectangleBorder(borderRadius: J3Radius.medium),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent.accentText,
          minimumSize: const Size(48, 40),
          textStyle: J3Type.label,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: J3Colors.textSecondary,
          minimumSize: const Size(44, 44),
          hoverColor: a.withValues(alpha: 0.1),
          focusColor: a.withValues(alpha: 0.25),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: J3Colors.surfaceRaised,
        textStyle: J3Type.body,
        shape: RoundedRectangleBorder(
          borderRadius: J3Radius.medium,
          side: BorderSide(color: a.withValues(alpha: 0.5)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: J3Colors.textSecondary,
        textColor: J3Colors.text,
        selectedColor: accent.accentText,
        selectedTileColor: J3Colors.selection,
        titleTextStyle: J3Type.body,
        subtitleTextStyle: J3Type.caption,
        shape: const RoundedRectangleBorder(borderRadius: J3Radius.medium),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: J3Colors.text,
        unselectedLabelColor: J3Colors.textMuted,
        labelStyle: J3Type.label,
        unselectedLabelStyle: J3Type.label,
        indicatorColor: a,
        dividerColor: J3Colors.border,
        indicatorSize: TabBarIndicatorSize.label,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: J3Colors.surface,
        indicatorColor: accent.accentDeep,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => J3Type.caption.copyWith(color: s.contains(WidgetState.selected) ? J3Colors.text : J3Colors.textMuted),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? J3Colors.text : J3Colors.textMuted),
        ),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: J3Colors.surface, surfaceTintColor: Colors.transparent),
      appBarTheme: const AppBarTheme(
        backgroundColor: J3Colors.background,
        foregroundColor: J3Colors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: J3Type.title,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: J3Colors.textSecondary,
        collapsedIconColor: J3Colors.textMuted,
        textColor: J3Colors.text,
        collapsedTextColor: J3Colors.text,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: J3Type.label.copyWith(color: accent.accentText),
        dataTextStyle: J3Type.code,
        dividerThickness: 1,
        headingRowColor: const WidgetStatePropertyAll(J3Colors.surfaceRaised),
      ),
    );
  }
}
