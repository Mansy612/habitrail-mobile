// Shared dark, 3D-inspired theme for every route. The ambient backdrop is
// layered behind the navigator in HabitrailApp's builder.
import 'package:flutter/material.dart';
import 'hr_tokens.dart';

ThemeData hrTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: kHrFont,
  );
  final text = base.textTheme
      .apply(bodyColor: HrColors.text, displayColor: HrColors.text, fontFamily: kHrFont)
      .copyWith(
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
      );
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HrRadius.md));
  const ui = TextStyle(fontFamily: kHrFont);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: HrColors.bg,
    colorScheme: ColorScheme.dark(
      surface: HrColors.surface,
      primary: HrColors.accent,
      onPrimary: HrColors.onAccent,
      secondary: HrColors.gold,
      onSecondary: HrColors.onBtnPrimary,
      error: HrColors.danger,
      onSurface: HrColors.text,
    ),
    textTheme: text,
    cardTheme: CardThemeData(
      color: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.lg),
        side: const BorderSide(color: HrColors.cardEdge),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: HrColors.text2,
      textColor: HrColors.text,
      titleTextStyle: ui.copyWith(fontSize: 16, fontWeight: FontWeight.w700, color: HrColors.text),
      subtitleTextStyle: ui.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: HrColors.text3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: HrColors.surface2,
      surfaceTintColor: Colors.transparent,
      textStyle: ui.copyWith(color: HrColors.text, fontWeight: FontWeight.w700),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        side: const BorderSide(color: HrColors.cardEdge),
      ),
    ),
    splashFactory: NoSplash.splashFactory, // press feedback is scale + fill, not ink ripples
    highlightColor: Colors.transparent,
    pageTransitionsTheme: base.pageTransitionsTheme, // keep _FadeSlidePageTransitionsBuilder here
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const Icon(Icons.chevron_left_rounded, size: 32),
      closeButtonIconBuilder: (_) => const Icon(Icons.close_rounded, size: 26),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 66,
      titleSpacing: 4,
      titleTextStyle: HrText.title1,
      foregroundColor: HrColors.text,
      iconTheme: const IconThemeData(color: HrColors.text),
      actionsIconTheme: const IconThemeData(color: HrColors.text2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HrColors.accent,
        foregroundColor: HrColors.onAccent,
        disabledBackgroundColor: HrColors.surface2,
        disabledForegroundColor: HrColors.textDisabled,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: ui.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: HrColors.btnPrimary,
        foregroundColor: HrColors.onBtnPrimary,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        elevation: 0,
        textStyle: ui.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: HrColors.text,
        backgroundColor: HrColors.surface,
        minimumSize: const Size(64, 48),
        side: const BorderSide(color: HrColors.cardEdge),
        shape: buttonShape,
        textStyle: ui.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: HrColors.accentBright, shape: buttonShape,
          textStyle: ui.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: HrColors.text2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HrColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      hintStyle: ui.copyWith(color: HrColors.text3, fontWeight: FontWeight.w600),
      labelStyle: ui.copyWith(color: HrColors.text2, fontWeight: FontWeight.w600),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.cardEdge)),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.cardEdge)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: BorderSide(color: HrColors.accent, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.danger, width: 1.5)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.danger, width: 1.5)),
      errorStyle: ui.copyWith(color: HrColors.dangerText, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: HrText.title2,
      contentTextStyle: HrText.bodyS,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.xl),
        side: const BorderSide(color: HrColors.cardEdge),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: HrColors.scrim,
      showDragHandle: true,
      dragHandleColor: HrColors.surface3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl)),
        side: BorderSide(color: HrColors.cardEdge),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: HrColors.surface2,
      contentTextStyle: ui.copyWith(color: HrColors.text, fontWeight: FontWeight.w700, fontSize: 14),
      actionTextColor: HrColors.gold,
      shape: const StadiumBorder(side: BorderSide(color: HrColors.cardEdge)),
      insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(HrColors.text),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HrColors.gold : HrColors.surface3),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? HrColors.gold : HrColors.surface2),
      checkColor: const WidgetStatePropertyAll(HrColors.onBtnPrimary),
      side: const BorderSide(color: HrColors.controlBorder, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? HrColors.gold : HrColors.text3),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: HrColors.surface,
      selectedColor: HrColors.accent,
      side: const BorderSide(color: HrColors.cardEdge),
      shape: const StadiumBorder(),
      labelStyle: ui.copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: HrColors.text2),
      secondaryLabelStyle: ui.copyWith(fontSize: 13, fontWeight: FontWeight.w700, color: HrColors.text),
      checkmarkColor: HrColors.text,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: HrColors.gold,
      inactiveTrackColor: HrColors.surface3,
      thumbColor: HrColors.gold,
      overlayColor: HrColors.gold.withValues(alpha: 0.13),
      trackHeight: 6,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: HrColors.text,
      unselectedLabelColor: HrColors.text3,
      indicatorColor: HrColors.accent,
      dividerColor: Colors.transparent,
      labelStyle: ui.copyWith(fontSize: 14, fontWeight: FontWeight.w800),
      unselectedLabelStyle: ui.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: HrColors.accent, linearTrackColor: HrColors.surface3, circularTrackColor: HrColors.surface3),
    dividerTheme: const DividerThemeData(color: HrColors.hairline, thickness: 1, space: 1),
    focusColor: HrColors.focusRing.withValues(alpha: 0.12),
  );
}
