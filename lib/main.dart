import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:window_manager/window_manager.dart';
import 'core.dart';
import 'ai.dart';

/// Single shared state object for the whole app (loads immediately).
final appState = AppState()..load();

// ── Living background — drifting particles + ambient glow (the web's
//    ParticleUniverse / "every screen is a place" atmosphere). ───────────────
class _Particle {
  _Particle(this.x, this.y, this.r, this.speed, this.phase);
  double x, y, r, speed, phase;
}

class _ParticleBackground extends StatefulWidget {
  const _ParticleBackground();
  @override
  State<_ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<_ParticleBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final List<_Particle> _particles = [];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 24))
      ..repeat();
    final r = Random(7);
    for (int i = 0; i < 46; i++) {
      _particles.add(_Particle(r.nextDouble(), r.nextDouble(),
          1 + r.nextDouble() * 2.2, 0.3 + r.nextDouble() * 0.9, r.nextDouble()));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(
        painter: _ParticlePainter(_particles, _c.value),
        size: Size.infinite,
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.particles, this.t);
  final List<_Particle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Base radial gradient (violet haze over the deep base).
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0.6, -0.9),
          radius: 1.3,
          colors: [Color(0xFF1C0B38), kBase],
        ).createShader(rect),
    );
    // Soft ambient orbs.
    void orb(Offset c, double rad, Color col) {
      canvas.drawCircle(
        c,
        rad,
        Paint()
          ..shader = RadialGradient(
            colors: [col, col.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: rad)),
      );
    }

    orb(Offset(size.width * 0.82, size.height * 0.08), 200,
        kPlasma.withValues(alpha: 0.12));
    orb(Offset(size.width * 0.08, size.height * 0.5), 180,
        kBlue.withValues(alpha: 0.10));
    orb(Offset(size.width * 0.6, size.height * 1.02), 220,
        kCyan.withValues(alpha: 0.07));
    // Drifting particles.
    final p = Paint();
    for (final part in particles) {
      double yy = (part.y - t * part.speed) % 1.0;
      if (yy < 0) yy += 1;
      final y = yy * size.height;
      final x = part.x * size.width + sin((t + part.phase) * 2 * pi) * 7;
      final tw = 0.5 + 0.5 * sin((part.phase + t) * 2 * pi);
      p.color = kPlasmaGlow.withValues(alpha: (0.15 + 0.45 * tw).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), part.r, p);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.t != t;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On desktop, constrain the window to phone proportions so every screen and
  // popup renders phone-shaped (mobile/web already size themselves).
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(400, 860),
      minimumSize: Size(340, 640),
      center: true,
      title: 'Habitrail',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const HabitrailApp());
}

class HabitrailApp extends StatelessWidget {
  const HabitrailApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(brightness: Brightness.dark);
    return MaterialApp(
      title: 'Habitrail',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(seedColor: kPlasma, brightness: Brightness.dark),
        scaffoldBackgroundColor: kBase,
        textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme)
            .apply(bodyColor: kTextPrimary, displayColor: kTextPrimary),
      ),
      home: const HomeShell(),
    );
  }
}

// ── Shell: bottom nav + the 5 screens ───────────────────────────────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _briefingChecked = false;

  Widget? _fab() {
    if (_index == 0) {
      return FloatingActionButton.extended(
        onPressed: () => showHabitEditor(context),
        backgroundColor: kPlasma,
        icon: const Icon(Icons.add),
        label: const Text('Add habit'),
      );
    }
    if (_index == 4) {
      return FloatingActionButton.extended(
        onPressed: () => showAddReflection(context),
        backgroundColor: kPlasma,
        icon: const Icon(Icons.edit),
        label: const Text('Reflect'),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (appState.loading) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!_briefingChecked && appState.needsBriefing) {
          _briefingChecked = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => const _DailyBriefing(),
            );
          });
        }
        // Build fresh instances each time so the screens reflect state changes.
        // (A const list would canonicalize them and Flutter would skip rebuilds,
        // which is why completed habits weren't showing their checked state.)
        // ignore: prefer_const_constructors, prefer_const_literals_to_create_immutables
        final screens = <Widget>[HomeScreen(), FocusScreen(), StatsScreen(), AwardsScreen(), JournalScreen()];
        return Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: _ParticleBackground()),
              IndexedStack(index: _index, children: screens),
            ],
          ),
          floatingActionButton: _fab(),
          bottomNavigationBar: _BottomNav(
            index: _index,
            onTap: (i) => setState(() => _index = i),
          ),
        );
      },
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.dashboard_rounded, 'Home'),
    (Icons.timer_rounded, 'Focus'),
    (Icons.bar_chart_rounded, 'Stats'),
    (Icons.emoji_events_rounded, 'Awards'),
    (Icons.menu_book_rounded, 'Journal'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kSurfacePrimary,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (int i = 0; i < _items.length; i++)
                _NavItem(
                  icon: _items[i].$1,
                  label: _items[i].$2,
                  active: i == index,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: active
              ? const LinearGradient(
                  colors: [Color(0xFF26124F), Color(0xFF141A3A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          border: Border.all(
              color: active ? kPlasma : Colors.transparent, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 20, color: active ? kPlasmaBright : kTextTertiary),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : kTextTertiary)),
          ],
        ),
      ),
    );
  }
}

// ── Reusable app bar with the coins pill ────────────────────────────────────
PreferredSizeWidget _titleBar(String title) {
  return AppBar(
    backgroundColor: Colors.transparent,
    title: Text(title,
        style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
            color: kTextPrimary)),
    actions: [
      Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.settings_rounded,
              color: kTextTertiary, size: 20),
          tooltip: 'Settings',
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ),
      Builder(
        builder: (context) => GestureDetector(
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ShopScreen())),
          child: Container(
            margin: const EdgeInsets.only(right: 14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: kElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorder),
            ),
            child: Row(children: [
              if (appState.xpBoostActive) ...[
                Text('2×',
                    style: TextStyle(
                        color: kPlasmaGlow,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
                const SizedBox(width: 6),
              ],
              const Icon(Icons.bolt, size: 16, color: kGold),
              const SizedBox(width: 5),
              Text('${appState.coins}',
                  style: const TextStyle(
                      color: kGold, fontWeight: FontWeight.bold)),
            ]),
          ),
        ),
      ),
    ],
  );
}

