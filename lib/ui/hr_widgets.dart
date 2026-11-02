// Habitrail core widgets — Flutter implementations of the design-system components.
// Each class names the old widget it replaces in lib/main.dart.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'hr_tokens.dart';

/// A static night-sky backdrop shared by every app page.
class HrAmbientBackdrop extends StatelessWidget {
  const HrAmbientBackdrop({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(
    painter: _HrAmbientBackdropPainter(),
    size: Size.infinite,
  );
}

/// Full-body brand mascot art for hero areas and focus screens.
class HrMascotArtwork extends StatelessWidget {
  const HrMascotArtwork({
    this.width = 180,
    this.height = 220,
    this.opacity = 1,
    super.key,
  });

  final double width;
  final double height;
  final double opacity;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Opacity(
        opacity: opacity,
        child: Image.asset(
          'assets/mascot/habit_trail_mascot.png',
          width: width,
          height: height,
          fit: BoxFit.contain,
          cacheWidth: (width * 2).round(),
          filterQuality: FilterQuality.medium,
        ),
      ),
    ),
  );
}

/// Header illustration: the mascot (or any art) on a soft violet glow with gold
/// sparkles and violet pixel stars, like the reference page headers.
class HrHeroArt extends StatelessWidget {
  const HrHeroArt({
    this.width = 150,
    this.height = 170,
    this.child,
    this.glow = true,
    super.key,
  });
  final double width, height;
  final Widget? child;
  final bool glow;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (glow)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.62,
                    colors: [
                      HrColors.accent.withValues(alpha: 0.30),
                      HrColors.accent.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          Positioned.fill(child: CustomPaint(painter: _SparklesPainter())),
          child ?? HrMascotArtwork(width: width * 0.86, height: height * 0.92),
        ],
      ),
    ),
  );
}

/// Consistent secondary-page heading: a heavy title (and optional subtitle)
/// with the brand mascot at the right edge.
class HrAppBarTitle extends StatelessWidget {
  const HrAppBarTitle(this.label, {this.subtitle, this.art = true, super.key});

  final String label;
  final String? subtitle;
  final bool art;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HrText.title1.copyWith(fontSize: 26),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HrText.caption.copyWith(color: HrColors.text2),
              ),
          ],
        ),
      ),
      if (art) const HrHeroArt(width: 58, height: 60),
    ],
  );
}

/// Large page header for tab roots and full-bleed pages: a heavy title, a
/// subtitle, optional trailing actions and hero art in the top-right corner.
class HrPageHeader extends StatelessWidget {
  const HrPageHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    this.art,
    this.artWidth = 140,
    this.artHeight = 150,
    this.showBack = false,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? art;
  final double artWidth, artHeight;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final hasArt = art != null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (hasArt)
          Positioned(
            right: 4,
            top: -10,
            child: SizedBox(width: artWidth, height: artHeight, child: art),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            HrSpace.gutter,
            showBack ? 0 : 10,
            HrSpace.gutter,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showBack)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left_rounded, size: 32, color: HrColors.text),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: hasArt ? artWidth - 30 : 0),
                      child: Text(title, style: HrText.display),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: EdgeInsets.only(right: hasArt ? artWidth - 40 : 0),
                  child: Text(
                    subtitle!,
                    style: HrText.bodyS.copyWith(fontSize: 15, color: HrColors.text2),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Round icon button used in page headers (settings gear, add, share).
class HrHeaderButton extends StatelessWidget {
  const HrHeaderButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.badge = false,
    super.key,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final bool badge;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? '',
    child: _Pressable(
      onTap: onPressed,
      scale: 0.92,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: HrColors.surface,
          border: Border.all(color: HrColors.cardEdge),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, size: 22, color: color ?? HrColors.text2),
            if (badge)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: HrColors.gold,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _HrAmbientBackdropPainter extends CustomPainter {
  const _HrAmbientBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0C0C17), Color(0xFF0A0B12), Color(0xFF0B0A14)],
          stops: [0, 0.55, 1],
        ).createShader(bounds),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0.95, -0.9),
          radius: 0.95,
          colors: [Color(0x40532C9E), Color(0x000E0A1E)],
        ).createShader(bounds),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-1.0, 0.85),
          radius: 0.9,
          colors: [Color(0x24452590), Color(0x000A0712)],
        ).createShader(bounds),
    );

    final pixels = <(double, double, double, Color)>[
      (0.10, 0.17, 4, Color(0x997F4CC8)),
      (0.62, 0.05, 3, Color(0x88FFD43B)),
      (0.92, 0.33, 3, Color(0x887C4BD1)),
      (0.16, 0.74, 3, Color(0x667A4CC2)),
      (0.82, 0.66, 4, Color(0x55FFD43B)),
    ];
    for (final (x, y, edge, color) in pixels) {
      final point = Offset(size.width * x, size.height * y);
      canvas.drawRect(
        Rect.fromCenter(center: point, width: edge, height: edge),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HrAmbientBackdropPainter oldDelegate) => false;
}

