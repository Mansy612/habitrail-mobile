# Supabase backend setup (social layer)

Habitrail's **friends + leaderboard** run on Supabase when credentials are
provided. Without them the app falls back to the on-device demo directory, so
this is entirely optional until you want real accounts. Habit progress stays on
the device either way — only a public snapshot (name + stats) is mirrored to the
cloud so friends can see it.

## 1. Create a project
1. Create a project at <https://supabase.com>.
2. **Project Settings → API**: copy the **Project URL** and the **anon public** key.
3. **Authentication → Providers → Email**: for now turn **"Confirm email" OFF**
   so sign-up signs you straight in. (Turn it back on once an email-confirm flow
   is added to the app.)

## 2. Run the schema
Open the **SQL editor** and run:

```sql
-- Public profile: a snapshot of each user's stats, visible to signed-in users.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique not null,
  name text not null,
  total_xp int not null default 0,
  streak int not null default 0,
  prestige int not null default 0,
  border_id text not null default 'none',
  updated_at timestamptz not null default now()
);

-- Directed friendship: "user_id added friend_id".
create table public.friendships (
  user_id uuid not null references auth.users (id) on delete cascade,
  friend_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;

-- Any signed-in user can read profiles (for search + leaderboard); you may only
-- write your own row.
create policy "profiles readable by authenticated"
  on public.profiles for select to authenticated using (true);
create policy "insert own profile"
  on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "update own profile"
  on public.profiles for update to authenticated using (auth.uid() = id);

-- You manage only your own friendship rows.
create policy "read own friendships"
  on public.friendships for select to authenticated using (auth.uid() = user_id);
create policy "add own friendships"
  on public.friendships for insert to authenticated with check (auth.uid() = user_id);
create policy "remove own friendships"
  on public.friendships for delete to authenticated using (auth.uid() = user_id);
```

## 2b. Parties (co-op) — optional

Adds parties: a small group with an invite code and a shared weekly XP goal.
Run the SQL in `supabase/migrations/20261029000000_parties.sql` in the SQL
editor (or `supabase db push`). It creates `parties` + `party_members` with RLS
on, and SECURITY DEFINER functions (`create_party`, `join_party`, `leave_party`,
`my_party`, `party_members_info`, `set_party_goal`) that enforce
membership/ownership. Until you run it, the app's Party screen shows a friendly
"needs an account / coming soon" state and nothing else breaks.

## 2c. Party chat (real-time) — optional

Adds live chat inside a party. Run `supabase/migrations/20261029010000_party_chat.sql`
(after the parties schema) in the SQL editor. It creates `party_messages` with
RLS (members read), a `send_party_message` RPC, and adds the table to the
`supabase_realtime` publication so new messages stream to members live. Until
it's run, the Party chat screen just shows an empty state.

## 2d. Guilds (public groups) — optional

Adds discoverable public groups (you can be in many, unlike the one-party rule).
Run `supabase/migrations/20261029020000_guilds.sql` in the SQL editor: it
creates `guilds` + `guild_members` (RLS on) and SECURITY DEFINER RPCs
(`create_guild`, `join_guild`, `leave_guild`, `discover_guilds`, `my_guilds`,
`guild_members_info`). Until it's run, the Guilds screen shows an empty state.

## 2e. Global chat — optional

One shared room every signed-in user can read and post to (no joining). Run
`supabase/migrations/20261029030000_global_chat.sql`: it creates
`global_messages` (RLS: authenticated read), a `send_global_message` RPC, and
adds the table to the `supabase_realtime` publication for live delivery. A
per-user rate limit / moderation is a good future addition.

## 2f. Cloud backup / restore — recommended

Backs up each user's full on-device save so a reinstall or new device can
restore their progress (streaks, habits, tasks, everything) instead of losing
it. Run `supabase/migrations/20261029040000_backups.sql`: it creates
`user_backups` (one JSON row per user) with RLS so each user reads/writes only
their own row. The app auto-backs-up (debounced) while signed in, restores
automatically on sign-in when the device has no progress yet, and offers manual
Back up / Restore in Account. Without the table it silently no-ops.

## 2g. Guild chat + weekly goal — optional

Brings guilds up to parity with parties: a live chat room and a shared weekly
XP goal. Run `supabase/migrations/20261029050000_guild_chat_goals.sql` (after
the guilds schema). It adds `goal_target`/`goal_week` to `guilds` and
`xp_baseline` to `guild_members`, a `set_guild_goal` RPC (owner-only,
rebaselines members like parties), re-creates `discover_guilds`/`my_guilds`/
`guild_members_info` to carry the owner + goal + baseline, and adds
`guild_messages` (RLS: members read) with a `send_guild_message` RPC on the
realtime publication. Until it's run, guild chat shows an empty state and the
goal card stays hidden/no-op.

## 2h. Co-op quests (party boss goals) — optional

Lets a party take on a shared themed boss: the owner picks a quest, the party's
combined XP is the "damage," and each member claims a coin reward when it falls.
Run `supabase/migrations/20261029060000_party_quests.sql` (after the parties
schema). It adds a `quest_id` column to `parties` and a `set_party_quest` RPC
(owner-only, rebaselines members like `set_party_goal`); `my_party` already
returns `parties.*` so the quest flows through. Rewards are claimed per member
on-device. Until it's run, the party screen's quest card shows a "start a quest"
prompt and nothing breaks.

