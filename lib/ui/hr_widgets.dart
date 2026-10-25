// Habitrail core widgets — Flutter implementations of the design-system components.
// Each class names the old widget it replaces in lib/main.dart.
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'hr_tokens.dart';

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
        HrButtonKind.primary => (HrColors.btnPrimary, HrColors.btnPrimaryPressed, HrColors.onBtnPrimary),
        HrButtonKind.accent => (HrColors.accent, HrColors.accentPressed, HrColors.onAccent),
        HrButtonKind.secondary => (HrColors.surface2, HrColors.surface3, HrColors.text),
        HrButtonKind.ghost => (Colors.transparent, HrColors.surface2, HrColors.text2),
        HrButtonKind.danger => (HrColors.dangerSurface, HrColors.dangerSurface, HrColors.dangerText),
      };

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final (bg, pressed, fg) = _colors;
    final fill = widget.onPressed == null ? HrColors.surface2 : (_down ? pressed : bg);
    final ink = widget.onPressed == null ? HrColors.textDisabled : fg;
    final h = widget.small ? 36.0 : (widget.kind == HrButtonKind.ghost ? 44.0 : 52.0);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(HrRadius.full)),
              alignment: Alignment.center,
              child: widget.loading
                  ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: ink))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (widget.icon != null) ...[Icon(widget.icon, size: 20, color: ink), const SizedBox(width: 8)],
                      Text(widget.label,
                          style: TextStyle(color: ink, fontSize: widget.small ? 14 : 16, fontWeight: FontWeight.w700)),
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Card (replaces glassDecoration / _kGlassSheen) ──────────────────────────
class HrCard extends StatelessWidget {
  const HrCard({required this.child, this.padding = const EdgeInsets.all(16), this.color, this.onTap, super.key});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;

  static BoxDecoration decoration({Color? color, double radius = HrRadius.lg}) => BoxDecoration(
        color: color ?? HrColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: const Border(top: BorderSide(color: HrColors.hairline)),
      );

  @override
  Widget build(BuildContext context) {
    final box = Container(padding: padding, decoration: decoration(color: color), child: child);
    return onTap == null ? box : _Pressable(onTap: onTap!, scale: 0.98, child: box);
  }
}

class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap, this.scale = 0.97});
  final Widget child;
  final VoidCallback onTap;
  final double scale;
  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(scale: _down ? widget.scale : 1, duration: HrMotion.of(context, HrMotion.fast), child: widget.child),
      );
}

/// Section label: THE FIVE
class HrLabel extends StatelessWidget {
  const HrLabel(this.text, {this.trailing, super.key});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Row(children: [
          Expanded(child: Text(text.toUpperCase(), style: HrText.labelCaps)),
          ?trailing,
        ]),
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
      label: '$title, ${rarity[0].toUpperCase()}${rarity.substring(1)}${streak > 0 ? ', $streak day streak' : ''}',
      child: InkWell(
        onTap: () {
          if (!done) HapticFeedback.selectionClick();
          onToggle();
        },
        onLongPress: onEdit,
        borderRadius: BorderRadius.circular(HrRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(children: [
              HrCheck(done: done),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(icon.isEmpty ? title : '$icon  $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HrText.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: done ? HrColors.text3 : HrColors.text,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationThickness: 1.5,
                      )),
                  const SizedBox(height: 2),
                  Row(children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: rc)),
                    const SizedBox(width: 5),
                    Text('${rarity[0].toUpperCase()}${rarity.substring(1)}', style: HrText.caption.copyWith(color: rc)),
                    if (reminder != null) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.notifications_none_rounded, size: 15, color: HrColors.text3),
                      const SizedBox(width: 2),
                      Text(reminder!, style: HrText.caption),
                    ],
                  ]),
                ]),
              ),
              if (streak > 0) StreakPill(count: streak, quiet: true),
            ]),
          ),
        ),
      ),
    );
  }
}

class HrCheck extends StatelessWidget {
  const HrCheck({required this.done, this.size = 26, super.key});
  final bool done;
  final double size;
  @override
  Widget build(BuildContext context) {
    final d = HrMotion.of(context, const Duration(milliseconds: 220));
    return AnimatedScale(
      scale: done ? 1 : 0.94,
      duration: d,
      curve: HrMotion.spring,
      child: AnimatedContainer(
        duration: d,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? HrColors.accent : Colors.transparent,
          border: Border.all(color: done ? HrColors.accent : HrColors.controlBorder, width: 2),
        ),
        child: AnimatedSwitcher(
          duration: d,
          transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: HrMotion.spring), child: c),
          child: done
              ? Icon(Icons.check_rounded, key: const ValueKey(1), size: size * 0.7, color: HrColors.onAccent)
              : const SizedBox(key: ValueKey(0)),
        ),
      ),
    );
  }
}