/// 1234 → "1,234".
String hrNum(num n) {
  final s = n.round().abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// A four-point sparkle (the gold "✦" in the references).
void hrDrawSparkle(Canvas canvas, Offset c, double r, Color color, {bool glow = true}) {
  final p = Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx + r * 0.16, c.dy - r * 0.16, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + r * 0.16, c.dy + r * 0.16, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - r * 0.16, c.dy + r * 0.16, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - r * 0.16, c.dy - r * 0.16, c.dx, c.dy - r)
    ..close();
  if (glow) {
    canvas.drawCircle(
      c,
      r * 1.2,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.9),
    );
  }
  canvas.drawPath(p, Paint()..color = color);
}

class _SparklesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final r = s.shortestSide;
    hrDrawSparkle(canvas, Offset(s.width * 0.96, s.height * 0.10), r * 0.07, HrColors.goldBright);
    hrDrawSparkle(canvas, Offset(s.width * 0.04, s.height * 0.42), r * 0.05, HrColors.gold);
    hrDrawSparkle(canvas, Offset(s.width * 0.9, s.height * 0.78), r * 0.04, HrColors.gold);
    final violet = Paint()..color = const Color(0xCC9B6BFF);
    for (final (x, y, e) in [
      (0.12, 0.16, 0.035),
      (0.18, 0.22, 0.025),
      (0.84, 0.32, 0.03),
      (0.02, 0.70, 0.025),
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: Offset(s.width * x, s.height * y), width: r * e, height: r * e),
        violet,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklesPainter oldDelegate) => false;
}

// ── Button (replaces GradientButton) ────────────────────────────────────────
enum HrButtonKind { primary, accent, secondary, ghost, danger }

class HrButton extends StatefulWidget {
  const HrButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = HrButtonKind.primary,
    this.expand = true,
    this.small = false,
    this.loading = false,
    super.key,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final HrButtonKind kind;
  final bool expand, small, loading;

  @override
  State<HrButton> createState() => _HrButtonState();
}

class _HrButtonState extends State<HrButton> {
  bool _down = false;

