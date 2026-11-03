// An in-memory stand-in for the admin RPCs, so the admin console and the
// account-status sync can be tested (and screenshotted) without Supabase.
// It mirrors the server's rules that the UI relies on: admins and yourself
// can't be banned, and adjustments show up as pending coins.
import 'package:habitrail/admin.dart';

/// Sample accounts: Premium, banned, gifted + pending coins, admin, and one
/// whose app never reported a balance.
List<AdminUser> sampleAdminUsers() => [
      AdminUser(
          id: 'u-maya',
          username: 'maya_runs',
          name: 'Maya',
          email: 'maya@example.com',
          coins: 1240,
          devicePremium: true,
          seenAt: DateTime(2026, 11, 2)),
      AdminUser(
          id: 'u-leo',
          username: 'leo_lifts',
          name: 'Leo',
          email: 'leo@example.com',
          coins: 80,
          banned: true,
          banReason: 'Spam in global chat',
          seenAt: DateTime(2026, 10, 30)),
      AdminUser(
          id: 'u-noor',
          username: 'noor_reads',
          name: 'Noor',
          email: 'noor@example.com',
          coins: 455,
          premiumOverride: 'grant',
          pendingCoins: 500,
          seenAt: DateTime(2026, 11, 1)),
      AdminUser(
          id: 'u-sam',
          username: 'sam_admin',
          name: 'Sam',
          email: 'sam@example.com',
          coins: 3020,
          isAdmin: true,
          seenAt: DateTime(2026, 11, 3)),
      const AdminUser(id: 'u-kai', username: 'kai', email: 'kai@example.com'),
    ];

class FakeAdminApi implements AdminApi {
  FakeAdminApi({List<AdminUser>? users, this.status, this.me})
      : users = users ?? sampleAdminUsers();

  final List<AdminUser> users;
  AccountStatus? status; // what myStatus() returns (null = offline)
  String? me; // the signed-in admin's id
  String? failWith; // when set, every admin call fails with this message
  bool ackOk = true;
  bool authBlocks = true; // whether a ban also lands in Supabase Auth

  final coinCalls = <(String, int, String)>[];
  final premiumCalls = <(String, String)>[];
  final banCalls = <(String, bool, String)>[];
  final acked = <String>[];

  @override
  String? get currentUserId => me;

  @override
  Future<AccountStatus?> myStatus() async => status;

  @override
  Future<bool> ackCoinGrants(List<String> ids) async {
    if (!ackOk) return false;
    acked.addAll(ids);
    return true;
  }

  @override
  Future<(List<AdminUser>, String?)> searchUsers(String query) async {
    if (failWith != null) return (const <AdminUser>[], failWith);
    final q = query.trim().toLowerCase();
    return (
      users
          .where((u) =>
              q.isEmpty ||
              u.username.toLowerCase().contains(q) ||
              u.name.toLowerCase().contains(q) ||
              u.email.toLowerCase().contains(q))
          .toList(),
      null,
    );
  }

  void _update(String id, AdminUser Function(AdminUser) change) {
    final i = users.indexWhere((u) => u.id == id);
    if (i >= 0) users[i] = change(users[i]);
  }

  @override
  Future<String?> adjustCoins(String userId, int amount, String note) async {
    if (failWith != null) return failWith;
    coinCalls.add((userId, amount, note));
    _update(userId, (u) => u.copyWith(pendingCoins: u.pendingCoins + amount));
    return null;
  }

  @override
  Future<String?> setPremium(String userId, String state) async {
    if (failWith != null) return failWith;
    premiumCalls.add((userId, state));
    _update(userId,
        (u) => u.copyWith(premiumOverride: state == 'none' ? '' : state));
    return null;
  }

  @override
  Future<({String? error, bool authBlocked})> setBan(
      String userId, bool banned, String reason) async {
    if (failWith != null) return (error: failWith, authBlocked: false);
    if (userId == me) return (error: 'you cannot ban yourself', authBlocked: false);
    if (banned && users.any((u) => u.id == userId && u.isAdmin)) {
      return (
        error: 'remove admin access before banning this account',
        authBlocked: false
      );
    }
    banCalls.add((userId, banned, reason));
    _update(userId,
        (u) => u.copyWith(banned: banned, banReason: banned ? reason : ''));
    return (error: null, authBlocked: authBlocks);
  }
}