// ── Streak pill ─────────────────────────────────────────────────────────────
class StreakPill extends StatelessWidget {
  const StreakPill({required this.count, this.quiet = false, this.big = false, this.label, super.key});
  final int count;
  final bool quiet, big;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final text = label ?? (quiet ? '$count' : '$count day streak');
    final fg = quiet ? HrColors.streak : HrColors.onStreak;
    Widget pill = Container(
      height: big ? 40 : 28,
      padding: EdgeInsets.fromLTRB(big ? 12 : 8, 0, big ? 18 : 12, 0),
      decoration: BoxDecoration(
        color: quiet ? HrColors.streakSurface : HrColors.streak,
        borderRadius: BorderRadius.circular(HrRadius.full),
        border: big ? Border.all(color: HrColors.stickerOutline, width: 3) : null,
        boxShadow: big ? HrShadow.sticker : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.local_fire_department_rounded, size: big ? 22 : 17, color: fg),
        const SizedBox(width: 4),
        Text(quiet ? text : text.toUpperCase(),
            style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: big ? 18 : 13, letterSpacing: quiet ? 0 : 0.4)),
      ]),
    );
    if (big) pill = Transform.rotate(angle: -3 * pi / 180, child: pill);
    return Semantics(label: '$count day streak', excludeSemantics: true, child: pill);
  }
}

// ── Count sticker: 3/5 ──────────────────────────────────────────────────────
class CountSticker extends StatelessWidget {
  const CountSticker(this.text, {this.size = 30, this.fill, this.semanticLabel, super.key});
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
        child: Stack(children: [
          Text(text, style: style.copyWith(foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = size * 0.23
            ..strokeJoin = StrokeJoin.round
            ..color = HrColors.stickerInk)),
          Text(text, style: style.copyWith(color: fill ?? HrColors.stickerFill)),
        ]),
      ),
    );
  }
}

// ── Progress dots ───────────────────────────────────────────────────────────
class ProgressDots extends StatelessWidget {
  const ProgressDots({required this.total, required this.done, this.size = 14, this.color, super.key});
  final int total, done;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$done of $total done',
        excludeSemantics: true,
        child: Wrap(spacing: size * 0.4, children: [
          for (var i = 0; i < total; i++)
            AnimatedContainer(
              duration: HrMotion.of(context, HrMotion.base),
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, color: i < done ? (color ?? HrColors.accent) : HrColors.surface3),
              child: i < done && size >= 20 ? Icon(Icons.check_rounded, size: size * 0.68, color: HrColors.onAccent) : null,
            ),
        ]),
      );
}

// ── Segmented ring (replaces GlowRing) ──────────────────────────────────────
class SegmentedRing extends StatelessWidget {
  /// segments == 1 → continuous ring, value 0..1. Otherwise value = filled segment count.
  const SegmentedRing({required this.size, required this.segments, required this.value, this.stroke = 10, this.gapDeg = 12, this.color, this.center, super.key});
  final double size, stroke, gapDeg;
  final int segments;
  final double value;
  final Color? color;
  final Widget? center;
  @override
  Widget build(BuildContext context) {
    final target = segments == 1 ? value.clamp(0.0, 1.0) : value.clamp(0.0, segments.toDouble());
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target.toDouble()),
      duration: HrMotion.of(context, HrMotion.fill),
      curve: HrMotion.standard,
      builder: (_, v, child) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _RingPainter(segments, v, stroke, gapDeg, color ?? HrColors.accent), child: Center(child: child)),
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
    final rect = Rect.fromCircle(center: s.center(Offset.zero), radius: (s.width - stroke) / 2);
    Paint p(Color c) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = c;
    const start = -pi / 2;
    if (segments <= 1) {
      canvas.drawArc(rect, 0, 2 * pi, false, p(HrColors.surface3));
      if (value > 0) canvas.drawArc(rect, start, 2 * pi * value, false, p(color));
      return;
    }
    final gap = gapDeg * pi / 180, seg = 2 * pi / segments - gap;
    for (var i = 0; i < segments; i++) {
      final a = start + gap / 2 + i * (seg + gap);
      canvas.drawArc(rect, a, seg, false, p(HrColors.surface3));
      final f = (value - i).clamp(0.0, 1.0);
      if (f > 0) canvas.drawArc(rect, a, seg * f, false, p(color));
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.value != value || o.color != color || o.segments != segments;
}

