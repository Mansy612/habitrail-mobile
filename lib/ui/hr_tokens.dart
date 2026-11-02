// Habitrail design tokens — mirrors the "Habitrail" design system (tokens.json).
// Replaces the k* palette in core.dart. Accent tokens are mutable so the
// Appearance themes can swap them at runtime (same pattern as applyThemeColors).
import 'package:flutter/material.dart';

/// The app's single type family (bundled in assets/fonts, set in the theme).
const kHrFont = 'Nunito';

abstract final class HrColors {
  // Navy-black night sky with glassy navy cards (sampled from the references).
  static const bg = Color(0xFF0A0B12);
  static const surface = Color(0xFF121624);
  static const surface2 = Color(0xFF181C2E);
  static const surface3 = Color(0xFF262A40);
  static const hairline = Color(0x2E8E8AC2);
  static const cardEdge = Color(0xFF22263F);
  static const cardTop = Color(0xF0161A2A);
  static const cardBottom = Color(0xF0101320);
  static const controlBorder = Color(0xFF5A5C78);

  static const text = Color(0xFFFFFFFF);
  static const text2 = Color(0xFFB0B2CC);
  static const text3 = Color(0xFF7A7B9D);
  static const textDisabled = Color(0xFF55576F);

  static const btnPrimary = Color(0xFFFFD43B);
  static const btnPrimaryPressed = Color(0xFFF0BF1F);
  static const onBtnPrimary = Color(0xFF17120A);
  static const onAccent = Color(0xFFFFFFFF);

  static const streak = Color(0xFFFFA32B);
  static const streakSurface = Color(0xFF36210E);
  static const onStreak = Color(0xFF000000);
  static const gold = Color(0xFFFFD43B);
  static const goldBright = Color(0xFFFFE45C);
  static const goldDeep = Color(0xFFF2AE12);
  static const goldSurface = Color(0xFF2E2509);
  static const xpChip = Color(0xFF0B0C14);
  static const success = Color(0xFF34D399);
  static const lavender = Color(0xFFB9A6FF);
  static const danger = Color(0xFFFF453A);
  static const dangerText = Color(0xFFFF6961);
  static const dangerSurface = Color(0xFF3A1412);
  static const info = Color(0xFF70D6FF);

  static const stickerFill = Color(0xFFFFD60A);
  static const stickerInk = Color(0xFF000000);
  static const stickerOutline = Color(0xFFFFFFFF);
  static const bubble = Color(0xF01A1B2A);
  static const bubbleInk = Color(0xFFF5F2FF);
  static const glass = Color(0xE9141828);
  static const glassEdge = Color(0x3D8170B3);
  static const navBg = Color(0xF70D1018);
  static const scrim = Color(0xB3000000);
  static const focusRing = Color(0xFFC290FE);

  static const rarity = <String, Color>{
    'common': Color(0xFF8E8E93),
    'rare': Color(0xFF61CFFF),
    'epic': Color(0xFFB585FF),
    'legendary': Color(0xFFFFCA35),
    'mythic': Color(0xFFFF6482),
  };

  static Color victory(int score) {
    if (score >= 90) return const Color(0xFFC38BFF); // Elite
    if (score >= 75) return const Color(0xFF30D158); // Great
    if (score >= 60) return const Color(0xFFFFD60A); // Good
    if (score >= 50) return const Color(0xFFFF9F0A); // Fair
    return const Color(0xFFFF6961); // Low
  }

  // ── Themed accent (Appearance) ────────────────────────────────────────────
  static Color accent = const Color(0xFF8D4BFF);
  static Color accentPressed = const Color(0xFF7436EC);
  static Color accentSurface = const Color(0xFF1F1252);

  /// Lighter accent for icons/text and glows on the dark background.
  static Color get accentBright => Color.lerp(accent, Colors.white, 0.32)!;
}

class HrAccentTheme {
  const HrAccentTheme(this.id, this.name, this.accent, this.pressed, this.surface);
  final String id, name;
  final Color accent, pressed, surface;
}

