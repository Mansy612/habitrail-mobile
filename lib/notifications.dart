// Phone notifications: habit reminders and streak alerts that arrive while
// Habitrail is closed. What to send and when is planned in core.dart
// (planNotifications); this file hands that plan to the OS and replans
// whenever progress changes.
import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'buddies.dart';
import 'core.dart';

class ReminderNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  String _scheduled = ''; // signature of the plan the OS holds
  Future<void> _queue = Future.value(); // keeps replans from interleaving
  Timer? _debounce;
  AppLifecycleListener? _lifecycle;

  /// Whether the OS lets Habitrail notify; null until checked.
  final ValueNotifier<bool?> permitted = ValueNotifier(null);

  /// A tapped notification for the app to act on: `done:<habitId>` from the
  /// "Mark done" button, else `open:<payload>`. The app clears it once handled.
  final ValueNotifier<String?> pendingAction = ValueNotifier(null);

  /// The plugin is running on this device (iOS, Android, macOS, Windows).
  bool get available => _ready;

  /// Reminders are reaching the OS, so the in-app nudge can stand down.
  bool get active => _ready && permitted.value == true && appState.remindersOn;

  static bool get _supported {
    if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  /// The bundled logo, which Windows shows on the toast (it needs a file path).
  static String? _windowsIcon() {
    final f = File('${File(Platform.resolvedExecutable).parent.path}'
        r'\data\flutter_assets\assets\branding\app_icon.png');
    return f.existsSync() ? f.path : null;
  }

  Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      // Asked for later, in context (setting a reminder, or Settings).
      final darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
        notificationCategories: [
          DarwinNotificationCategory('habit', actions: [
            DarwinNotificationAction.plain('done', 'Mark done',
                options: {DarwinNotificationActionOption.foreground}),
          ]),
        ],
      );
      _ready = await _plugin.initialize(
            settings: InitializationSettings(
              android: const AndroidInitializationSettings('ic_stat_habitrail'),
              iOS: darwin,
              macOS: darwin,
              windows: WindowsInitializationSettings(
                appName: 'Habitrail',
                appUserModelId: 'Habitrail.Habitrail',
                guid: '11ad8e3e-0241-4a7a-a316-d8b1cb03198d',
                iconPath: Platform.isWindows ? _windowsIcon() : null,
              ),
            ),
            onDidReceiveNotificationResponse: _onResponse,
          ) ??
          false;
      if (!_ready) return;
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final r = launch?.notificationResponse;
      if ((launch?.didNotificationLaunchApp ?? false) && r != null) {
        _onResponse(r);
      }
      await refreshPermission();
    } catch (e) {
      debugPrint('notifications: init failed: $e');
      _ready = false;
    }
  }

  /// Replans on every progress change, and when the app comes back to the
  /// foreground (time has passed; permission may have changed in Settings).
  void attach() {
    if (!_ready) return;
    appState.addListener(replanSoon);
    buddies.addListener(replanSoon);
    _lifecycle = AppLifecycleListener(onResume: () async {
      await refreshPermission();
      replanSoon();
    });
    replanSoon();
  }

  void replanSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), replan);
  }

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin
      .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
  MacOSFlutterLocalNotificationsPlugin? get _macos => _plugin
      .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> refreshPermission() async {
    if (!_ready) return;
    try {
      if (Platform.isIOS) {
        permitted.value = (await _ios?.checkPermissions())?.isEnabled ?? false;
      } else if (Platform.isMacOS) {
        permitted.value = (await _macos?.checkPermissions())?.isEnabled ?? false;
      } else if (Platform.isAndroid) {
        permitted.value = await _android?.areNotificationsEnabled() ?? false;
      } else {
        permitted.value = true; // Windows has no prompt; it's a system setting
      }
    } catch (e) {
      debugPrint('notifications: permission check failed: $e');
    }
  }

  /// Shows the OS permission prompt, then schedules if it was allowed. After
  /// the first answer iOS won't prompt again; the app points to Settings.
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    appState.setNotificationPrefs(asked: true);
    try {
      bool? ok;
      if (Platform.isIOS) {
        ok = await _ios?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isMacOS) {
        ok = await _macos?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isAndroid) {
        ok = await _android?.requestNotificationsPermission();
      } else {
        ok = true;
      }
      permitted.value = ok ?? false;
    } catch (e) {
      debugPrint('notifications: permission request failed: $e');
    }
    await replan(force: true);
    return permitted.value == true;
  }

  Future<void> openSystemSettings() async {
    try {
      await _plugin.openAppNotificationSettings();
    } catch (_) {} // not available on this platform
  }

  /// Hands the current plan to the OS, unless it already holds that plan.
  Future<void> replan({bool force = false}) =>
      _queue = _queue.then((_) => _apply(force));

  Future<void> _apply(bool force) async {
    if (!_ready) return;
    final allowed = permitted.value == true;
    // A few seconds' margin: the OS rejects times that are already past.
    final soon = DateTime.now().add(const Duration(seconds: 5));
    final plan = allowed
        ? planNotifications(appState, DateTime.now(), buddies: buddies.active)
            .where((p) => p.at.isAfter(soon))
            .toList()
        : const <PlannedNotification>[];
    final sig = plan
        .map((p) =>
            '${p.id}|${p.at.millisecondsSinceEpoch}|${p.title}|${p.body}|${p.payload}')
        .join('\n');
    if (!force && sig == _scheduled) return;
    try {
      // Pending ones only: a reminder already delivered stays in the list.
      if (Platform.isWindows) {
        await _plugin.cancelAll();
      } else {
        await _plugin.cancelAllPendingNotifications();
      }
      for (final p in plan) {
        await _plugin.zonedSchedule(
          id: p.id,
          // The plan is in local wall-clock time; scheduling the same instant
          // in UTC fires it at that local time on every platform.
          scheduledDate: tz.TZDateTime.from(p.at, tz.UTC),
          notificationDetails: _details(p.payload),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: p.title,
          body: p.body,
          payload: p.payload,
        );
      }
      _scheduled = sig;
    } catch (e) {
      debugPrint('notifications: scheduling failed: $e');
      _scheduled = '';
    }
  }

  /// What's scheduled right now (for the Settings screen).
  Future<int> pendingCount() async {
    if (!_ready) return 0;
    try {
      return (await _plugin.pendingNotificationRequests()).length;
    } catch (_) {
      return 0;
    }
  }

  /// Sends one right away so the user can see what reminders look like.
  Future<bool> sendTest() async {
    if (!_ready) return false;
    if (permitted.value != true && !await requestPermission()) return false;
    final c = companionByType(appState.activeCompanion);
    try {
      await _plugin.show(
        id: 0,
        title: 'Reminders are on',
        body: '${c.name}: ${companionLine(c.type, 'reminder')}',
        notificationDetails: _details('test'),
        payload: 'test',
      );
      return true;
    } catch (e) {
      debugPrint('notifications: test failed: $e');
      return false;
    }
  }

  NotificationDetails _details(String payload) {
    final habit = payload.startsWith('habit:');
    return NotificationDetails(
        android: AndroidNotificationDetails(
          habit ? 'habit_reminders' : 'streak_alerts',
          habit ? 'Habit reminders' : 'Streak alerts',
          channelDescription: habit
              ? 'A nudge at each habit\'s reminder time'
              : 'A heads-up before a streak breaks',
          importance: Importance.high,
          priority: Priority.high,
          color: const Color(0xFF8D4BFF),
          actions: habit
              ? const [
                  AndroidNotificationAction('done', 'Mark done',
                      showsUserInterface: true),
                ]
              : null,
        ),
        iOS: DarwinNotificationDetails(
            categoryIdentifier: habit ? 'habit' : null,
            threadIdentifier: habit ? 'habits' : 'streak'),
        macOS: DarwinNotificationDetails(
            categoryIdentifier: habit ? 'habit' : null,
            threadIdentifier: habit ? 'habits' : 'streak'),
        // Windows reports a button press as the button's arguments, so they
        // carry the habit too.
        windows: WindowsNotificationDetails(
          actions: habit
              ? [WindowsAction(content: 'Mark done', arguments: 'done:$payload')]
              : const [],
        ),
      );
  }

  void _onResponse(NotificationResponse r) {
    var payload = r.payload ?? '';
    final done = r.actionId == 'done' || payload.startsWith('done:');
    if (payload.startsWith('done:')) payload = payload.substring(5);
    final habitId = payload.startsWith('habit:') ? payload.substring(6) : null;
    pendingAction.value =
        done && habitId != null ? 'done:$habitId' : 'open:$payload';
  }

  void dispose() {
    _debounce?.cancel();
    _lifecycle?.dispose();
    appState.removeListener(replanSoon);
    buddies.removeListener(replanSoon);
  }
}

final reminders = ReminderNotifications();