// ── HOME ────────────────────────────────────────────────────────────────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    void onToggle(Habit h) {
      final old = appState.level;
      final oldStreak = h.streak;
      final doneBefore = appState.doneTodayCount;
      final total = appState.habits.length;
      appState.toggle(h);
      final who = appState.activeCompanion;
      if (appState.consumeBossDefeat()) {
        appState.setCompanionLine(companionLine(who, 'boss_defeat'));
        celebrate(context);
        if (appState.consumeSeasonIntro()) {
          _showSeasonIntro(context);
        } else {
          _showBossDefeat(context);
        }
      } else if (appState.level > old) {
        appState.setCompanionLine(companionLine(who, 'level_up'));
        celebrate(context);
        _showLevelUp(context, appState.level);
      } else {
        if (h.streak == 30 && oldStreak != 30) {
          appState.setCompanionLine(companionLine(who, 'streak_30'));
        } else if (h.streak == 7 && oldStreak != 7) {
          appState.setCompanionLine(companionLine(who, 'streak_7'));
        } else if (appState.victory().score >= 90) {
          appState.setCompanionLine(companionLine(who, 'elite_day'));
        }
        // A perfect day just completed → a little confetti.
        if (total > 0 && doneBefore < total && appState.doneTodayCount == total) {
          celebrate(context);
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('🔥 Habitrail'),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _LevelHeader(ld: ld),
          const _CompanionCard(),
          const _VictoryCard(),
          const _NutritionCard(),
          const _BossCard(),
          const _QuestsPanel(),
          const _PrestigeCard(),
          const Padding(
            padding: EdgeInsets.fromLTRB(22, 14, 22, 6),
            child: Text('HABITS',
                style: TextStyle(
                    color: kTextTertiary,
                    fontSize: 12,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold)),
          ),
          if (appState.habits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: _EmptyState(
                  emoji: '🌱',
                  title: 'No habits yet',
                  subtitle: 'Tap “Add habit” to start.'),
            )
          else
            ...appState.habits.map((h) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _HabitTile(
                    habit: h,
                    done: appState.doneToday(h),
                    onToggle: () => onToggle(h),
                    onDelete: () => appState.deleteHabit(h),
                    onEdit: () => showHabitEditor(context, h),
                  ),
                )),
        ],
      ),
    );
  }
}

class _VictoryCard extends StatelessWidget {
  const _VictoryCard();
  @override
  Widget build(BuildContext context) {
    final v = appState.victory();
    final color = victoryColor(v.score);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(children: [
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(
                value: v.score / 100,
                strokeWidth: 6,
                backgroundColor: const Color(0x14FFFFFF),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            Text('${v.score}',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('VICTORY SCORE',
                  style: TextStyle(
                      color: kTextTertiary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(victoryLabel(v.score),
                  style: TextStyle(
                      color: color, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                  'Habits ${v.habits} · Nutr ${v.nutrition} · Focus ${v.focus} · Sleep ${v.sleep}',
                  style: const TextStyle(color: kTextSecondary, fontSize: 11)),
            ],
          ),
        ),
      ]),
    );
  }
}

class _BossCard extends StatelessWidget {
  const _BossCard();
  @override
  Widget build(BuildContext context) {
    final count = appState.perfectDaysThisWeek().clamp(0, kBossGoal);
    final defeated = count >= kBossGoal;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: defeated ? kGold : kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.shield_rounded, color: kGold, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(kBossTitle,
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            Text(defeated ? 'DEFEATED' : '$count/$kBossGoal',
                style: TextStyle(
                    color: defeated ? kGold : kTextSecondary,
                    fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: (count / kBossGoal).clamp(0.0, 1.0).toDouble(),
              minHeight: 8,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor: const AlwaysStoppedAnimation<Color>(kGold),
            ),
          ),
          const SizedBox(height: 8),
          Text(
              defeated
                  ? 'Reward claimed: +$kBossXp XP · +$kBossCoins coins'
                  : '$kBossDesc  (+$kBossXp XP, +$kBossCoins coins)',
              style: const TextStyle(color: kTextTertiary, fontSize: 11)),
          const SizedBox(height: 8),
          Text(
              'Season ${appState.currentSeason + 1} · ${appState.seasonBossDefeats}/4 bosses',
              style: const TextStyle(
                  color: kCyan, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _QuestsPanel extends StatelessWidget {
  const _QuestsPanel();
  @override
  Widget build(BuildContext context) {
    final claimed = appState.questClaimedIds;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('DAILY QUESTS',
                  style: TextStyle(
                      color: kTextTertiary,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold)),
              Text('${claimed.length}/${kQuests.length}',
                  style:
                      const TextStyle(color: kCyan, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          ...kQuests.map((q) {
            final on = claimed.contains(q.id);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 18, color: on ? kGreen : kTextTertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(q.title,
                      style: TextStyle(
                        color: on ? kTextTertiary : kTextPrimary,
                        fontSize: 13,
                        decoration: on ? TextDecoration.lineThrough : null,
                      )),
                ),
                Text('+${q.xp}',
                    style: TextStyle(
                        color: on ? kGreen : kPlasmaGlow,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ]),
            );
          }),
        ],
      ),
    );
  }
}

void _showBossDefeat(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF3A2A08), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kGold),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_rounded, color: kGold, size: 44),
            const SizedBox(height: 10),
            const Text('BOSS DEFEATED',
                style: TextStyle(
                    color: kGold,
                    fontSize: 18,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text('Weekly Sovereignty Challenge',
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 14),
            Text('+$kBossXp XP   ·   +$kBossCoins coins',
                style: TextStyle(
                    color: kPlasmaGlow, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(companionLine(appState.activeCompanion, 'boss_defeat'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Claim'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LevelHeader extends StatelessWidget {
  const _LevelHeader({required this.ld});
  final ({int level, int currentXp, int requiredXp, double progress}) ld;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF2A1458), Color(0xFF160B2E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [kPlasma, kBlue]),
              ),
              child: Text('${ld.level}',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(levelTitle(ld.level).toUpperCase(),
                      style: GoogleFonts.spaceGrotesk(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text('Level ${ld.level}',
                        style: const TextStyle(
                            color: kTextTertiary, fontSize: 12)),
                    if (appState.prestige > 0) ...[
                      const SizedBox(width: 6),
                      Text('★' * appState.prestige,
                          style: const TextStyle(color: kGold, fontSize: 12)),
                    ],
                  ]),
                ],
              ),
            ),
            Text('${appState.doneTodayCount}/${appState.habits.length} today',
                style: const TextStyle(color: kCyan, fontSize: 13)),
          ]),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ld.progress.clamp(0.0, 1.0).toDouble(),
              minHeight: 9,
              backgroundColor: const Color(0x14FFFFFF),
              valueColor: AlwaysStoppedAnimation<Color>(kPlasmaBright),
            ),
          ),
          const SizedBox(height: 6),
          Text('${ld.currentXp} / ${ld.requiredXp} XP',
              style: const TextStyle(color: kTextSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.habit,
    required this.done,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });
  final Habit habit;
  final bool done;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final rc = rarityConfig[habit.rarity];
    final rarityColor = rc?.color ?? kTextTertiary;
    return Dismissible(
      key: ValueKey(habit.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
            color: const Color(0xFF3A1020),
            borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.delete_outline, color: Color(0xFFFB7185)),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: done ? kPlasma : kBorder),
        ),
        child: ListTile(
          onTap: onToggle,
          onLongPress: onEdit,
          leading: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? kPlasma : Colors.transparent,
              border: Border.all(
                  color: done ? kPlasma : const Color(0x4DFFFFFF), width: 2),
            ),
            child: done
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : null,
          ),
          title: Text(
              habit.icon.isEmpty ? habit.name : '${habit.icon}  ${habit.name}',
              style: TextStyle(
                color: done ? kTextTertiary : kTextPrimary,
                decoration: done ? TextDecoration.lineThrough : null,
                fontWeight: FontWeight.w500,
              )),
          subtitle: Row(children: [
            Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: rarityColor)),
            const SizedBox(width: 6),
            Text(rc?.label ?? 'Common',
                style: TextStyle(color: rarityColor, fontSize: 11)),
          ]),
          trailing: habit.streak > 0
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: const Color(0x268B5CF6),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text('🔥 ${habit.streak}',
                      style: TextStyle(
                          color: kPlasmaGlow, fontWeight: FontWeight.bold)),
                )
              : null,
        ),
      ),
    );
  }
}