  (Color, Color, Color) get _colors => switch (widget.kind) {
    HrButtonKind.primary => (
      HrColors.btnPrimary,
      HrColors.btnPrimaryPressed,
      HrColors.onBtnPrimary,
    ),
    HrButtonKind.accent => (
      HrColors.accent,
      HrColors.accentPressed,
      HrColors.onAccent,
    ),
    HrButtonKind.secondary => (
      HrColors.surface,
      HrColors.surface2,
      HrColors.text,
    ),
    HrButtonKind.ghost => (
      Colors.transparent,
      HrColors.surface2,
      HrColors.text2,
    ),
    HrButtonKind.danger => (
      HrColors.dangerSurface,
      HrColors.dangerSurface,
      HrColors.dangerText,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final (bg, pressed, fg) = _colors;
    final fill = widget.onPressed == null
        ? HrColors.surface2
        : (_down ? pressed : bg);
    final ink = widget.onPressed == null ? HrColors.textDisabled : fg;
    final buttonGradient = widget.onPressed == null
        ? null
        : widget.kind == HrButtonKind.primary
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _down
                ? const [HrColors.btnPrimaryPressed, HrColors.goldDeep]
                : const [HrColors.goldBright, HrColors.btnPrimary, HrColors.goldDeep],
            stops: _down ? null : const [0, 0.55, 1],
          )
        : widget.kind == HrButtonKind.accent
        ? LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Color.lerp(_down ? HrColors.accentPressed : HrColors.accent, Colors.white, 0.12)!,
              _down ? HrColors.accentPressed : HrColors.accent,
              Color.lerp(_down ? HrColors.accentPressed : HrColors.accent, Colors.white, 0.08)!,
            ],
          )
        : null;
    final h = widget.small
        ? 38.0
        : (widget.kind == HrButtonKind.ghost ? 44.0 : 52.0);
    final glow = enabled &&
        !_down &&
        (widget.kind == HrButtonKind.primary || widget.kind == HrButtonKind.accent);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: () => setState(() => _down = false),
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedScale(
            scale: _down ? 0.97 : 1,
            duration: HrMotion.of(context, HrMotion.fast),
            child: AnimatedContainer(
              duration: HrMotion.of(context, HrMotion.base),
              height: h,
              width: widget.expand ? double.infinity : null,
              padding: EdgeInsets.symmetric(horizontal: widget.small ? 16 : 24),
              decoration: BoxDecoration(
                color: buttonGradient == null ? fill : null,
                gradient: buttonGradient,
                borderRadius: BorderRadius.circular(widget.small ? HrRadius.sm + 2 : HrRadius.md),
                border: widget.kind == HrButtonKind.secondary
                    ? Border.all(color: HrColors.cardEdge, width: 1.2)
                    : buttonGradient != null
                    ? Border.all(color: Colors.white.withValues(alpha: 0.16))
                    : null,
                boxShadow: glow
                    ? [
                        BoxShadow(
                          color: bg.withValues(alpha: 0.4),
                          blurRadius: 18,
                        ),
                      ]
                    : null,
              ),
              alignment: Alignment.center,
              child: widget.loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: ink,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: widget.small ? 18 : 21, color: ink),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: kHrFont,
                              color: ink,
                              fontSize: widget.small ? 14 : 16.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Card (replaces glassDecoration / _kGlassSheen) ──────────────────────────
class HrCard extends StatelessWidget {
  const HrCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onTap,
    this.onLongPress,
    this.highlight = false,
    this.radius = HrRadius.lg,
    super.key,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Selected / completed state: a violet edge with a soft outer glow.
  final bool highlight;
  final double radius;

  static BoxDecoration decoration({
    Color? color,
    double radius = HrRadius.lg,
    bool highlight = false,
  }) => BoxDecoration(
        color: color,
        gradient: color == null
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [HrColors.cardTop, HrColors.cardBottom],
              )
            : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: highlight ? HrColors.accent.withValues(alpha: 0.9) : HrColors.cardEdge,
          width: highlight ? 1.4 : 1,
        ),
        boxShadow: [
          if (highlight)
            BoxShadow(
              color: HrColors.accent.withValues(alpha: 0.35),
              blurRadius: 18,
            ),
          const BoxShadow(
            color: Color(0x40000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final box = Container(
      clipBehavior: Clip.antiAlias,
      decoration: decoration(color: color, radius: radius, highlight: highlight),
      child: Stack(
        children: [
          // Soft glass sheen from the top-left, like light catching the panel.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.9, -1.2),
                    radius: 1.3,
                    colors: [
                      Colors.white.withValues(alpha: 0.045),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
    return (onTap == null && onLongPress == null)
        ? box
        : _Pressable(
            onTap: onTap, onLongPress: onLongPress, scale: 0.98, child: box);
  }
}

class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: HrMotion.of(context, HrMotion.fast),
        child: widget.child,
      ),
    ),
  );
}

/// Tap target with the shared press-scale feedback.
class HrPressable extends StatelessWidget {
  const HrPressable({required this.child, this.onTap, this.onLongPress, this.scale = 0.97, super.key});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  @override
  Widget build(BuildContext context) =>
      _Pressable(onTap: onTap, onLongPress: onLongPress, scale: scale, child: child);
}

/// Section heading: "Today's quests", "Recent achievements".
class HrLabel extends StatelessWidget {
  const HrLabel(this.text, {this.trailing, this.leading, super.key});
  final String text;
  final Widget? trailing;
  final Widget? leading;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
    child: Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        Expanded(
          child: Text(text, style: HrText.headline.copyWith(fontSize: 18)),
        ),
        ?trailing,
      ],
    ),
  );
}

/// "See all" style link for section headers.
class HrLink extends StatelessWidget {
  const HrLink(this.label, {required this.onTap, super.key});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        label,
        style: HrText.bodyS.copyWith(color: HrColors.info, fontWeight: FontWeight.w800),
      ),
    ),
  );
}

// ── 3D icon tile (quest icons, menu icons) ──────────────────────────────────
/// A glossy rounded tile holding an emoji, an icon or an image — the colourful
/// "3D" quest icons of the references.
class HrIconTile extends StatelessWidget {
  const HrIconTile({
    this.emoji,
    this.icon,
    this.asset,
    this.size = 52,
    this.color,
    this.selected = false,
    super.key,
  });
  final String? emoji;
  final IconData? icon;
  final String? asset;
  final double size;

  /// Tint for the inner glow and the icon (defaults to the accent).
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? HrColors.accentBright;
    final Widget content;
    if (asset != null) {
      content = Image.asset(asset!, width: size * 0.74, height: size * 0.74, fit: BoxFit.contain);
    } else if (icon != null) {
      content = Icon(
        icon,
        size: size * 0.5,
        color: tint,
        shadows: [Shadow(color: tint.withValues(alpha: 0.6), blurRadius: 12)],
      );
    } else {
      final e = (emoji ?? '').trim();
      content = Text(
        e.isEmpty ? '✦' : e,
        maxLines: 1,
        style: TextStyle(fontSize: size * 0.5, height: 1, color: HrColors.gold),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF282D4A), Color(0xFF151829)],
        ),
        border: Border.all(
          color: selected ? HrColors.accent : const Color(0xFF30355A),
          width: selected ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: selected ? 0.35 : 0.14),
            blurRadius: 14,
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.28),
                gradient: RadialGradient(
                  radius: 0.7,
                  colors: [tint.withValues(alpha: 0.22), Colors.transparent],
                ),
              ),
            ),
          ),
          content,
        ],
      ),
    );
  }
}