/// The six purchasable themes. 'matrix' (old green) maps to 'rail' on load.
const hrAccentThemes = <HrAccentTheme>[
  HrAccentTheme('rail', 'Rail Green', Color(0xFF30D158), Color(0xFF28B84C), Color(0xFF14301B)),
  HrAccentTheme('violet', 'Habitrail Violet', Color(0xFF8D4BFF), Color(0xFF7436EC), Color(0xFF1F1252)),
  HrAccentTheme('tokyo', 'Neon Tokyo', Color(0xFFFF6EB4), Color(0xFFE85A9F), Color(0xFF3A1729)),
  HrAccentTheme('solar', 'Solar Gold', Color(0xFFFFD60A), Color(0xFFE6C000), Color(0xFF332B07)),
  HrAccentTheme('crimson', 'Crimson', Color(0xFFFF6961), Color(0xFFE8564F), Color(0xFF3A1715)),
  HrAccentTheme('arctic', 'Arctic', Color(0xFF64D2FF), Color(0xFF4DBBE8), Color(0xFF0F2C38)),
  HrAccentTheme('nebula', 'Nebula', Color(0xFFE056FD), Color(0xFFC13FE0), Color(0xFF2A123A)),
];

void hrApplyAccent(String id) {
  final key = id == 'matrix' ? 'rail' : id;
  final t = hrAccentThemes.firstWhere((t) => t.id == key, orElse: () => hrAccentThemes.first);
  HrColors.accent = t.accent;
  HrColors.accentPressed = t.pressed;
  HrColors.accentSurface = t.surface;
}

abstract final class HrSpace {
  static const s2 = 2.0, s4 = 4.0, s8 = 8.0, s12 = 12.0, s16 = 16.0, s20 = 20.0, s24 = 24.0, s32 = 32.0, s48 = 48.0;
  static const gutter = s20;
}

abstract final class HrRadius {
  static const xs = 6.0, sm = 10.0, md = 14.0, lg = 18.0, xl = 26.0, full = 999.0;
}

abstract final class HrShadow {
  static const float = [BoxShadow(color: Color(0x99000000), blurRadius: 40, offset: Offset(0, 16))];
  static const sticker = [BoxShadow(color: Color(0x73000000), blurRadius: 0, offset: Offset(0, 4))];
}

abstract final class HrMotion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const enter = Duration(milliseconds: 320);
  static const fill = Duration(milliseconds: 480);
  static const standard = Cubic(0.2, 0, 0, 1);
  static const spring = Curves.easeOutBack;

  /// Respect the OS reduced-motion setting.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;
}

/// Type scale — one rounded family (Nunito), heavy titles like the references.
abstract final class HrText {
  static const _f = FontFeature.tabularFigures();
  static const displayXl = TextStyle(fontFamily: kHrFont, fontSize: 40, height: 44 / 40, fontWeight: FontWeight.w900, letterSpacing: -0.8, color: HrColors.text);
  static const display = TextStyle(fontFamily: kHrFont, fontSize: 34, height: 40 / 34, fontWeight: FontWeight.w900, letterSpacing: -0.5, color: HrColors.text);
  static const title1 = TextStyle(fontFamily: kHrFont, fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w900, letterSpacing: -0.3, color: HrColors.text);
  static const title2 = TextStyle(fontFamily: kHrFont, fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w800, letterSpacing: -0.2, color: HrColors.text);
  static const headline = TextStyle(fontFamily: kHrFont, fontSize: 17, height: 22 / 17, fontWeight: FontWeight.w800, color: HrColors.text);
  static const body = TextStyle(fontFamily: kHrFont, fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, color: HrColors.text);
  static const bodyS = TextStyle(fontFamily: kHrFont, fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600, color: HrColors.text2);
  static const caption = TextStyle(fontFamily: kHrFont, fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w600, color: HrColors.text3);
  static const labelCaps = TextStyle(fontFamily: kHrFont, fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: HrColors.text3);
  static const micro = TextStyle(fontFamily: kHrFont, fontSize: 11, height: 14 / 11, fontWeight: FontWeight.w700, color: HrColors.text3);
  static const numeralXl = TextStyle(fontFamily: kHrFont, fontSize: 64, height: 1, fontWeight: FontWeight.w900, letterSpacing: -1.5, color: HrColors.text, fontFeatures: [_f]);
  static const stat = TextStyle(fontFamily: kHrFont, fontSize: 26, height: 30 / 26, fontWeight: FontWeight.w900, letterSpacing: -0.3, color: HrColors.text, fontFeatures: [_f]);
  static const sticker = TextStyle(fontFamily: kHrFont, fontSize: 30, height: 1, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, letterSpacing: -0.5, fontFeatures: [_f]);
}