// ── FOCUS ───────────────────────────────────────────────────────────────────
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});
  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  int _minutes = 25;
  int _remaining = 25 * 60;
  bool _running = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _setMinutes(int m) {
    if (_running) return;
    setState(() {
      _minutes = m;
      _remaining = m * 60;
    });
  }

  void _start() {
    setState(() => _running = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        final gain = appState.completeFocus(_minutes);
        setState(() {
          _running = false;
          _remaining = _minutes * 60;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: kElevated,
            content: Text('Focus complete! +$gain XP',
                style: TextStyle(color: kPlasmaGlow)),
          ));
        }
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _stop() {
    _timer?.cancel();
    setState(() {
      _running = false;
      _remaining = _minutes * 60;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Focus'),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Wrap(
              spacing: 10,
              children: [15, 25, 50].map((m) {
                final sel = m == _minutes;
                return ChoiceChip(
                  label: Text('$m min'),
                  selected: sel,
                  onSelected: (_) => _setMinutes(m),
                  selectedColor: kPlasma,
                  backgroundColor: kCard,
                  labelStyle: TextStyle(
                      color: sel ? Colors.white : kTextSecondary),
                  side: const BorderSide(color: kBorder),
                );
              }).toList(),
            ),
            const SizedBox(height: 32),
            Container(
              width: 230,
              height: 230,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                    colors: [Color(0xFF2A1458), Color(0xFF0B0420)]),
                border: Border.all(color: kPlasma, width: 2),
              ),
              child: Text('$mm:$ss',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 52,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: _running ? const Color(0xFF3A1020) : kPlasma,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 14)),
              onPressed: _running ? _stop : _start,
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              label: Text(_running ? 'Stop' : 'Start focus'),
            ),
            const SizedBox(height: 10),
            const Text('Finish a session to earn XP',
                style: TextStyle(color: kTextTertiary, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── STATS ───────────────────────────────────────────────────────────────────
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final stats = <(String, String, Color, IconData)>[
      ('Level', '${ld.level}', kPlasmaBright, Icons.military_tech_rounded),
      ('Title', levelTitle(ld.level), kCyan, Icons.star_rounded),
      ('Total XP', '${appState.totalXp}', kPlasma, Icons.bolt_rounded),
      ('Coins', '${appState.coins}', kGold, Icons.savings_rounded),
      ('Habits', '${appState.habits.length}', kBlue, Icons.widgets_rounded),
      ('Done today', '${appState.doneTodayCount}', kCyan,
          Icons.check_circle_rounded),
      ('Best streak', '${appState.bestStreak}', const Color(0xFFFB7185),
          Icons.local_fire_department_rounded),
      ('Reflections', '${appState.reflections.length}', kPlasmaGlow,
          Icons.menu_book_rounded),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Stats'),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Material(
              color: kCard,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LegacyScreen())),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: kBorder)),
                  child: Row(children: [
                    const Icon(Icons.history_rounded, color: kCyan, size: 22),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text('Legacy Timeline',
                          style: TextStyle(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold)),
                    ),
                    Text('${appState.milestoneLog.length}',
                        style: const TextStyle(
                            color: kCyan, fontWeight: FontWeight.bold)),
                    const Icon(Icons.chevron_right, color: kTextTertiary),
                  ]),
                ),
              ),
            ),
          ),
          const _WeekTrendCard(),
          const _HeatmapCard(),
          GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.5,
            children: stats
                .map((s) => _StatCard(
                    label: s.$1, value: s.$2, color: s.$3, icon: s.$4))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.label,
      required this.value,
      required this.color,
      required this.icon});
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 22),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              Text(label,
                  style: const TextStyle(color: kTextTertiary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── AWARDS (achievements) ────────────────────────────────────────────────────
class AwardsScreen extends StatelessWidget {
  const AwardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final unlocked = kAchievements.where((a) => a.unlocked(appState)).length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Awards'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Achievements',
                    style: TextStyle(color: kTextSecondary)),
                Text('$unlocked / ${kAchievements.length} unlocked',
                    style: const TextStyle(
                        color: kCyan, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: GridView.count(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.05,
              children:
                  kAchievements.map((a) => _AchievementCard(a)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard(this.a);
  final Achievement a;

  @override
  Widget build(BuildContext context) {
    final on = a.unlocked(appState);
    final color = rarityConfig[a.rarity]?.color ?? kTextTertiary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: on ? color : kBorder),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(on ? a.icon : Icons.lock_outline_rounded,
              size: 34, color: on ? color : kTextTertiary),
          const SizedBox(height: 10),
          Text(a.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: on ? Colors.white : kTextTertiary,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(a.description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kTextTertiary, fontSize: 11)),
        ],
      ),
    );
  }
}

// ── JOURNAL ─────────────────────────────────────────────────────────────────
class JournalScreen extends StatelessWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final items = appState.reflections;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _titleBar('Journal'),
      body: items.isEmpty
          ? const _EmptyState(
              emoji: '📓',
              title: 'No reflections yet',
              subtitle: 'Tap “Reflect” to write one (+20 XP).')
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final r = items[i];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.date,
                          style: const TextStyle(
                              color: kCyan,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(r.text,
                          style: const TextStyle(color: kTextPrimary)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState(
      {required this.emoji, required this.title, required this.subtitle});
  final String emoji;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(color: kTextSecondary, fontSize: 18)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: kTextTertiary)),
        ],
      ),
    );
  }
}

