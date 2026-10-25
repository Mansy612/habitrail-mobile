// ThemeData for the redesign. Drop-in replacement for the theme in HabitrailApp.
// Usage:  theme: hrTheme(),   and remove the `builder:` that stacks _ParticleBackground.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'hr_tokens.dart';

ThemeData hrTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  final text = GoogleFonts.plusJakartaSansTextTheme(base.textTheme)
      .apply(bodyColor: HrColors.text, displayColor: HrColors.text);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(HrRadius.full));
  return base.copyWith(
    scaffoldBackgroundColor: HrColors.bg,
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
    splashFactory: NoSplash.splashFactory, // press feedback is scale + fill, not ink ripples
    highlightColor: Colors.transparent,
    pageTransitionsTheme: base.pageTransitionsTheme, // keep _FadeSlidePageTransitionsBuilder here
    appBarTheme: AppBarTheme(
      backgroundColor: HrColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: GoogleFonts.plusJakartaSans(textStyle: HrText.headline),
      foregroundColor: HrColors.text,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HrColors.btnPrimary,
        foregroundColor: HrColors.onBtnPrimary,
        disabledBackgroundColor: HrColors.surface2,
        disabledForegroundColor: HrColors.textDisabled,
        minimumSize: const Size(64, 52),
        shape: pill,
        textStyle: GoogleFonts.plusJakartaSans(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: HrColors.text2, shape: pill,
          textStyle: GoogleFonts.plusJakartaSans(fontSize: 15, fontWeight: FontWeight.w600)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: HrColors.surface2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      hintStyle: const TextStyle(color: HrColors.text3),
      labelStyle: const TextStyle(color: HrColors.text2),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(HrRadius.md), borderSide: const BorderSide(color: HrColors.text, width: 1.5)),
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
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? HrColors.accent : HrColors.surface3),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: HrColors.accent, linearTrackColor: HrColors.surface3, circularTrackColor: HrColors.surface3),
    dividerTheme: const DividerThemeData(color: HrColors.hairline, thickness: 1, space: 1),
    focusColor: HrColors.focusRing.withValues(alpha: 0.12),
  );
}