// ── XP chip: ✦ +80 XP ───────────────────────────────────────────────────────
class HrXpChip extends StatelessWidget {
  const HrXpChip(this.xp, {this.label, this.plus = true, super.key});
  final int xp;
  final String? label;
  final bool plus;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
    decoration: BoxDecoration(
      color: HrColors.xpChip,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: HrColors.gold.withValues(alpha: 0.14)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome, size: 13, color: HrColors.gold),
        const SizedBox(width: 5),
        Text(
          label ?? '${plus ? '+' : ''}$xp XP',
          style: HrText.micro.copyWith(
            color: HrColors.gold,
            fontSize: 12.5,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

// ── Gold XP / progress bar ──────────────────────────────────────────────────
class HrXpBar extends StatelessWidget {
  const HrXpBar({required this.value, this.height = 10, this.color, super.key});
  final double value;
  final double height;

  /// Solid fill instead of the gold gradient (e.g. violet progress).
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final fill = color;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: v),
      duration: HrMotion.of(context, HrMotion.fill),
      curve: HrMotion.standard,
      builder: (context, t, _) => Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF07080E),
          borderRadius: BorderRadius.circular(height),
          border: Border.all(color: HrColors.cardEdge),
        ),
        child: LayoutBuilder(
          builder: (context, c) => Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: max(t > 0 ? height : 0, c.maxWidth * t),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(height),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: fill == null
                      ? const [HrColors.goldBright, HrColors.gold, HrColors.goldDeep]
                      : [Color.lerp(fill, Colors.white, 0.25)!, fill],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (fill ?? HrColors.gold).withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Stat tile: icon + big value + caption ───────────────────────────────────
class HrStatTile extends StatelessWidget {
  const HrStatTile({
    required this.value,
    required this.label,
    this.icon,
    this.leading,
    this.valueColor,
    this.onTap,
    super.key,
  });
  final String value, label;
  final IconData? icon;
  final Widget? leading;
  final Color? valueColor;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => HrCard(
    onTap: onTap,
    padding: const EdgeInsets.fromLTRB(9, 12, 6, 12),
    radius: HrRadius.md,
    child: Row(
      children: [
        leading ?? Icon(icon ?? Icons.star_rounded, size: 30, color: HrColors.gold),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: HrText.headline.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: valueColor ?? HrColors.text,
                  ),
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  style: HrText.micro.copyWith(color: HrColors.text2),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ── Menu group: a card of rows with inset dividers ──────────────────────────
class HrMenuGroup extends StatelessWidget {
  const HrMenuGroup({required this.children, this.title, super.key});
  final List<Widget> children;
  final String? title;
  @override
  Widget build(BuildContext context) => HrCard(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(title!, style: HrText.headline.copyWith(fontSize: 15)),
          ),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.only(left: 56, right: 14),
              child: Divider(height: 1),
            ),
          children[i],
        ],
      ],
    ),
  );
}

class HrMenuRow extends StatelessWidget {
  const HrMenuRow({
    required this.icon,
    required this.label,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.labelColor,
    this.chevron = true,
    super.key,
  });
  final IconData icon;
  final String label;
  final String? subtitle;

  /// Right-aligned value text before the chevron (e.g. "12 / 50", "Off").
  final Widget? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor, labelColor;
  final bool chevron;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(HrRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 24, color: iconColor ?? const Color(0xFFC9C3F0)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: HrText.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: labelColor ?? HrColors.text,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.caption,
                      ),
                  ],
                ),
              ),
              if (value != null) ...[value!, const SizedBox(width: 8)],
              ?trailing,
              if (trailing == null && chevron)
                const Icon(Icons.chevron_right_rounded, color: HrColors.text2, size: 26),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── Quest row: icon tile · title + chip · check ─────────────────────────────
class HrQuestRow extends StatelessWidget {
  const HrQuestRow({
    required this.title,
    required this.leading,
    this.subtitle,
    this.trailing,
    this.done = false,
    this.onTap,
    this.onLongPress,
    super.key,
  });
  final String title;
  final Widget leading;
  final Widget? subtitle;
  final Widget? trailing;
  final bool done;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  @override
  Widget build(BuildContext context) => Semantics(
    checked: done,
    label: title,
    child: HrCard(
      onTap: onTap,
      onLongPress: onLongPress,
      highlight: done,
      radius: HrRadius.md + 2,
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HrText.headline.copyWith(fontSize: 17),
                ),
                if (subtitle != null) ...[const SizedBox(height: 6), subtitle!],
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing ?? HrCheck(done: done, size: 32),
        ],
      ),
    ),
  );
}