void _showLevelUp(BuildContext context, int level) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF2A1458), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kPlasmaBright),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('⚡ LEVEL UP',
                style: TextStyle(
                    color: kPlasmaGlow,
                    fontSize: 13,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text('$level',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 56,
                    fontWeight: FontWeight.w800)),
            Text(levelTitle(level).toUpperCase(),
                style: const TextStyle(
                    color: kCyan,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(companionLine(appState.activeCompanion, 'level_up'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPlasma),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showHabitEditor(BuildContext context, [Habit? existing]) async {
  final controller = TextEditingController(text: existing?.name ?? '');
  // The current difficulty decision — the AI (or heuristic) owns this; the user
  // no longer picks it. It's frozen onto the habit when they tap Add/Save.
  DifficultyVerdict verdict = existing != null
      ? DifficultyVerdict(existing.rarity, existing.difficultyReason,
          fromAi: existing.aiRated)
      : heuristicVerdict(controller.text);
  bool analyzing = false;
  Timer? debounce;
  int reqSeq = 0; // drops stale async results from earlier keystrokes
  String icon = existing?.icon ?? '';
  const emojis = [
    '💧', '📖', '🏋️', '😴', '🧘', '🏃', '🥗', '💻',
    '🎯', '✍️', '🎸', '☀️', '🧠', '💰', '🌱', '🚭'
  ];
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Re-rate the habit: show the instant heuristic now, then let the local
        // Ollama model refine it shortly after the user stops typing.
        void analyze(String name) {
          debounce?.cancel();
          final instant = heuristicVerdict(name);
          if (name.trim().isEmpty || !appState.aiEnabled) {
            setLocal(() {
              verdict = instant;
              analyzing = false;
            });
            return;
          }
          final seq = ++reqSeq;
          setLocal(() {
            verdict = instant;
            analyzing = true;
          });
          debounce = Timer(const Duration(milliseconds: 650), () async {
            final v = await classifyDifficulty(name,
                enabled: appState.aiEnabled,
                baseUrl: appState.aiBaseUrl,
                model: appState.aiModel);
            if (!ctx.mounted || seq != reqSeq) return;
            setLocal(() {
              verdict = v;
              analyzing = false;
            });
          });
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? 'New habit' : 'Edit habit',
                  style: GoogleFonts.spaceGrotesk(
                      color: kTextPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: existing == null,
                style: const TextStyle(color: kTextPrimary),
                textCapitalization: TextCapitalization.sentences,
                decoration:
                    const InputDecoration(hintText: 'e.g. Meditate 10 min'),
                onChanged: analyze,
              ),
              const SizedBox(height: 14),
              const Text('Icon',
                  style: TextStyle(color: kTextTertiary, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: emojis.map((e) {
                  final sel = e == icon;
                  return GestureDetector(
                    onTap: () => setLocal(() => icon = sel ? '' : e),
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: sel ? kPlasma : kElevated,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: sel ? kPlasma : kBorder)),
                      child: Text(e, style: const TextStyle(fontSize: 20)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              _difficultyCard(verdict, analyzing),
              const SizedBox(height: 18),
              Row(children: [
                if (existing != null)
                  TextButton.icon(
                      onPressed: () {
                        appState.deleteHabit(existing);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline, color: kRed),
                      label: const Text('Delete',
                          style: TextStyle(color: kRed))),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kPlasma),
                  onPressed: () {
                    final name = controller.text.trim();
                    if (name.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    debounce?.cancel();
                    final v = verdict;
                    if (existing == null) {
                      appState.addHabit(name, v.rarity,
                          icon: icon, aiRated: v.fromAi, reason: v.reason);
                    } else {
                      appState.editHabit(existing,
                          name: name,
                          rarity: v.rarity,
                          icon: icon,
                          aiRated: v.fromAi,
                          reason: v.reason);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(existing == null ? 'Add' : 'Save'),
                ),
              ]),
            ],
          ),
        );
      },
    ),
  );
  debounce?.cancel();
}

/// Shows the AI/heuristic difficulty verdict — the user can't change it.
Widget _difficultyCard(DifficultyVerdict v, bool analyzing) {
  final color = rarityConfig[v.rarity]?.color ?? kTextTertiary;
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: kElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder)),
    child: Row(children: [
      Icon(Icons.auto_awesome_rounded, size: 18, color: color),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Flexible(
                child: Text('${v.label} · ×${v.multiplier} · ~${estimatedXp(v.rarity)} XP',
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
              const SizedBox(width: 8),
              _ratingChip(v, analyzing),
            ]),
            const SizedBox(height: 3),
            Text(
                analyzing
                    ? 'Reading your habit…'
                    : (v.reason.isEmpty ? 'Difficulty set automatically' : v.reason),
                style: const TextStyle(color: kTextSecondary, fontSize: 11)),
          ],
        ),
      ),
    ]),
  );
}

Widget _ratingChip(DifficultyVerdict v, bool analyzing) {
  if (analyzing) {
    return SizedBox(
      width: 13,
      height: 13,
      child: CircularProgressIndicator(strokeWidth: 2, color: kPlasmaBright),
    );
  }
  final ai = v.fromAi;
  final label = ai ? '🤖 AI' : '✨ Auto';
  final c = ai ? kCyan : kTextTertiary;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.4))),
    child: Text(label,
        style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

Future<void> showAddReflection(BuildContext context) async {
  final controller = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Reflection', style: TextStyle(color: kTextPrimary)),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        style: const TextStyle(color: kTextPrimary),
        textCapitalization: TextCapitalization.sentences,
        decoration:
            const InputDecoration(hintText: 'How did today go?'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (text != null && text.isNotEmpty) appState.addReflection(text);
}

// ── NUTRITION ────────────────────────────────────────────────────────────────
class _NutritionCard extends StatelessWidget {
  const _NutritionCard();
  @override
  Widget build(BuildContext context) {
    final n = appState.todayNutrition();
    final t = appState.targets();
    final score = appState.nutritionScore();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NutritionScreen())),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kBorder),
            ),
            child: Row(children: [
              const Icon(Icons.restaurant_rounded, color: kGreen, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('NUTRITION',
                        style: TextStyle(
                            color: kTextTertiary,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 3),
                    Text(
                        '${n.calories.round()} / ${t.calories.round()} kcal · ${n.protein.round()}g protein',
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Text('$score',
                  style: GoogleFonts.spaceGrotesk(
                      color: kGreen, fontSize: 20, fontWeight: FontWeight.w800)),
              const Icon(Icons.chevron_right, color: kTextTertiary),
            ]),
          ),
        ),
      ),
    );
  }
}

class NutritionScreen extends StatelessWidget {
  const NutritionScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final n = appState.todayNutrition();
        final today = dateKey(DateTime.now());
        final todays =
            appState.foodLog.where((e) => e.date == today).toList();
        final score = appState.nutritionScore();
        final t = appState.targets();
        final p = appState.bodyProfile;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Nutrition',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showAddFood(context),
            backgroundColor: kPlasma,
            icon: const Icon(Icons.add),
            label: const Text('Log food'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('NUTRITION SCORE',
                              style: TextStyle(
                                  color: kTextTertiary,
                                  fontSize: 11,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.bold)),
                          Text('$score / 100',
                              style: GoogleFonts.spaceGrotesk(
                                  color: kGreen,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    const Icon(Icons.restaurant_rounded,
                        color: kGreen, size: 32),
                  ]),
                  const SizedBox(height: 14),
                  _macroBar('Calories', n.calories, t.calories, 'kcal', kGold),
                  _macroBar('Protein', n.protein, t.protein, 'g', kRed),
                  _macroBar('Carbs', n.carbs, t.carbs, 'g', kCyan),
                  _macroBar('Fat', n.fat, t.fat, 'g', kPlasmaBright),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: Text(
                          p == null
                              ? 'Targets: defaults'
                              : 'TDEE ${computeTDEE(p).round()} kcal · ${p.goal}',
                          style: const TextStyle(
                              color: kTextTertiary, fontSize: 11)),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const BodyProfileScreen())),
                      icon: Icon(Icons.person_rounded,
                          size: 16, color: kPlasmaBright),
                      label: Text(
                          p == null ? 'Set body profile' : 'Edit profile',
                          style: TextStyle(color: kPlasmaBright)),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              if (todays.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyState(
                      emoji: '🍎',
                      title: 'No food logged today',
                      subtitle: 'Tap “Log food” to add a meal.'),
                )
              else
                ...todays.map((e) => _FoodTile(e)),
            ],
          ),
        );
      },
    );
  }
}

Widget _macroBar(
    String label, double value, double target, String unit, Color color) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(color: kTextSecondary, fontSize: 12)),
            Text('${value.round()} / ${target.round()} $unit',
                style: const TextStyle(color: kTextTertiary, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (target <= 0 ? 0.0 : value / target).clamp(0.0, 1.0).toDouble(),
            minHeight: 7,
            backgroundColor: const Color(0x14FFFFFF),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    ),
  );
}

class _FoodTile extends StatelessWidget {
  const _FoodTile(this.e);
  final FoodEntry e;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.name,
                  style: const TextStyle(
                      color: kTextPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                  '${e.calories.round()} kcal · P${e.protein.round()} C${e.carbs.round()} F${e.fat.round()}',
                  style: const TextStyle(color: kTextTertiary, fontSize: 12)),
            ],
          ),
        ),
        IconButton(
            icon: const Icon(Icons.close, color: kTextTertiary, size: 18),
            onPressed: () => appState.deleteFood(e)),
      ]),
    );
  }
}

