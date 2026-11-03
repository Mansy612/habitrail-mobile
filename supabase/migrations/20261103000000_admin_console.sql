-- Admin console: a server-side admin role, an audit log, and the three things
-- an admin can do to any account — adjust coins, override Premium, ban/unban.
--
-- Coins and Premium live on each device, so an admin change is recorded here
-- and the target's app picks it up on launch / sign-in (my_account_status):
--   * coin_grants — a ledger of +/- adjustments. The app applies each row once
--     and acknowledges it (ack_coin_grants), which stamps applied_at.
--   * premium_overrides — 'grant' / 'revoke', which the app's entitlement check
--     respects over the device's own purchase state. No row = the device decides.
--   * user_bans — a banned account is refused at sign-in (auth.users.banned_until
--     where this database role may set it, plus the app's own check), and its
--     chat / party / guild / friend writes are refused by RPC checks and RLS.
--
-- Every table has RLS on with no permissive policies (= deny direct access),
-- like parties and guilds; all access goes through SECURITY DEFINER functions,
-- and every admin_* function checks public.is_admin() first. This migration
-- makes nobody an admin: seed the first one by hand (docs/SUPABASE_SETUP.md, 2j).
--
-- Requires the earlier migrations (parties, party chat, guilds, global chat,
-- guild chat/goals, party quests): it re-creates their write RPCs with a ban
-- check, keeping each body otherwise identical.

-- 1. Tables -------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.user_bans (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text not null default '',
  banned_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.premium_overrides (
  user_id uuid primary key references auth.users (id) on delete cascade,
  state text not null check (state in ('grant', 'revoke')),
  set_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.coin_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  amount int not null check (amount <> 0 and abs(amount) <= 1000000),
  note text not null default '',
  granted_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  applied_at timestamptz -- null until the user's app has applied it
);

create index if not exists coin_grants_pending
  on public.coin_grants (user_id) where applied_at is null;

-- What each device last reported about itself (coins live on-device), so the
-- admin console can show a balance. Display only; never trusted for rewards.
create table if not exists public.account_snapshots (
  user_id uuid primary key references auth.users (id) on delete cascade,
  coins int not null default 0,
  premium boolean not null default false, -- the device's own entitlement
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_actions (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users (id) on delete set null,
  target_id uuid references auth.users (id) on delete set null,
  action text not null, -- 'coins' | 'premium' | 'ban' | 'unban'
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;
alter table public.user_bans enable row level security;
alter table public.premium_overrides enable row level security;
alter table public.coin_grants enable row level security;
alter table public.account_snapshots enable row level security;
alter table public.admin_actions enable row level security;

-- 2. Helpers ------------------------------------------------------------------
-- Is the caller an admin?
create or replace function public.is_admin()
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from admins where user_id = auth.uid());
$$;

-- Is the caller banned? (Caller-only, so it can't be used to probe others.)
create or replace function public.caller_banned()
returns boolean language sql security definer stable set search_path = public as $$
  select exists(select 1 from user_bans where user_id = auth.uid());
$$;

create or replace function public.assert_admin()
returns void language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.assert_not_banned()
returns void language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if public.caller_banned() then
    raise exception 'this account is suspended' using errcode = '42501';
  end if;
end;
$$;

-- 3. The signed-in user's own status (read by the app on launch / sign-in) ----
create or replace function public.my_account_status()
returns jsonb language sql security definer stable set search_path = public as $$
  select jsonb_build_object(
    'is_admin', public.is_admin(),
    'banned', public.caller_banned(),
    'ban_reason',
      coalesce((select reason from user_bans where user_id = auth.uid()), ''),
    'premium_override',
      coalesce((select state from premium_overrides where user_id = auth.uid()), ''),
    'coin_grants', coalesce((
      select jsonb_agg(jsonb_build_object('id', g.id, 'amount', g.amount, 'note', g.note)
                       order by g.created_at)
      from coin_grants g
      where g.user_id = auth.uid() and g.applied_at is null), '[]'::jsonb)
  );
$$;

-- The app applied these coin adjustments; stamp them so they never apply twice.
create or replace function public.ack_coin_grants(p_ids uuid[])
returns int language sql security definer set search_path = public as $$
  with done as (
    update coin_grants set applied_at = now()
    where user_id = auth.uid() and applied_at is null and id = any(p_ids)
    returning 1
  )
  select count(*)::int from done;
$$;

-- The app reports its coin balance and own Premium state for the admin view.
create or replace function public.report_account_snapshot(p_coins int, p_premium boolean)
returns void language sql security definer set search_path = public as $$
  insert into account_snapshots (user_id, coins, premium, updated_at)
  select auth.uid(), greatest(0, coalesce(p_coins, 0)), coalesce(p_premium, false), now()
  where auth.uid() is not null
  on conflict (user_id) do update
    set coins = excluded.coins, premium = excluded.premium, updated_at = now();
$$;

-- 4. Admin actions ------------------------------------------------------------
-- Find accounts by username, display name or email (blank = recently active).
create or replace function public.admin_search_users(p_query text)
returns table (
  id uuid, username text, name text, email text, coins int,
  device_premium boolean, premium_override text, banned boolean,
  ban_reason text, pending_coins int, is_admin boolean, seen_at timestamptz
) language plpgsql security definer stable set search_path = public as $$
declare v_q text := coalesce(trim(p_query), '');
begin
  perform public.assert_admin();
  return query
  select p.id, p.username, p.name, u.email::text, s.coins,
    s.premium, coalesce(o.state, ''), b.user_id is not null,
    coalesce(b.reason, ''),
    coalesce((select sum(g.amount) from coin_grants g
              where g.user_id = p.id and g.applied_at is null), 0)::int,
    exists(select 1 from admins a where a.user_id = p.id),
    s.updated_at
  from profiles p
  join auth.users u on u.id = p.id
  left join account_snapshots s on s.user_id = p.id
  left join premium_overrides o on o.user_id = p.id
  left join user_bans b on b.user_id = p.id
  where v_q = ''
     or p.username ilike '%' || v_q || '%'
     or p.name ilike '%' || v_q || '%'
     or u.email ilike '%' || v_q || '%'
  order by p.updated_at desc
  limit 50;
end;
$$;

-- Give (+) or take (-) coins. Recorded in the ledger; the user's app applies
-- it on its next launch / sign-in (never below zero on the device).
create or replace function public.admin_adjust_coins(p_user uuid, p_amount int, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if coalesce(p_amount, 0) = 0 then raise exception 'amount must not be zero'; end if;
  if abs(p_amount) > 1000000 then raise exception 'amount is too large'; end if;
  if not exists(select 1 from profiles where id = p_user) then
    raise exception 'user not found';
  end if;
  insert into coin_grants (user_id, amount, note, granted_by)
    values (p_user, p_amount, left(coalesce(trim(p_note), ''), 200), auth.uid());
  insert into admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, 'coins',
            jsonb_build_object('amount', p_amount, 'note', coalesce(p_note, '')));
end;
$$;

-- Force Premium on ('grant') or off ('revoke'), or hand it back to the
-- device's own purchase state ('none').
create or replace function public.admin_set_premium(p_user uuid, p_state text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_state is null or p_state not in ('grant', 'revoke', 'none') then
    raise exception 'state must be grant, revoke or none';
  end if;
  if not exists(select 1 from profiles where id = p_user) then
    raise exception 'user not found';
  end if;
  if p_state = 'none' then
    delete from premium_overrides where user_id = p_user;
  else
    insert into premium_overrides (user_id, state, set_by)
      values (p_user, p_state, auth.uid())
      on conflict (user_id) do update
        set state = excluded.state, set_by = excluded.set_by, updated_at = now();
  end if;
  insert into admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user, 'premium', jsonb_build_object('state', p_state));
end;
$$;

-- Ban or unban. Returns true when the sign-in block also landed on
-- auth.users.banned_until (Supabase Auth then refuses sign-in and token
-- refresh); false means only the app-side check, RPC checks and RLS apply.
create or replace function public.admin_set_ban(p_user uuid, p_banned boolean, p_reason text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_auth boolean := false;
begin
  perform public.assert_admin();
  if p_user = auth.uid() then raise exception 'you cannot ban yourself'; end if;
  if not exists(select 1 from profiles where id = p_user) then
    raise exception 'user not found';
  end if;
  if coalesce(p_banned, false) then
    if exists(select 1 from admins where user_id = p_user) then
      raise exception 'remove admin access before banning this account';
    end if;
    insert into user_bans (user_id, reason, banned_by)
      values (p_user, left(coalesce(trim(p_reason), ''), 200), auth.uid())
      on conflict (user_id) do update
        set reason = excluded.reason, banned_by = excluded.banned_by,
            created_at = now();
  else
    delete from user_bans where user_id = p_user;
  end if;
  begin
    update auth.users
      set banned_until = case when coalesce(p_banned, false)
                              then now() + interval '100 years' end
      where id = p_user;
    v_auth := found;
  exception when others then
    v_auth := false; -- no write access to auth.users: app/RLS blocks still hold
  end;
  insert into admin_actions (admin_id, target_id, action, detail)
    values (auth.uid(), p_user,
            case when coalesce(p_banned, false) then 'ban' else 'unban' end,
            jsonb_build_object('reason', coalesce(p_reason, ''), 'auth_blocked', v_auth));
  return v_auth;
end;
$$;

-- 5. Ban checks in the existing write RPCs ------------------------------------
-- SECURITY DEFINER functions bypass RLS, so each one checks the caller itself.
create or replace function public.create_party(p_name text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_code text; v_party parties; v_xp int;
begin
  perform public.assert_not_banned();
  delete from parties where owner_id = auth.uid();          -- one party per user
  delete from party_members where user_id = auth.uid();
  v_code := upper(substring(replace(gen_random_uuid()::text, '-', '') for 6));
  select coalesce(total_xp, 0) into v_xp from profiles where id = auth.uid();
  insert into parties (name, invite_code, owner_id)
    values (coalesce(nullif(trim(p_name), ''), 'My Party'), v_code, auth.uid())
    returning * into v_party;
  insert into party_members (party_id, user_id, xp_baseline)
    values (v_party.id, auth.uid(), coalesce(v_xp, 0));
  return v_party;
end;
$$;

create or replace function public.join_party(p_code text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties; v_xp int;
begin
  perform public.assert_not_banned();
  select * into v_party from parties where invite_code = upper(trim(p_code));
  if v_party.id is null then raise exception 'party not found'; end if;
  delete from parties where owner_id = auth.uid() and id <> v_party.id;
  delete from party_members where user_id = auth.uid() and party_id <> v_party.id;
  select coalesce(total_xp, 0) into v_xp from profiles where id = auth.uid();
  insert into party_members (party_id, user_id, xp_baseline)
    values (v_party.id, auth.uid(), coalesce(v_xp, 0))
    on conflict (party_id, user_id) do nothing;
  return v_party;
end;
$$;

create or replace function public.set_party_goal(p_id uuid, p_target int, p_week text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties;
begin
  perform public.assert_not_banned();
  if not exists(select 1 from parties where id = p_id and owner_id = auth.uid())
  then raise exception 'only the owner can set the goal'; end if;
  update parties set goal_target = greatest(0, p_target), goal_week = p_week
    where id = p_id returning * into v_party;
  update party_members m
    set xp_baseline = coalesce((select total_xp from profiles where id = m.user_id), 0)
    where m.party_id = p_id;
  return v_party;
end;
$$;

create or replace function public.set_party_quest(
  p_id uuid, p_quest text, p_target int, p_week text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties;
begin
  perform public.assert_not_banned();
  if not exists(select 1 from parties where id = p_id and owner_id = auth.uid())
  then raise exception 'only the owner can set the quest'; end if;
  update parties
    set quest_id = coalesce(p_quest, ''),
        goal_target = greatest(0, p_target),
        goal_week = p_week
    where id = p_id returning * into v_party;
  update party_members m
    set xp_baseline = coalesce((select total_xp from profiles where id = m.user_id), 0)
    where m.party_id = p_id;
  return v_party;
end;
$$;

create or replace function public.send_party_message(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  perform public.assert_not_banned();
  if not public.is_party_member(p_id) then
    raise exception 'not a member of this party';
  end if;
  if length(trim(p_body)) = 0 then return; end if;
  select coalesce(name, username, 'Player') into v_name
    from profiles where id = auth.uid();
  insert into public.party_messages (party_id, user_id, author_name, body)
    values (p_id, auth.uid(), coalesce(v_name, 'Player'), left(trim(p_body), 500));
end;
$$;

create or replace function public.create_guild(p_name text, p_desc text)
returns guilds language plpgsql security definer set search_path = public as $$
declare v_g guilds;
begin
  perform public.assert_not_banned();
  insert into guilds (name, description, owner_id)
    values (coalesce(nullif(trim(p_name), ''), 'New Guild'),
            coalesce(left(trim(p_desc), 200), ''), auth.uid())
    returning * into v_g;
  insert into guild_members (guild_id, user_id) values (v_g.id, auth.uid());
  return v_g;
end;
$$;

create or replace function public.join_guild(g_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_not_banned();
  insert into guild_members (guild_id, user_id) values (g_id, auth.uid())
    on conflict (guild_id, user_id) do nothing;
end;
$$;

create or replace function public.set_guild_goal(g_id uuid, p_target int, p_week text)
returns guilds language plpgsql security definer set search_path = public as $$
declare v_g guilds;
begin
  perform public.assert_not_banned();
  if not exists(select 1 from guilds where id = g_id and owner_id = auth.uid())
  then raise exception 'only the owner can set the goal'; end if;
  update guilds set goal_target = greatest(0, p_target), goal_week = p_week
    where id = g_id returning * into v_g;
  update guild_members m
    set xp_baseline = coalesce((select total_xp from profiles where id = m.user_id), 0)
    where m.guild_id = g_id;
  return v_g;
end;
$$;

create or replace function public.send_guild_message(g_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  perform public.assert_not_banned();
  if not public.is_guild_member(g_id) then
    raise exception 'not a member of this guild';
  end if;
  if length(trim(p_body)) = 0 then return; end if;
  select coalesce(name, username, 'Player') into v_name
    from profiles where id = auth.uid();
  insert into public.guild_messages (guild_id, user_id, author_name, body)
    values (g_id, auth.uid(), coalesce(v_name, 'Player'), left(trim(p_body), 500));
end;
$$;

create or replace function public.send_global_message(p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  perform public.assert_not_banned();
  if length(trim(p_body)) = 0 then return; end if;
  select coalesce(name, username, 'Player') into v_name
    from profiles where id = auth.uid();
  insert into public.global_messages (user_id, author_name, body)
    values (auth.uid(), coalesce(v_name, 'Player'), left(trim(p_body), 500));
end;
$$;

-- 6. RLS: banned accounts can't write chat, party, guild or social rows -------
-- Restrictive policies AND with the permissive ones, so they only ever take
-- access away. The chat/party/guild tables have no permissive write policies
-- today (writes go through the RPCs above); these keep it that way for banned
-- accounts even if direct-write policies are added later.
do $$
declare t text;
begin
  foreach t in array array[
    'party_messages', 'guild_messages', 'global_messages',
    'parties', 'party_members', 'guilds', 'guild_members'
  ] loop
    execute format('drop policy if exists "banned cannot insert" on public.%I', t);
    execute format('create policy "banned cannot insert" on public.%I as restrictive '
                   'for insert to authenticated '
                   'with check (not (select public.caller_banned()))', t);
    execute format('drop policy if exists "banned cannot update" on public.%I', t);
    execute format('create policy "banned cannot update" on public.%I as restrictive '
                   'for update to authenticated '
                   'using (not (select public.caller_banned())) '
                   'with check (not (select public.caller_banned()))', t);
    execute format('drop policy if exists "banned cannot delete" on public.%I', t);
    execute format('create policy "banned cannot delete" on public.%I as restrictive '
                   'for delete to authenticated '
                   'using (not (select public.caller_banned()))', t);
  end loop;
end $$;

-- Friendships and profiles are written directly by the client, so these bite
-- today: a banned account can't add friends or rename itself.
drop policy if exists "banned cannot add friends" on public.friendships;
create policy "banned cannot add friends" on public.friendships as restrictive
  for insert to authenticated with check (not (select public.caller_banned()));

drop policy if exists "banned cannot edit profile" on public.profiles;
create policy "banned cannot edit profile" on public.profiles as restrictive
  for update to authenticated
  using (not (select public.caller_banned()))
  with check (not (select public.caller_banned()));

-- 7. Grants -------------------------------------------------------------------
-- Supabase grants new functions to anon by default; admin and account
-- functions are for signed-in callers only.
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.caller_banned() from public, anon;
revoke execute on function public.assert_admin() from public, anon;
revoke execute on function public.assert_not_banned() from public, anon;
revoke execute on function public.my_account_status() from public, anon;
revoke execute on function public.ack_coin_grants(uuid[]) from public, anon;
revoke execute on function public.report_account_snapshot(int, boolean) from public, anon;
revoke execute on function public.admin_search_users(text) from public, anon;
revoke execute on function public.admin_adjust_coins(uuid, int, text) from public, anon;
revoke execute on function public.admin_set_premium(uuid, text) from public, anon;
revoke execute on function public.admin_set_ban(uuid, boolean, text) from public, anon;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.caller_banned() to authenticated;
grant execute on function public.assert_admin() to authenticated;
grant execute on function public.assert_not_banned() to authenticated;
grant execute on function public.my_account_status() to authenticated;
grant execute on function public.ack_coin_grants(uuid[]) to authenticated;
grant execute on function public.report_account_snapshot(int, boolean) to authenticated;
grant execute on function public.admin_search_users(text) to authenticated;
grant execute on function public.admin_adjust_coins(uuid, int, text) to authenticated;
grant execute on function public.admin_set_premium(uuid, text) to authenticated;
grant execute on function public.admin_set_ban(uuid, boolean, text) to authenticated;