// ── Habit row (replaces _HabitTile) ─────────────────────────────────────────
class HabitRow extends StatelessWidget {
  const HabitRow({
    required this.title,
    required this.done,
    required this.onToggle,
    this.icon = '',
    this.rarity = 'common',
    this.streak = 0,
    this.reminder,
    this.onEdit,
    super.key,
  });
  final String title, icon, rarity;
  final bool done;
  final int streak;
  final String? reminder;
  final VoidCallback onToggle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final rc = HrColors.rarity[rarity] ?? HrColors.text3;
    return Semantics(
      checked: done,
      label:
          '$title, ${rarity[0].toUpperCase()}${rarity.substring(1)}${streak > 0 ? ', $streak day streak' : ''}',
      child: InkWell(
        onTap: () {
          if (!done) HapticFeedback.selectionClick();
          onToggle();
        },
        onLongPress: onEdit,
        borderRadius: BorderRadius.circular(HrRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                if (icon == '💰')
                  const HrIconTile(asset: 'assets/shop/coin_stack.png', size: 40)
                else
                  HrIconTile(emoji: icon, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HrText.body.copyWith(
                          fontWeight: FontWeight.w800,
                          color: done ? HrColors.text2 : HrColors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: rc,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '${rarity[0].toUpperCase()}${rarity.substring(1)}',
                            style: HrText.caption.copyWith(color: rc),
                          ),
                          if (reminder != null) ...[
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.notifications_none_rounded,
                              size: 15,
                              color: HrColors.text3,
                            ),
                            const SizedBox(width: 2),
                            Text(reminder!, style: HrText.caption),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (streak > 0) ...[
                  StreakPill(count: streak, quiet: true),
                  const SizedBox(width: 8),
                ],
                HrCheck(done: done, size: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Gold check circle (done) or a quiet outline ring (to do).
class HrCheck extends StatelessWidget {
  const HrCheck({required this.done, this.size = 26, super.key});
  final bool done;
  final double size;
  @override
  Widget build(BuildContext context) {
    final d = HrMotion.of(context, const Duration(milliseconds: 220));
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (done && size >= 28)
            Positioned(
              left: -size * 0.3,
              top: -size * 0.3,
              right: -size * 0.3,
              bottom: -size * 0.3,
              child: const IgnorePointer(child: CustomPaint(painter: _CheckSparkles())),
            ),
          AnimatedScale(
            scale: done ? 1 : 0.94,
            duration: d,
            curve: HrMotion.spring,
            child: AnimatedContainer(
              duration: d,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: done
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [HrColors.goldBright, HrColors.gold, HrColors.goldDeep],
                      )
                    : null,
                border: done
                    ? null
                    : Border.all(color: const Color(0xFF9597B2), width: 1.6),
                boxShadow: done
                    ? [
                        BoxShadow(
                          color: HrColors.gold.withValues(alpha: 0.45),
                          blurRadius: size * 0.45,
                        ),
                      ]
                    : null,
              ),
              child: AnimatedSwitcher(
                duration: d,
                transitionBuilder: (c, a) => ScaleTransition(
                  scale: CurvedAnimation(parent: a, curve: HrMotion.spring),
                  child: c,
                ),
                child: done
                    ? Icon(
                        Icons.check_rounded,
                        key: const ValueKey(1),
                        size: size * 0.64,
                        color: const Color(0xFF2B2100),
                      )
                    : const SizedBox(key: ValueKey(0)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckSparkles extends CustomPainter {
  const _CheckSparkles();
  @override
  void paint(Canvas canvas, Size s) {
    hrDrawSparkle(canvas, Offset(s.width * 0.92, s.height * 0.1), s.width * 0.07, HrColors.goldBright, glow: false);
    hrDrawSparkle(canvas, Offset(s.width * 0.06, s.height * 0.86), s.width * 0.05, HrColors.gold, glow: false);
  }

  @override
  bool shouldRepaint(_CheckSparkles oldDelegate) => false;
}

// ── Streak pill ─────────────────────────────────────────────────────────────
class StreakPill extends StatelessWidget {
  const StreakPill({
    required this.count,
    this.quiet = false,
    this.big = false,
    this.leaderboard = false,
    this.label,
    super.key,
  });
  final int count;
  final bool quiet, big, leaderboard;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final text = label ?? (quiet ? '$count' : '$count day streak');
    final fg = quiet ? HrColors.streak : HrColors.onStreak;
    Widget pill = Container(
      height: big
          ? 40
          : leaderboard
          ? 26
          : 28,
      padding: EdgeInsets.fromLTRB(
        big
            ? 12
            : leaderboard
            ? 6
            : 8,
        0,
        big
            ? 18
            : leaderboard
            ? 8
            : 12,
        0,
      ),
      decoration: BoxDecoration(
        color: quiet ? HrColors.streakSurface : HrColors.streak,
        gradient: leaderboard
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF38220E), Color(0xFF21170E)],
              )
            : null,
        borderRadius: BorderRadius.circular(HrRadius.full),
        border: big
            ? Border.all(color: HrColors.stickerOutline, width: 3)
            : leaderboard
            ? Border.all(color: const Color(0x66FF9F0A), width: 1)
            : null,
        boxShadow: big
            ? HrShadow.sticker
            : leaderboard
            ? const [
                BoxShadow(
                  color: Color(0x24FF8A00),
                  blurRadius: 7,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/streaks/enamel_flame.png',
              width: big
                  ? 22
                  : leaderboard
                  ? 16
                  : 17,
              height: big
                  ? 22
                  : leaderboard
                  ? 16
                  : 17,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 4),
            Text(
              quiet ? text : text.toUpperCase(),
              style: TextStyle(
                fontFamily: kHrFont,
                color: leaderboard ? const Color(0xFFFFC76A) : fg,
                fontWeight: FontWeight.w900,
                fontSize: big
                    ? 18
                    : leaderboard
                    ? 12
                    : 13,
                letterSpacing: quiet ? 0 : 0.4,
              ),
            ),
          ],
        ),
      ),
    );
    if (big) pill = Transform.rotate(angle: -3 * pi / 180, child: pill);
    return Semantics(
      label: '$count day streak',
      excludeSemantics: true,
      child: pill,
    );
  }
}

// ── Count sticker: 3/5 ──────────────────────────────────────────────────────
class CountSticker extends StatelessWidget {
  const CountSticker(
    this.text, {
    this.size = 30,
    this.fill,
    this.semanticLabel,
    super.key,
  });
  final String text;
  final double size;
  final Color? fill;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final style = HrText.sticker.copyWith(fontSize: size);
    return Semantics(
      label: semanticLabel ?? text,
      excludeSemantics: true,
      child: Transform.rotate(
        angle: -4 * pi / 180,
        child: Stack(
          children: [
            Text(
              text,
              style: style.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = size * 0.23
                  ..strokeJoin = StrokeJoin.round
                  ..color = HrColors.stickerInk,
              ),
            ),
            Text(
              text,
              style: style.copyWith(color: fill ?? HrColors.stickerFill),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Progress dots ───────────────────────────────────────────────────────────
class ProgressDots extends StatelessWidget {
  const ProgressDots({
    required this.total,
    required this.done,
    this.size = 14,
    this.color,
    super.key,
  });
  final int total, done;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$done of $total done',
    excludeSemantics: true,
    child: Wrap(
      spacing: size * 0.4,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: HrMotion.of(context, HrMotion.base),
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < done ? (color ?? HrColors.gold) : HrColors.surface3,
              boxShadow: i < done
                  ? [
                      BoxShadow(
                        color: (color ?? HrColors.gold).withValues(alpha: 0.4),
                        blurRadius: size * 0.6,
                      ),
                    ]
                  : null,
            ),
            child: i < done && size >= 20
                ? Icon(
                    Icons.check_rounded,
                    size: size * 0.68,
                    color: HrColors.onBtnPrimary,
                  )
                : null,
          ),
      ],
    ),
  );
}

/// Row of small rounded squares — the streak meter on Today.
class HrStreakSquares extends StatelessWidget {
  const HrStreakSquares({required this.total, required this.filled, this.size = 13, super.key});
  final int total, filled;
  final double size;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < total; i++) ...[
        if (i > 0) SizedBox(width: size * 0.38),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: i < filled ? HrColors.gold : const Color(0xFF1C1F33),
            borderRadius: BorderRadius.circular(size * 0.24),
            border: i < filled ? null : Border.all(color: HrColors.cardEdge),
            boxShadow: i < filled
                ? [BoxShadow(color: HrColors.gold.withValues(alpha: 0.4), blurRadius: 7)]
                : null,
          ),
        ),
      ],
    ],
  );
}

// ── Segmented ring (replaces GlowRing) ──────────────────────────────────────
class SegmentedRing extends StatelessWidget {
  /// segments == 1 → continuous ring, value 0..1. Otherwise value = filled segment count.
  const SegmentedRing({
    required this.size,
    required this.segments,
    required this.value,
    this.stroke = 10,
    this.gapDeg = 12,
    this.color,
    this.center,
    super.key,
  });
  final double size, stroke, gapDeg;
  final int segments;
  final double value;
  final Color? color;
  final Widget? center;
  @override
  Widget build(BuildContext context) {
    final target = segments == 1
        ? value.clamp(0.0, 1.0)
        : value.clamp(0.0, segments.toDouble());
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target.toDouble()),
      duration: HrMotion.of(context, HrMotion.fill),
      curve: HrMotion.standard,
      builder: (_, v, child) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            segments,
            v,
            stroke,
            gapDeg,
            color ?? HrColors.accent,
          ),
          child: Center(child: child),
        ),
      ),
      child: center,
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.segments, this.value, this.stroke, this.gapDeg, this.color);
  final int segments;
  final double value, stroke, gapDeg;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final rect = Rect.fromCircle(
      center: s.center(Offset.zero),
      radius: (s.width - stroke) / 2,
    );
    Paint p(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = c;
    Paint glow() => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.45)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.7);
    const start = -pi / 2;
    const track = Color(0xFF1C1F33);
    if (segments <= 1) {
      canvas.drawArc(rect, 0, 2 * pi, false, p(track));
      if (value > 0) {
        canvas.drawArc(rect, start, 2 * pi * value, false, glow());
        canvas.drawArc(rect, start, 2 * pi * value, false, p(color));
      }
      return;
    }
    final gap = gapDeg * pi / 180, seg = 2 * pi / segments - gap;
    for (var i = 0; i < segments; i++) {
      final a = start + gap / 2 + i * (seg + gap);
      canvas.drawArc(rect, a, seg, false, p(track));
      final f = (value - i).clamp(0.0, 1.0);
      if (f > 0) canvas.drawArc(rect, a, seg * f, false, p(color));
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.value != value || o.color != color || o.segments != segments;
}