double _parseNum(String s) => double.tryParse(s.trim()) ?? 0;

Widget _numField(TextEditingController c, String label, TextInputType kb) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        keyboardType: kb,
        style: const TextStyle(color: kTextPrimary),
        decoration: InputDecoration(labelText: label),
      ),
    );

Future<void> showAddFood(BuildContext context) async {
  final name = TextEditingController();
  final cal = TextEditingController();
  final p = TextEditingController();
  final c = TextEditingController();
  final f = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Log food', style: TextStyle(color: kTextPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _numField(name, 'Food name', TextInputType.text),
            _numField(cal, 'Calories (kcal)', TextInputType.number),
            _numField(p, 'Protein (g)', TextInputType.number),
            _numField(c, 'Carbs (g)', TextInputType.number),
            _numField(f, 'Fat (g)', TextInputType.number),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  if (ok == true) {
    final nm = name.text.trim().isEmpty ? 'Food' : name.text.trim();
    appState.addFood(nm, _parseNum(cal.text), _parseNum(p.text),
        _parseNum(c.text), _parseNum(f.text));
  }
}

// ── COMPANIONS ───────────────────────────────────────────────────────────────
class _CompanionOrb extends StatelessWidget {
  const _CompanionOrb(
      {required this.color, required this.icon, required this.size});
  final Color color;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0.25)]),
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 16,
              spreadRadius: 1),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
  }
}

class _CompanionCard extends StatelessWidget {
  const _CompanionCard();
  @override
  Widget build(BuildContext context) {
    final c = companionByType(appState.activeCompanion);
    final stage = companionStage(appState.level);
    final line = appState.lastCompanionLine.isEmpty
        ? c.tagline
        : appState.lastCompanionLine;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CompanionsScreen())),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder)),
            child: Row(children: [
              _CompanionOrb(color: c.color, icon: c.icon, size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(c.name,
                          style: const TextStyle(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: const Color(0x268B5CF6),
                            borderRadius: BorderRadius.circular(10)),
                        child: Text('Stage $stage',
                            style: TextStyle(
                                color: kPlasmaGlow,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 3),
                    Text('"$line"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kTextSecondary,
                            fontSize: 12,
                            fontStyle: FontStyle.italic)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: kTextTertiary),
            ]),
          ),
        ),
      ),
    );
  }
}

class CompanionsScreen extends StatelessWidget {
  const CompanionsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Companions',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.92,
            children: kCompanions.map((c) {
              final unlocked = appState.companionUnlocked(c.type);
              final active = appState.activeCompanion == c.type;
              return GestureDetector(
                onTap: unlocked ? () => appState.setCompanion(c.type) : null,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: active ? c.color : kBorder,
                        width: active ? 2 : 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Opacity(
                        opacity: unlocked ? 1 : 0.35,
                        child: _CompanionOrb(
                            color: c.color,
                            icon: unlocked
                                ? c.icon
                                : Icons.lock_outline_rounded,
                            size: 54),
                      ),
                      const SizedBox(height: 10),
                      Text(c.name,
                          style: TextStyle(
                              color:
                                  unlocked ? kTextPrimary : kTextTertiary,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(unlocked ? c.tagline : 'Unlock at Lv ${c.unlockLevel}',
                          textAlign: TextAlign.center,
                          style:
                              const TextStyle(color: kTextTertiary, fontSize: 11)),
                      if (active) ...[
                        const SizedBox(height: 6),
                        const Text('ACTIVE',
                            style: TextStyle(
                                color: kCyan,
                                fontSize: 10,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.bold)),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ── PRESTIGE & SEASONS ───────────────────────────────────────────────────────
class _PrestigeCard extends StatelessWidget {
  const _PrestigeCard();
  @override
  Widget build(BuildContext context) {
    final can = appState.canPrestige;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: appState.prestige > 0 ? kGold : kBorder),
      ),
      child: Row(children: [
        const Icon(Icons.auto_awesome_rounded, color: kGold, size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('PRESTIGE',
                    style: TextStyle(
                        color: kTextTertiary,
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold)),
                if (appState.prestige > 0) ...[
                  const SizedBox(width: 8),
                  Text('★' * appState.prestige,
                      style: const TextStyle(color: kGold, fontSize: 13)),
                ],
              ]),
              const SizedBox(height: 3),
              Text(
                  can
                      ? 'Rebirth to Lv 1 for a permanent ★ (+5% XP each)'
                      : 'Unlocks at Level $kPrestigeMinLevel',
                  style: const TextStyle(color: kTextSecondary, fontSize: 12)),
            ],
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: can ? kGold : kElevated,
              foregroundColor: can ? Colors.black : kTextTertiary),
          onPressed: can ? () => _confirmPrestige(context) : null,
          child: const Text('Prestige'),
        ),
      ]),
    );
  }
}

Future<void> _confirmPrestige(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Prestige?', style: TextStyle(color: kTextPrimary)),
      content: const Text(
          'This rebirths you to Level 1 and resets your XP, but grants a permanent ★ and +5% XP per star. Your habits, streaks, and coins are kept.',
          style: TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kGold, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Prestige'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState
        .setCompanionLine(companionLine(appState.activeCompanion, 'prestige'));
    appState.doPrestige();
    if (context.mounted) _showPrestige(context, appState.prestige);
  }
}

