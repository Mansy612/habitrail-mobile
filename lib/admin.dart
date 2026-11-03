import 'package:flutter/foundation.dart';

import 'auth.dart' show auth;
import 'backend.dart' as backend;
import 'core.dart' show appState;

// ── Admin console + account moderation ───────────────────────────────────────
//
// Admin status, bans, Premium overrides and coin adjustments are held and
// enforced on the server (supabase/migrations/20261103000000_admin_console.sql):
// admin_* RPCs refuse non-admins, and a banned account can't sign in or write
// chat, party, guild or friend rows. The app's part is to show the console to
// admins, and to pick up what an admin did to *this* account on launch and
// sign-in: apply coin adjustments once each and respect the Premium override.
//
// [adminApi] is the swap-in seam: the Supabase calls in the app, a fake in tests.

class CoinGrant {
  const CoinGrant(this.id, this.amount, [this.note = '']);
  final String id;
  final int amount; // + gives, - takes
  final String note;
}

/// What the server holds for the signed-in account.
class AccountStatus {
  const AccountStatus({
    this.isAdmin = false,
    this.banned = false,
    this.banReason = '',
    this.premiumOverride = '',
    this.coinGrants = const [],
  });

  final bool isAdmin;
  final bool banned;
  final String banReason;
  final String premiumOverride; // 'grant' | 'revoke' | '' (none)
  final List<CoinGrant> coinGrants; // not yet applied on a device

  factory AccountStatus.fromMap(Map<String, dynamic> m) => AccountStatus(
        isAdmin: m['is_admin'] == true,
        banned: m['banned'] == true,
        banReason: (m['ban_reason'] ?? '').toString(),
        premiumOverride: (m['premium_override'] ?? '').toString(),
        coinGrants: [
          for (final g in (m['coin_grants'] as List?) ?? const [])
            if (g is Map)
              CoinGrant((g['id'] ?? '').toString(),
                  (g['amount'] as num?)?.toInt() ?? 0, (g['note'] ?? '').toString()),
        ],
      );
}

/// One account as the admin console sees it.
class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    this.name = '',
    this.email = '',
    this.coins,
    this.devicePremium = false,
    this.premiumOverride = '',
    this.banned = false,
    this.banReason = '',
    this.pendingCoins = 0,
    this.isAdmin = false,
    this.seenAt,
  });

  final String id;
  final String username;
  final String name;
  final String email;
  final int? coins; // last balance the device reported; null = never reported
  final bool devicePremium; // the device's own entitlement
  final String premiumOverride; // 'grant' | 'revoke' | ''
  final bool banned;
  final String banReason;
  final int pendingCoins; // adjustments the device hasn't applied yet
  final bool isAdmin;
  final DateTime? seenAt; // when the device last reported

  /// Premium as the user's app will see it once it syncs.
  bool get premium =>
      premiumOverride == 'grant' || (premiumOverride != 'revoke' && devicePremium);

  String get displayName => name.isNotEmpty ? name : username;

  factory AdminUser.fromMap(Map<String, dynamic> m) => AdminUser(
        id: (m['id'] ?? '').toString(),
        username: (m['username'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        email: (m['email'] ?? '').toString(),
        coins: (m['coins'] as num?)?.toInt(),
        devicePremium: m['device_premium'] == true,
        premiumOverride: (m['premium_override'] ?? '').toString(),
        banned: m['banned'] == true,
        banReason: (m['ban_reason'] ?? '').toString(),
        pendingCoins: (m['pending_coins'] as num?)?.toInt() ?? 0,
        isAdmin: m['is_admin'] == true,
        seenAt: DateTime.tryParse((m['seen_at'] ?? '').toString()),
      );

  AdminUser copyWith({
    int? pendingCoins,
    String? premiumOverride,
    bool? banned,
    String? banReason,
  }) =>
      AdminUser(
        id: id,
        username: username,
        name: name,
        email: email,
        coins: coins,
        devicePremium: devicePremium,
        premiumOverride: premiumOverride ?? this.premiumOverride,
        banned: banned ?? this.banned,
        banReason: banReason ?? this.banReason,
        pendingCoins: pendingCoins ?? this.pendingCoins,
        isAdmin: isAdmin,
        seenAt: seenAt,
      );
}

/// Admin and account-status calls. Every admin method returns null on success
/// or the error to show; the server decides whether the caller may do it.
abstract class AdminApi {
  /// The signed-in user's id, so the console can tell "you" apart.
  String? get currentUserId;
  Future<AccountStatus?> myStatus();
  Future<bool> ackCoinGrants(List<String> ids);
  Future<(List<AdminUser>, String?)> searchUsers(String query);
  Future<String?> adjustCoins(String userId, int amount, String note);
  Future<String?> setPremium(String userId, String state);
  Future<({String? error, bool authBlocked})> setBan(
      String userId, bool banned, String reason);
}

class SupabaseAdminApi implements AdminApi {
  const SupabaseAdminApi();

  @override
  String? get currentUserId => backend.currentUserId;

  @override
  Future<AccountStatus?> myStatus() async {
    final m = await backend.fetchAccountStatus();
    return m == null ? null : AccountStatus.fromMap(m);
  }

  @override
  Future<bool> ackCoinGrants(List<String> ids) => backend.ackCoinGrants(ids);

  @override
  Future<(List<AdminUser>, String?)> searchUsers(String query) async {
    final (rows, err) = await backend.adminSearchUsers(query);
    return (rows.map(AdminUser.fromMap).toList(), err);
  }

  @override
  Future<String?> adjustCoins(String userId, int amount, String note) =>
      backend.adminAdjustCoins(userId, amount, note);

  @override
  Future<String?> setPremium(String userId, String state) =>
      backend.adminSetPremium(userId, state);

  @override
  Future<({String? error, bool authBlocked})> setBan(
          String userId, bool banned, String reason) =>
      backend.adminSetBan(userId, banned, reason);
}

AdminApi adminApi = const SupabaseAdminApi();

/// True while the server says the signed-in account is an admin. It only
/// decides whether the console is shown; the server checks every admin call.
final adminAccess = ValueNotifier<bool>(false);

/// Pick up what an admin did to this account: sign out if banned, apply the
/// Premium override, and apply new coin adjustments once (then acknowledge
/// them). Call after sign-in (after any cloud restore) and on launch. Returns
/// null, changing nothing, when the status can't be read (offline / signed out).
Future<AccountStatus?> syncAccountStatus() async {
  final s = await adminApi.myStatus();
  if (s == null) return null;
  if (s.banned) {
    clearAccountStatus();
    await auth.signOut();
    return s;
  }
  adminAccess.value = s.isAdmin;
  appState.setPremiumOverride(s.premiumOverride);
  final grants = s.coinGrants.where((g) => g.id.isNotEmpty && g.amount != 0);
  if (grants.isNotEmpty) {
    await appState
        .applyCoinGrants(grants.map((g) => (id: g.id, amount: g.amount)));
    final ids = grants.map((g) => g.id).toList();
    if (await adminApi.ackCoinGrants(ids)) appState.forgetCoinGrants(ids);
  }
  return s;
}

/// Signed out: the override and admin access belonged to that account.
void clearAccountStatus() {
  adminAccess.value = false;
  appState.setPremiumOverride('');
}