// ── Companion sticker + speech bubble ───────────────────────────────────────
class CompanionSticker extends StatelessWidget {
  const CompanionSticker({
    required this.icon,
    required this.color,
    this.size = 72,
    this.locked = false,
    this.semanticLabel,
    this.imageAsset,
    super.key,
  });
  final IconData icon;
  final Color color;
  final double size;
  final bool locked;
  final String? semanticLabel;
  final String? imageAsset;
  @override
  Widget build(BuildContext context) {
    final edge = size >= 100
        ? 5.0
        : size >= 60
        ? 4.0
        : 2.5;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Transform.rotate(
        angle: size >= 60 && !locked ? -4 * pi / 180 : 0,
        child: Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: locked ? HrColors.surface3 : HrColors.bg,
            border: locked || imageAsset != null
                ? null
                : Border.all(color: HrColors.stickerOutline, width: edge),
            boxShadow: locked || size < 60 ? null : HrShadow.sticker,
          ),
          child: imageAsset != null && !locked
              ? Image.asset(imageAsset!, fit: BoxFit.cover)
              : Icon(
                  locked ? Icons.lock_rounded : icon,
                  size: size * 0.52,
                  color: locked ? HrColors.text3 : HrColors.bg,
                ),
        ),
      ),
    );
  }
}