void _showPrestige(BuildContext context, int prestige) {
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF3A2A08), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kGold),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_rounded, color: kGold, size: 46),
            const SizedBox(height: 10),
            const Text('PRESTIGE',
                style: TextStyle(
                    color: kGold,
                    fontSize: 18,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('★' * prestige,
                style: const TextStyle(color: kGold, fontSize: 26)),
            const SizedBox(height: 8),
            const Text('Reborn as Initiate — stronger than before.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 10),
            Text(companionLine(appState.activeCompanion, 'prestige'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: kTextSecondary,
                    fontStyle: FontStyle.italic,
                    fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kGold, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Rise'),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showSeasonIntro(BuildContext context) {
  final s = appState.currentSeason + 1;
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            colors: [Color(0xFF0B2A4A), Color(0xFF160B2E)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: kCyan),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public_rounded, color: kCyan, size: 44),
            const SizedBox(height: 10),
            const Text('NEW SEASON',
                style: TextStyle(
                    color: kCyan,
                    fontSize: 14,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Season $s',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 40,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Four bosses fell. A new season begins.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary)),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: kCyan, foregroundColor: Colors.black),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Begin'),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── BODY PROFILE ─────────────────────────────────────────────────────────────
Widget _dropdown(String label, String value, Map<String, String> opts,
        ValueChanged<String> onChanged) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        dropdownColor: kElevated,
        decoration: InputDecoration(labelText: label),
        items: opts.entries
            .map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value,
                    style: const TextStyle(color: kTextPrimary))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );

class BodyProfileScreen extends StatefulWidget {
  const BodyProfileScreen({super.key});
  @override
  State<BodyProfileScreen> createState() => _BodyProfileScreenState();
}

class _BodyProfileScreenState extends State<BodyProfileScreen> {
  late final TextEditingController _weight;
  late final TextEditingController _height;
  late final TextEditingController _age;
  String _gender = 'male';
  String _activity = 'moderate';
  String _goal = 'maintain';

  @override
  void initState() {
    super.initState();
    final p = appState.bodyProfile;
    _weight = TextEditingController(
        text: p != null ? p.weight.toStringAsFixed(0) : '');
    _height = TextEditingController(
        text: p != null ? p.height.toStringAsFixed(0) : '');
    _age = TextEditingController(text: p != null ? p.age.toString() : '');
    if (p != null) {
      _gender = p.gender;
      _activity = p.activity;
      _goal = p.goal;
    }
  }

  @override
  void dispose() {
    _weight.dispose();
    _height.dispose();
    _age.dispose();
    super.dispose();
  }

  void _save() {
    final w = double.tryParse(_weight.text.trim()) ?? 0;
    final h = double.tryParse(_height.text.trim()) ?? 0;
    final a = int.tryParse(_age.text.trim()) ?? 0;
    if (w <= 0 || h <= 0 || a <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter a valid weight, height, and age')));
      return;
    }
    appState.setBodyProfile(BodyProfile(
        weight: w,
        height: h,
        age: a,
        gender: _gender,
        activity: _activity,
        goal: _goal));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final w = double.tryParse(_weight.text) ?? 0;
    final h = double.tryParse(_height.text) ?? 0;
    final a = int.tryParse(_age.text) ?? 0;
    final preview = (w > 0 && h > 0 && a > 0)
        ? computeMacroTargets(BodyProfile(
            weight: w,
            height: h,
            age: a,
            gender: _gender,
            activity: _activity,
            goal: _goal))
        : null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Body Profile',
            style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.bold, color: kTextPrimary)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _numField(_weight, 'Weight (kg)', TextInputType.number),
          _numField(_height, 'Height (cm)', TextInputType.number),
          _numField(_age, 'Age', TextInputType.number),
          _dropdown('Gender', _gender, const {'male': 'Male', 'female': 'Female'},
              (v) => setState(() => _gender = v)),
          _dropdown(
              'Activity',
              _activity,
              const {
                'sedentary': 'Sedentary',
                'light': 'Light',
                'moderate': 'Moderate',
                'active': 'Active',
                'very_active': 'Very active'
              },
              (v) => setState(() => _activity = v)),
          _dropdown(
              'Goal',
              _goal,
              const {
                'cut': 'Cut (lose fat)',
                'maintain': 'Maintain',
                'bulk': 'Bulk (gain)'
              },
              (v) => setState(() => _goal = v)),
          const SizedBox(height: 16),
          if (preview != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('COMPUTED TARGETS',
                      style: TextStyle(
                          color: kTextTertiary,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                      '${preview.calories.round()} kcal · P${preview.protein.round()} C${preview.carbs.round()} F${preview.fat.round()}',
                      style: const TextStyle(
                          color: kTextPrimary, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: kPlasma,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _save,
            child: const Text('Save profile'),
          ),
        ],
      ),
    );
  }
}

// ── LEGACY TIMELINE ──────────────────────────────────────────────────────────
IconData _milestoneIcon(String type) {
  switch (type) {
    case 'boss_defeat':
      return Icons.shield_rounded;
    case 'prestige':
      return Icons.auto_awesome_rounded;
    case 'season':
      return Icons.public_rounded;
    case 'streak':
      return Icons.local_fire_department_rounded;
    default:
      return Icons.trending_up_rounded; // level_up
  }
}

Color _milestoneColor(String type) {
  switch (type) {
    case 'boss_defeat':
    case 'prestige':
      return kGold;
    case 'season':
      return kCyan;
    case 'streak':
      return kRed;
    default:
      return kPlasmaBright;
  }
}

String _fmtDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${months[d.month - 1]} ${d.day} · $hh:$mm';
}

Widget _bestChip(String label, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: kElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: kTextTertiary, fontSize: 11)),
        ],
      ),
    );

class LegacyScreen extends StatelessWidget {
  const LegacyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final log = appState.milestoneLog;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Legacy',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('CAREER BESTS',
                        style: TextStyle(
                            color: kTextTertiary,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      _bestChip('Peak level', '${appState.highestLevel}'),
                      _bestChip('Prestige', '★${appState.prestige}'),
                      _bestChip('Bosses', '${appState.totalBossDefeats}'),
                      _bestChip('Season', '${appState.currentSeason + 1}'),
                      _bestChip('Best streak', '${appState.bestStreak}'),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (log.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyState(
                      emoji: '📜',
                      title: 'No milestones yet',
                      subtitle: 'Level up, defeat the boss, or hit a streak.'),
                )
              else
                ...log.map((m) => _MilestoneTile(m)),
            ],
          ),
        );
      },
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile(this.m);
  final MilestoneEvent m;
  @override
  Widget build(BuildContext context) {
    final color = _milestoneColor(m.type);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
          child: Icon(_milestoneIcon(m.type), color: color, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.description,
                  style: const TextStyle(
                      color: kTextPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(_fmtDate(m.date),
                  style: const TextStyle(color: kTextTertiary, fontSize: 11)),
            ],
          ),
        ),
        if (m.xp > 0)
          Text('+${m.xp}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      ]),
    );
  }
}

// ── SETTINGS & ACCOUNT ───────────────────────────────────────────────────────
Widget _settingsTile(IconData icon, String title, String subtitle,
    VoidCallback? onTap,
    {bool danger = false}) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Row(children: [
            Icon(icon, color: danger ? kRed : kPlasmaBright, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: danger ? kRed : kTextPrimary,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style:
                          const TextStyle(color: kTextTertiary, fontSize: 11)),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: kTextTertiary),
          ]),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(s,
          style: const TextStyle(
              color: kTextTertiary,
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold)),
    );

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final ld = levelFromXp(appState.totalXp);
        final initial = appState.displayName.isNotEmpty
            ? appState.displayName[0].toUpperCase()
            : '?';
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Settings',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Account header
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Row(children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [kPlasma, kBlue])),
                    child: Text(initial,
                        style: GoogleFonts.spaceGrotesk(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(appState.displayName,
                            style: const TextStyle(
                                color: kTextPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                        Text('Level ${ld.level} · ${levelTitle(ld.level)}',
                            style: const TextStyle(
                                color: kTextTertiary, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                      icon: Icon(Icons.edit,
                          color: kPlasmaBright, size: 18),
                      onPressed: () => _editName(context)),
                ]),
              ),
              _sectionLabel('ACCOUNT'),
              _settingsTile(Icons.cloud_off_rounded, 'Cloud sync & sign-in',
                  'Local account — Apple/Supabase sign-in coming soon', null),
              _sectionLabel('PREFERENCES'),
              _settingsTile(
                  Icons.palette_rounded,
                  'Appearance',
                  'Pick an accent theme',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AppearanceScreen()))),
              _settingsTile(
                  Icons.person_rounded,
                  'Body profile',
                  'Weight, height, goal → nutrition targets',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const BodyProfileScreen()))),
              _settingsTile(
                  Icons.pets_rounded,
                  'Companion',
                  'Choose your active companion',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const CompanionsScreen()))),
              _settingsTile(
                  Icons.auto_awesome_rounded,
                  'AI difficulty',
                  appState.aiEnabled
                      ? 'Ollama rates new habits · ${appState.aiModel}'
                      : 'Off — using the built-in estimate',
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AiSettingsScreen()))),
              _sectionLabel('DATA'),
              _settingsTile(Icons.refresh_rounded, 'Reset all progress',
                  'Wipe habits, XP, and history',
                  () => _confirmReset(context),
                  danger: true),
              const SizedBox(height: 20),
              const Center(
                child: Text('Habitrail · v1.0.0\nRebuilt from the Habitrail web app',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextTertiary, fontSize: 11)),
              ),
            ],
          ),
        );
      },
    );
  }
}