## 2i. Chat moderation / reports — recommended (App Store 1.2)

Backs the in-app **Report** action on chat messages (Block is client-side).
Run `supabase/migrations/20261029070000_content_reports.sql`: it creates
`content_reports` with RLS so any signed-in user can file a report (insert
only; no read policy — review reports via the dashboard / service role). Until
it's run, reporting silently no-ops; blocking still works.

## 2j. Admin console (coins, Premium, bans) — optional

Lets admin accounts give or take coins, grant or revoke Premium, and ban or
unban any account from **Settings → Admin console** (the row only appears for
admins). Run `supabase/migrations/20261103000000_admin_console.sql` after all
the migrations above (it re-creates the party, guild and chat write RPCs with
a ban check, so it must come last).

It creates, all with RLS on and no client policies:
- `admins` — who is an admin. Admin status is server-side only.
- `coin_grants` — a ledger of coin adjustments. Coins live on each device, so
  the target's app applies each row once on its next launch / sign-in and
  acknowledges it (`ack_coin_grants`), which stamps `applied_at`.
- `premium_overrides` — `grant` / `revoke`, which the app's entitlement check
  respects over the device's own purchase. No row = the device decides.
- `user_bans` — banned accounts are refused at sign-in and can't write chat,
  party, guild or friend rows (RPC checks + restrictive RLS policies).
  `admin_set_ban` also sets `auth.users.banned_until` so Supabase Auth itself
  refuses the account; if the database role can't write `auth.users`, the
  app's own sign-in check and the RLS/RPC blocks still apply.
- `account_snapshots` — the coin balance and Premium state each app last
  reported, so the console can show them. Display only.
- `admin_actions` — an audit log of every admin action.

Every `admin_*` function checks the caller is in `admins` and is not callable
by `anon`. The migration makes nobody an admin. Seed the first one in the SQL
editor with the email that account signs in with:

```sql
insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('you@example.com')
on conflict do nothing;
```

Sign out and back in (or relaunch) and the Admin console row appears. Until
the migration is deployed the app behaves exactly as before: the status check
reads as "not an admin, not banned, no override".

## 2k. Forgot password (email code) — required for the reset to work

**Log in → Forgot password?** emails a one-time code; the user types it in the
app with a new password (`resetPasswordForEmail` → `verifyOTP(type: recovery)`
→ `updateUser`). Codes instead of links, so it works the same on iPhone and
desktop with no deep links or redirect URLs.

1. **Authentication → Emails → Templates → Reset Password**: the default email
   only has a link, so replace its body with one that shows the code:

   ```html
   <h2>Reset your Habitrail password</h2>
   <p>Enter this code in the app to choose a new password:</p>
   <p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p>
   <p>It expires in an hour. If you didn't ask for this, you can ignore this email.</p>
   ```

   Subject: `Your Habitrail password reset code`.
2. **Authentication → Emails → SMTP Settings**: Supabase's built-in sender only
   delivers to your own team's addresses and a few emails an hour. For real
   users, turn on custom SMTP, e.g. Gmail with `habitrailapp@gmail.com`: host
   `smtp.gmail.com`, port `465`, username `habitrailapp@gmail.com`, password =
   a Google **App Password** (Google Account → Security → 2-Step Verification
   → App passwords), sender name `Habitrail`.

The code length follows **Authentication → Providers → Email → Email OTP
Length** (6 by default); the app accepts 6–10 digits.

## 2l. Buddy streaks — optional

Two friends keep one shared streak that grows on days they both finish a
habit or task. Run `supabase/migrations/20261104000000_buddy_streaks.sql`
(or `supabase db push`). It creates `checkins` (who checked in on which local
day) and `buddies` (invite → active pair, at most 5 per user), RLS on with no
direct policies, plus SECURITY DEFINER RPCs `check_in`, `invite_buddy`,
`respond_buddy`, `end_buddy` and `my_buddies`. The server only stores the
days; the app counts the streak (`buddyStreak` in `lib/core.dart`). Until
it's run, the Social strip shows no buddies and invites fail with a toast.

## 3. Run the app with credentials
Pass them at build/run time with `--dart-define`:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

For the Windows preview build, add the same two flags:

```bash
flutter build windows --debug \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

With credentials set, `backendEnabled` is true: the app uses `SupabaseAuthService`
for real sign-up / sign-in, mirrors your stats to `profiles`, and resolves friends
against the real user directory. With no credentials it stays on the on-device
stub, unchanged.

## Notes / limitations
- **Account deletion** fully deletes the `auth.users` record (and all cascading
  rows) via the `delete-account` Edge Function (`supabase/functions/delete-account`),
  which the app invokes and which uses the auto-injected **service-role** key
  server-side (it also removes the `user_backups` cloud backup and the
  `profiles` row explicitly before the auth user is deleted). **The function
  must be deployed for deletion to work.** Deploy it with `npx supabase
  functions deploy delete-account --project-ref <ref>` — no extra secrets
  needed. If it isn't deployed, or the call fails, the app reports a clear,
  retryable error and keeps the user signed in — it never deletes only the
  profile row and presents that as a completed account deletion. The
  service-role key never leaves the server.
- The **anon key is safe** to ship in a client build; Row-Level Security is what
  protects the data.
- To test the leaderboard with real data, sign up as two users (two devices or a
  signed-out session) and add each other by username.