class SpeechBubble extends StatelessWidget {
  const SpeechBubble(
    this.text, {
    this.speaker,
    this.tailRight = false,
    this.maxWidth = 220,
    super.key,
  });
  final String text;
  final String? speaker;
  final bool tailRight;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => Semantics(
    label: speaker == null ? text : '$speaker says: $text',
    excludeSemantics: true,
    child: Transform.rotate(
      angle: (tailRight ? 2 : -2) * pi / 180,
      child: CustomPaint(
        painter: _BubblePainter(tailRight),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: kHrFont,
                color: HrColors.bubbleInk,
                fontSize: 14,
                height: 18 / 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _BubblePainter extends CustomPainter {
  _BubblePainter(this.right);
  final bool right;
  @override
  void paint(Canvas c, Size s) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & s,
      const Radius.circular(16),
    );
    final tx = right ? s.width - 34 : 26.0;
    final path = Path()
      ..addRRect(r)
      ..moveTo(tx, s.height - 1)
      ..lineTo(tx + 6, s.height + 9)
      ..lineTo(tx + 16, s.height - 1)
      ..close();
    c.drawPath(
      path.shift(const Offset(0, 4)),
      Paint()..color = const Color(0x73000000),
    );
    c.drawPath(
      path,
      Paint()
        ..color = HrColors.accent.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    c.drawPath(path, Paint()..color = HrColors.bubble);
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = HrColors.accent.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_BubblePainter o) => o.right != right;
}

// ── Tab bar (replaces _BottomNav) ───────────────────────────────────────────
class HrTabItem {
  const HrTabItem(this.icon, this.activeIcon, this.label);
  final IconData icon, activeIcon;
  final String label;
}

const hrTabs = [
  HrTabItem(Icons.home_rounded, Icons.home_rounded, 'Today'),
  HrTabItem(Icons.timer_outlined, Icons.timer_rounded, 'Focus'),
  HrTabItem(Icons.bar_chart_rounded, Icons.bar_chart_rounded, 'Progress'),
  HrTabItem(Icons.group_rounded, Icons.group_rounded, 'Friends'),
  HrTabItem(Icons.person_rounded, Icons.person_rounded, 'Profile'),
];

class HrTabBar extends StatelessWidget {
  const HrTabBar({required this.index, required this.onTap, super.key});
  final int index;
  final ValueChanged<int> onTap;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: HrColors.navBg,
      border: Border(top: BorderSide(color: HrColors.cardEdge)),
      boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, -4))],
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 9, 6, 5),
        child: Row(
          children: [
            for (var i = 0; i < hrTabs.length; i++)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  label: hrTabs[i].label,
                  excludeSemantics: true,
                  child: InkResponse(
                    onTap: () => onTap(i),
                    radius: 32,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: HrMotion.of(context, HrMotion.base),
                          child: Icon(
                            i == index ? hrTabs[i].activeIcon : hrTabs[i].icon,
                            key: ValueKey(i == index),
                            size: 26,
                            color: i == index ? HrColors.accentBright : const Color(0xFF8A8CA6),
                            shadows: i == index
                                ? [Shadow(color: HrColors.accent.withValues(alpha: 0.8), blurRadius: 14)]
                                : null,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          hrTabs[i].label,
                          style: HrText.micro.copyWith(
                            fontSize: 11.5,
                            color: i == index ? HrColors.text : const Color(0xFF8A8CA6),
                            fontWeight: i == index ? FontWeight.w900 : FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        AnimatedContainer(
                          duration: HrMotion.of(context, HrMotion.base),
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == index ? HrColors.gold : Colors.transparent,
                            boxShadow: i == index
                                ? [
                                    BoxShadow(
                                      color: HrColors.gold.withValues(alpha: 0.6),
                                      blurRadius: 8,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ── Segmented control ───────────────────────────────────────────────────────
class HrSegmented extends StatelessWidget {
  const HrSegmented({
    required this.items,
    required this.index,
    required this.onChanged,
    super.key,
  });
  final List<String> items;
  final int index;
  final ValueChanged<int>? onChanged; // null = disabled (e.g. focus running)
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xFF0F1220),
      border: Border.all(color: HrColors.cardEdge),
      borderRadius: BorderRadius.circular(HrRadius.md),
    ),
    child: LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth / items.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: HrMotion.of(context, HrMotion.base),
              curve: HrMotion.standard,
              left: w * index,
              width: w,
              top: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color.lerp(HrColors.accent, Colors.white, 0.12)!,
                      HrColors.accent,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(HrRadius.md - 3),
                  boxShadow: [
                    BoxShadow(
                      color: HrColors.accent.withValues(alpha: 0.45),
                      blurRadius: 14,
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Container(
                      width: 1,
                      height: 16,
                      color: (i == index || i - 1 == index)
                          ? Colors.transparent
                          : HrColors.cardEdge,
                    ),
                  Expanded(
                    child: Semantics(
                      selected: i == index,
                      button: true,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onChanged == null ? null : () => onChanged!(i),
                        child: SizedBox(
                          height: 38,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: HrMotion.of(context, HrMotion.base),
                              style: TextStyle(
                                fontFamily: kHrFont,
                                fontSize: 14.5,
                                fontWeight: i == index ? FontWeight.w800 : FontWeight.w700,
                                color: i == index
                                    ? HrColors.text
                                    : (onChanged == null
                                          ? HrColors.textDisabled
                                          : HrColors.text2),
                              ),
                              child: Text(
                                items[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// Separate filter pills (Awards: All / Streaks / Habits / Special).
class HrFilterChips extends StatelessWidget {
  const HrFilterChips({
    required this.items,
    required this.index,
    required this.onChanged,
    super.key,
  });
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          HrPressable(
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: HrMotion.of(context, HrMotion.base),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: i == index ? HrColors.accent : HrColors.surface,
                borderRadius: BorderRadius.circular(HrRadius.sm),
                border: Border.all(
                  color: i == index ? HrColors.accentBright.withValues(alpha: 0.5) : HrColors.cardEdge,
                ),
                boxShadow: i == index
                    ? [BoxShadow(color: HrColors.accent.withValues(alpha: 0.4), blurRadius: 12)]
                    : null,
              ),
              child: Text(
                items[i],
                style: HrText.bodyS.copyWith(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: i == index ? HrColors.text : HrColors.text2,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

// ── Toast (replaces _toast / ad-hoc SnackBars) ──────────────────────────────
void hrToast(
  BuildContext context,
  String message, {
  IconData? icon,
  Color? iconColor,
  String? actionLabel,
  VoidCallback? onAction,
  bool error = false,
}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      duration: Duration(milliseconds: actionLabel != null ? 4000 : 1400),
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 20,
              color: error ? HrColors.dangerText : (iconColor ?? HrColors.gold),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: kHrFont,
                fontWeight: FontWeight.w700,
                color: error ? HrColors.dangerText : HrColors.text,
              ),
            ),
          ),
        ],
      ),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
    ),
  );
}