Future<void> _editName(BuildContext context) async {
  final c = TextEditingController(text: appState.displayName);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Your name', style: TextStyle(color: kTextPrimary)),
      content: TextField(
        controller: c,
        autofocus: true,
        style: const TextStyle(color: kTextPrimary),
        decoration: const InputDecoration(hintText: 'Display name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: kPlasma),
          onPressed: () => Navigator.pop(ctx, c.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name != null && name.isNotEmpty) appState.setDisplayName(name);
}

Future<void> _confirmReset(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Reset all progress?',
          style: TextStyle(color: kTextPrimary)),
      content: const Text(
          'This permanently clears your habits, XP, coins, streaks, nutrition, companions, prestige, and history. It cannot be undone.',
          style: TextStyle(color: kTextSecondary)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kRed, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    appState.resetAll();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Progress reset')));
  }
}

// ── AI DIFFICULTY (local Ollama) ─────────────────────────────────────────────
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});
  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: appState.aiBaseUrl);
  late final TextEditingController _model =
      TextEditingController(text: appState.aiModel);
  bool _testing = false;
  bool _testOk = false;
  String? _testResult;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    // Save what's on screen, then test exactly that.
    appState.setAiConfig(baseUrl: _url.text, model: _model.text);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await testOllama(_url.text, _model.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = r.ok;
      _testResult = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final on = appState.aiEnabled;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('AI difficulty',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.auto_awesome_rounded, color: kCyan, size: 20),
                      const SizedBox(width: 8),
                      Text('How it works',
                          style: GoogleFonts.spaceGrotesk(
                              color: kTextPrimary,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                      'When you add a habit, a local AI model reads it and picks a '
                      'difficulty — harder habits earn a bigger XP multiplier. The '
                      'rating is locked in when the habit is created, so XP stays '
                      'fair and the app still works offline (it falls back to a '
                      'built-in estimate whenever the model isn\'t running).',
                      style: TextStyle(
                          color: kTextSecondary, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder)),
                child: SwitchListTile(
                  value: on,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  title: const Text('Use Ollama',
                      style: TextStyle(
                          color: kTextPrimary, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Rate new habits with a local model',
                      style: TextStyle(color: kTextTertiary, fontSize: 12)),
                  onChanged: (v) => appState.setAiConfig(enabled: v),
                ),
              ),
              const SizedBox(height: 16),
              _aiField('Server URL', _url, 'http://localhost:11434',
                  enabled: on,
                  onChanged: (v) => appState.setAiConfig(baseUrl: v)),
              const SizedBox(height: 12),
              _aiField('Model', _model, kDefaultAiModel,
                  enabled: on, onChanged: (v) => appState.setAiConfig(model: v)),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: on ? kPlasma : kElevated,
                    minimumSize: const Size.fromHeight(46)),
                onPressed: on && !_testing ? _test : null,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: Text(_testing ? 'Testing…' : 'Test connection'),
              ),
              if (_testResult != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: (_testOk ? kGreen : kRed).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: (_testOk ? kGreen : kRed)
                              .withValues(alpha: 0.4))),
                  child: Row(children: [
                    Icon(_testOk ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: _testOk ? kGreen : kRed, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_testResult!,
                          style: TextStyle(
                              color: _testOk ? kGreen : kRed, fontSize: 12)),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              _sectionLabel('SETUP'),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 2, 4, 0),
                child: Text(
                  '1. Install Ollama from ollama.com\n'
                  '2. Run:  ollama pull llama3.2\n'
                  '3. Keep Ollama running while you add habits.\n\n'
                  'On a real iPhone later, Ollama runs on your computer, not the '
                  'phone — set the Server URL to your computer\'s address, e.g. '
                  'http://192.168.1.20:11434, or leave AI off to use the built-in '
                  'estimate.',
                  style: TextStyle(
                      color: kTextTertiary, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _aiField(String label, TextEditingController c, String hint,
    {required bool enabled, required ValueChanged<String> onChanged}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(label,
            style: const TextStyle(color: kTextTertiary, fontSize: 12)),
      ),
      TextField(
        controller: c,
        enabled: enabled,
        style: const TextStyle(color: kTextPrimary),
        decoration: InputDecoration(hintText: hint),
        onChanged: onChanged,
      ),
    ],
  );
}

// ── APPEARANCE (themes) ──────────────────────────────────────────────────────
Widget _swatch(Color c) => Container(
      width: 22,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );

void _toast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: kElevated));

Widget _shopItem({
  required IconData icon,
  required Color color,
  required String title,
  required String desc,
  required int cost,
  required VoidCallback? onBuy,
  String? activeLabel,
}) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder)),
    child: Row(children: [
      Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: color.withValues(alpha: 0.15)),
        child: Icon(icon, color: color),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: kTextPrimary, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(desc,
                style: const TextStyle(color: kTextTertiary, fontSize: 11)),
          ],
        ),
      ),
      const SizedBox(width: 10),
      if (activeLabel != null)
        Text(activeLabel,
            style: const TextStyle(
                color: kGreen, fontWeight: FontWeight.bold, fontSize: 11))
      else
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: onBuy == null ? kElevated : kPlasma,
              foregroundColor: Colors.white),
          onPressed: onBuy,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.bolt, size: 14, color: kGold),
            const SizedBox(width: 3),
            Text('$cost'),
          ]),
        ),
    ]),
  );
}

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Shop',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF2A1458), Color(0xFF160B2E)]),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kBorder)),
                child: Row(children: [
                  const Icon(Icons.bolt, color: kGold, size: 28),
                  const SizedBox(width: 10),
                  Text('${appState.coins}',
                      style: GoogleFonts.spaceGrotesk(
                          color: kGold,
                          fontSize: 28,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(width: 8),
                  const Text('coins', style: TextStyle(color: kTextSecondary)),
                ]),
              ),
              const SizedBox(height: 8),
              _shopItem(
                icon: Icons.bolt_rounded,
                color: kGold,
                title: '2× XP Booster',
                desc: appState.xpBoostActive
                    ? 'Active for the rest of today'
                    : 'Double all XP you earn today',
                cost: 150,
                onBuy: appState.xpBoostActive
                    ? null
                    : () => _toast(
                        context,
                        appState.buyXpBoost()
                            ? '2× XP active for today!'
                            : 'Not enough coins'),
                activeLabel: appState.xpBoostActive ? 'ACTIVE' : null,
              ),
              _shopItem(
                icon: Icons.shield_rounded,
                color: kCyan,
                title: 'Streak Shield',
                desc:
                    'Saves a streak from one missed day · owned: ${appState.streakShields}',
                cost: 100,
                onBuy: () => _toast(
                    context,
                    appState.buyStreakShield()
                        ? 'Streak Shield added!'
                        : 'Not enough coins'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── CONFETTI ─────────────────────────────────────────────────────────────────
void celebrate(BuildContext context) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: _Confetti(onDone: () => entry.remove()),
    ),
  );
  overlay.insert(entry);
}

class _Confo {
  _Confo(this.x, this.vx, this.delay, this.rot, this.vr, this.color, this.size);
  final double x, vx, delay, rot, vr, size;
  final Color color;
}

