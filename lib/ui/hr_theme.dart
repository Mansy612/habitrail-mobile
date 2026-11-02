// Shared dark, 3D-inspired theme for every route. The ambient backdrop is
// layered behind the navigator in HabitrailApp's builder.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'hr_tokens.dart';

ThemeData hrTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final text = GoogleFonts.plusJakartaSansTextTheme(base.textTheme)
      .apply(bodyColor: HrColors.text, displayColor: HrColors.text);
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HrRadius.md));
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: HrColors.bg,
    colorScheme: ColorScheme.dark(
      surface: HrColors.surface,
      primary: HrColors.accent,
      onPrimary: HrColors.onAccent,
      secondary: HrColors.accent,
      error: HrColors.danger,
      onSurface: HrColors.text,
    ),
    textTheme: text,
    cardTheme: CardThemeData(
      color: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 7,
      margin: EdgeInsets.zero,
      shadowColor: Colors.black.withValues(alpha: 0.48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.lg),
        side: const BorderSide(color: HrColors.cardEdge, width: 0.8),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: HrColors.text2,
      textColor: HrColors.text,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: HrColors.surface2,
      surfaceTintColor: Colors.transparent,
      textStyle: GoogleFonts.plusJakartaSans(color: HrColors.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HrRadius.md),
        side: const BorderSide(color: HrColors.cardEdge),
      ),
    ),
    splashFactory: NoSplash.splashFactory, // press feedback is scale + fill, not ink ripples
    highlightColor: Colors.transparent,
    pageTransitionsTheme: base.pageTransitionsTheme, // keep _FadeSlidePageTransitionsBuilder here
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.plusJakartaSans(textStyle: HrText.title1),
      foregroundColor: HrColors.text,
      iconTheme: const IconThemeData(color: HrColors.text2),
      actionsIconTheme: IconThemeData(color: HrColors.accent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HrColors.btnPrimary,
        foregroundColor: HrColors.onBtnPrimary,
        disabledBackgroundColor: HrColors.surface2,
        disabledForegroundColor: HrColors.textDisabled,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: HrColors.text2, shape: buttonShape,
          textStyle: GoogleFonts.plusJakartaSans(fontSize: 15, fontWeight: FontWeight.w600)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HrColors.surface2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      hintStyle: const TextStyle(color: HrColors.text3),
      labelStyle: const TextStyle(color: HrColors.text2),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: BorderSide(color: HrColors.cardEdge.withValues(alpha: 0.5), width: 0.8)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: BorderSide(color: HrColors.accent, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.danger, width: 1.5)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.danger, width: 1.5)),
      errorStyle: const TextStyle(color: HrColors.dangerText, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(HrRadius.xl)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: HrColors.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: HrColors.scrim,
      showDragHandle: true,
      dragHandleColor: HrColors.surface3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(HrRadius.xl))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: HrColors.surface2,
      contentTextStyle: GoogleFonts.plusJakartaSans(color: HrColors.text, fontWeight: FontWeight.w700, fontSize: 14),
      actionTextColor: HrColors.accent,
      shape: const StadiumBorder(),
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
          s.contains(WidgetState.selected) ? HrColors.accent : HrColors.text3),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: HrColors.gold,
      inactiveTrackColor: HrColors.surface3,
      thumbColor: HrColors.gold,
      overlayColor: HrColors.gold.withValues(alpha: 0.13),
      trackHeight: 4,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: HrColors.accent, linearTrackColor: HrColors.surface3, circularTrackColor: HrColors.surface3),
    dividerTheme: const DividerThemeData(color: HrColors.hairline, thickness: 1, space: 1),
    focusColor: HrColors.focusRing.withValues(alpha: 0.12),
  );
}
