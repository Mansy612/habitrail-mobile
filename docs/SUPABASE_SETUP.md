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
- **Account deletion** removes your `profiles` row (friendships cascade) and signs
  you out, but fully deleting the `auth.users` record needs a privileged call
  (a Supabase Edge Function using the **service-role** key) — never done from the
  client. The service-role key must stay server-side only.
- The **anon key is safe** to ship in a client build; Row-Level Security is what
  protects the data.
- To test the leaderboard with real data, sign up as two users (two devices or a
  signed-out session) and add each other by username.