// ── Companion sticker + speech bubble ───────────────────────────────────────
class CompanionSticker extends StatelessWidget {
  const CompanionSticker({required this.icon, required this.color, this.size = 72, this.locked = false, this.semanticLabel, super.key});
  final IconData icon;
  final Color color;
  final double size;
  final bool locked;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final edge = size >= 100 ? 5.0 : size >= 60 ? 4.0 : 2.5;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Transform.rotate(
        angle: size >= 60 && !locked ? -4 * pi / 180 : 0,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: locked ? HrColors.surface3 : color,
            border: locked ? null : Border.all(color: HrColors.stickerOutline, width: edge),
            boxShadow: locked || size < 60 ? null : HrShadow.sticker,
          ),
          child: Icon(locked ? Icons.lock_rounded : icon, size: size * 0.52, color: locked ? HrColors.text3 : HrColors.bg),
        ),
      ),
    );
  }
}

class SpeechBubble extends StatelessWidget {
  const SpeechBubble(this.text, {this.speaker, this.tailRight = false, this.maxWidth = 220, super.key});
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
                child: Text(text, style: const TextStyle(color: HrColors.bubbleInk, fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w700)),
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
    final r = RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(18));
    final tx = right ? s.width - 34 : 26.0;
    final path = Path()
      ..addRRect(r)
      ..moveTo(tx, s.height - 1)
      ..lineTo(tx + 6, s.height + 9)
      ..lineTo(tx + 16, s.height - 1)
      ..close();
    c.drawPath(path.shift(const Offset(0, 4)), Paint()..color = const Color(0x73000000));
    c.drawPath(path, Paint()..color = HrColors.bubble);
    c.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = HrColors.bubbleInk);
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
  HrTabItem(Icons.radio_button_unchecked_rounded, Icons.radio_button_checked_rounded, 'Today'),
  HrTabItem(Icons.timer_outlined, Icons.timer_rounded, 'Focus'),
  HrTabItem(Icons.calendar_month_outlined, Icons.calendar_month_rounded, 'Progress'),
  HrTabItem(Icons.group_outlined, Icons.group_rounded, 'Friends'),
  HrTabItem(Icons.person_outline_rounded, Icons.person_rounded, 'You'),
];

class HrTabBar extends StatelessWidget {
  const HrTabBar({required this.index, required this.onTap, super.key});
  final int index;
  final ValueChanged<int> onTap;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: HrColors.navBg, border: Border(top: BorderSide(color: HrColors.hairline))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Row(children: [
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
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        AnimatedSwitcher(
                          duration: HrMotion.of(context, HrMotion.base),
                          child: Icon(i == index ? hrTabs[i].activeIcon : hrTabs[i].icon,
                              key: ValueKey(i == index), size: 26, color: i == index ? HrColors.text : HrColors.text3),
                        ),
                        const SizedBox(height: 3),
                        Text(hrTabs[i].label, style: HrText.micro.copyWith(color: i == index ? HrColors.text : HrColors.text3)),
                        const SizedBox(height: 2),
                        AnimatedContainer(
                          duration: HrMotion.of(context, HrMotion.base),
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: i == index ? HrColors.accent : Colors.transparent),
                        ),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      );
}

// ── Segmented control ───────────────────────────────────────────────────────
class HrSegmented extends StatelessWidget {
  const HrSegmented({required this.items, required this.index, required this.onChanged, super.key});
  final List<String> items;
  final int index;
  final ValueChanged<int>? onChanged; // null = disabled (e.g. focus running)
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: HrColors.surface, borderRadius: BorderRadius.circular(HrRadius.full)),
        child: LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth / items.length;
          return Stack(children: [
            AnimatedPositioned(
              duration: HrMotion.of(context, HrMotion.base),
              curve: HrMotion.standard,
              left: w * index,
              width: w,
              top: 0,
              bottom: 0,
              child: DecoratedBox(decoration: BoxDecoration(color: HrColors.text, borderRadius: BorderRadius.circular(HrRadius.full))),
            ),
            Row(children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == index,
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onChanged == null ? null : () => onChanged!(i),
                      child: SizedBox(
                        height: 36,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: HrMotion.of(context, HrMotion.base),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: i == index ? HrColors.bg : (onChanged == null ? HrColors.textDisabled : HrColors.text2)),
                            child: Text(items[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ]);
        }),
      );
}

// ── Toast (replaces _toast / ad-hoc SnackBars) ──────────────────────────────
void hrToast(BuildContext context, String message, {IconData? icon, Color? iconColor, String? actionLabel, VoidCallback? onAction, bool error = false}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    duration: Duration(milliseconds: actionLabel != null ? 4000 : 1400),
    content: Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 20, color: error ? HrColors.dangerText : (iconColor ?? HrColors.text)),
        const SizedBox(width: 10),
      ],
      Expanded(child: Text(message, style: TextStyle(color: error ? HrColors.dangerText : HrColors.text))),
    ]),
    action: actionLabel == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
  ));
}