class _Confetti extends StatefulWidget {
  const _Confetti({required this.onDone});
  final VoidCallback onDone;
  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final List<_Confo> _p = [];

  @override
  void initState() {
    super.initState();
    final r = Random();
    final colors = [
      kPlasma, kCyan, kGold, const Color(0xFFF472B6), kGreen, kBlue
    ];
    for (int i = 0; i < 80; i++) {
      _p.add(_Confo(
        r.nextDouble(),
        (r.nextDouble() - 0.5) * 0.4,
        r.nextDouble() * 0.25,
        r.nextDouble() * 6.28,
        (r.nextDouble() - 0.5) * 10,
        colors[r.nextInt(colors.length)],
        6 + r.nextDouble() * 7,
      ));
    }
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1900))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
            size: Size.infinite, painter: _ConfettiPainter(_p, _c.value)),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.ps, this.t);
  final List<_Confo> ps;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final c in ps) {
      final denom = 1 - c.delay;
      final p = denom <= 0 ? t : (t - c.delay) / denom;
      if (p <= 0) continue;
      final pc = p.clamp(0.0, 1.0);
      final y = (pc * pc * 0.5 + pc * 0.6) * size.height * 1.1;
      final x = (c.x + c.vx * pc) * size.width;
      paint.color = c.color.withValues(alpha: (1 - pc).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(c.rot + c.vr * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset.zero, width: c.size, height: c.size * 0.6),
            const Radius.circular(1.5)),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}

class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard();
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final todayK = dateKey(now);
    const n = 35; // 5 weeks
    final cells = <({int score, bool today})>[];
    for (int i = n - 1; i >= 0; i--) {
      final k = dateKey(now.subtract(Duration(days: i)));
      cells.add((score: appState.dailyScore[k] ?? 0, today: k == todayK));
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ACTIVITY · LAST 5 WEEKS',
              style: TextStyle(
                  color: kTextTertiary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 7,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: cells.map((c) {
              final on = c.score > 0;
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: on
                      ? victoryColor(c.score)
                          .withValues(alpha: 0.25 + c.score / 100 * 0.75)
                      : const Color(0x14FFFFFF),
                  border: c.today
                      ? Border.all(color: Colors.white, width: 1)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _WeekTrendCard extends StatelessWidget {
  const _WeekTrendCard();
  @override
  Widget build(BuildContext context) {
    final days = appState.weekTrend();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('THIS WEEK · VICTORY SCORE',
              style: TextStyle(
                  color: kTextTertiary,
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: days.map((d) {
                final h = 6.0 + (d.score / 100) * 60;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('${d.score}',
                        style: const TextStyle(
                            color: kTextTertiary, fontSize: 9)),
                    const SizedBox(height: 3),
                    Container(
                      width: 22,
                      height: h,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: victoryColor(d.score)
                            .withValues(alpha: d.today ? 1 : 0.55),
                        border: d.today
                            ? Border.all(color: Colors.white, width: 1)
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(d.label,
                        style: TextStyle(
                            color: d.today ? kTextPrimary : kTextTertiary,
                            fontSize: 10,
                            fontWeight:
                                d.today ? FontWeight.bold : FontWeight.normal)),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: Text('Appearance',
                style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.bold, color: kTextPrimary)),
          ),
          body: GridView.count(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.3,
            children: kThemes.map((t) {
              final active = appState.themeId == t.id;
              return GestureDetector(
                onTap: () => appState.setTheme(t.id),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: active ? t.accent : kBorder,
                        width: active ? 2 : 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _swatch(t.accent),
                          _swatch(t.bright),
                          _swatch(t.glow),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(t.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: kTextPrimary, fontWeight: FontWeight.bold)),
                      if (active) ...[
                        const SizedBox(height: 4),
                        const Text('ACTIVE',
                            style: TextStyle(
                                color: kCyan,
                                fontSize: 10,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.bold)),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

// ── DAILY BRIEFING ───────────────────────────────────────────────────────────
Widget _briefPanel(String tag, String title, Widget body) => Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(tag,
              style: const TextStyle(
                  color: kCyan,
                  letterSpacing: 3,
                  fontSize: 12,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(title,
              textAlign: TextAlign.center,
              style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 28),
          body,
        ],
      ),
    );

class _DailyBriefing extends StatefulWidget {
  const _DailyBriefing();
  @override
  State<_DailyBriefing> createState() => _DailyBriefingState();
}

class _DailyBriefingState extends State<_DailyBriefing> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _next(int last) {
    if (_page >= last) {
      appState.markBriefingSeen();
      Navigator.of(context).pop();
    } else {
      _pc.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ld = levelFromXp(appState.totalXp);
    final v = appState.victory();
    final who = companionByType(appState.activeCompanion);
    final panels = <Widget>[
      _briefPanel(
        'BRIEFING',
        'Welcome back, ${appState.displayName}',
        Column(children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [kPlasma, kBlue])),
            child: Text('${ld.level}',
                style: GoogleFonts.spaceGrotesk(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 12),
          Text(levelTitle(ld.level).toUpperCase(),
              style: const TextStyle(
                  color: kCyan, letterSpacing: 2, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('Best streak: ${appState.bestStreak} days',
              style: const TextStyle(color: kTextSecondary)),
        ]),
      ),
      _briefPanel(
        'STATUS',
        'Today',
        Column(children: [
          SizedBox(
            width: 96,
            height: 96,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(
                width: 96,
                height: 96,
                child: CircularProgressIndicator(
                  value: v.score / 100,
                  strokeWidth: 8,
                  backgroundColor: const Color(0x14FFFFFF),
                  valueColor:
                      AlwaysStoppedAnimation<Color>(victoryColor(v.score)),
                ),
              ),
              Text('${v.score}',
                  style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          Text(victoryLabel(v.score),
              style: TextStyle(
                  color: victoryColor(v.score),
                  fontWeight: FontWeight.bold,
                  fontSize: 18)),
          const SizedBox(height: 6),
          Text(
              '${appState.doneTodayCount}/${appState.habits.length} habits · ${appState.coins} coins',
              style: const TextStyle(color: kTextSecondary)),
        ]),
      ),
      _briefPanel(
        'ORDERS',
        "Today's quests",
        Column(
          children: kQuests.map((q) {
            final on = appState.questClaimedIds.contains(q.id);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 16, color: on ? kGreen : kTextTertiary),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(q.title,
                        style: const TextStyle(
                            color: kTextSecondary, fontSize: 13))),
                Text('+${q.xp}',
                    style: TextStyle(
                        color: kPlasmaGlow,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ]),
            );
          }).toList(),
        ),
      ),
      _briefPanel(
        'DEPLOY',
        who.name,
        Column(children: [
          _CompanionOrb(color: who.color, icon: who.icon, size: 60),
          const SizedBox(height: 14),
          Text(
              '"${companionLine(appState.activeCompanion, v.score >= 90 ? 'elite_day' : 'level_up')}"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: kTextSecondary, fontStyle: FontStyle.italic)),
        ]),
      ),
    ];
    final last = panels.length - 1;
    return Dialog.fullscreen(
      backgroundColor: kBase,
      child: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              children: panels,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              panels.length,
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(4),
                width: i == _page ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i == _page ? kPlasma : const Color(0x33FFFFFF)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: kPlasma,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => _next(last),
                child: Text(_page >= last ? 'Start the day' : 'Next'),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
