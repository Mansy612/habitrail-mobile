// Screens must reflect app-state changes immediately (no stale const widgets).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:habitrail/core.dart';
import 'package:habitrail/main.dart';
import 'package:habitrail/ui/hr_theme.dart';

import '../support/app_fonts.dart';
import 'package:habitrail/ui/hr_widgets.dart';

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadAppFonts);
  SharePreferencesReset.reset();
  await tester.runAsync(appState.load);
  appState.markBriefingSeen();
  await tester.pumpWidget(MaterialApp(theme: hrTheme(), home: const HomeShell()));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Fresh, empty store for each test.
abstract final class SharePreferencesReset {
  static void reset() => SharedPreferences.setMockInitialValues({});
}

String _xpText() {
  final ld = levelFromXp(appState.totalXp);
  return '${hrNum(ld.currentXp)} / ${hrNum(ld.requiredXp)}';
}

void main() {
  testWidgets('Today level panel updates when a habit is completed', (tester) async {
    await _pumpShell(tester);
    final before = _xpText();
    expect(find.textContaining(before), findsWidgets);
    final bar = find.byType(HrXpBar).first;
    final valueBefore = tester.widget<HrXpBar>(bar).value;

    appState.toggle(appState.habits.first); // earn XP
    await tester.pump(const Duration(milliseconds: 600));

    final after = _xpText();
    expect(after, isNot(before));
    expect(find.textContaining(after), findsWidgets,
        reason: 'XP numbers must refresh');
    expect(tester.widget<HrXpBar>(find.byType(HrXpBar).first).value,
        greaterThan(valueBefore),
        reason: 'XP bar must refresh');
  });

  testWidgets('Profile level panel and coins update live', (tester) async {
    await _pumpShell(tester);
    shellTab.value = 4;
    await tester.pump(const Duration(milliseconds: 600));
    final coinsBefore = hrNum(appState.coins);
    expect(find.text(coinsBefore), findsWidgets);

    appState.toggle(appState.habits.first);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text(hrNum(appState.coins)), findsWidgets);
    expect(find.textContaining(_xpText()), findsWidgets);
    shellTab.value = 0;
  });
}
