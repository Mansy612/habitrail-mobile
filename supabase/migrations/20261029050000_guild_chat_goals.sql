-- Guild chat + weekly guild goal — brings guilds up to parity with parties.
-- Mirrors the parties design: a shared weekly XP goal on the guild row with a
-- per-member xp_baseline that set_guild_goal rebaselines, progress summed
-- client-side; plus a realtime message room readable by members only.
-- Requires the guilds schema (20261029020000_guilds.sql) first.

-- 1. Goal fields on the guild + per-member baseline -------------------------
alter table public.guilds
  add column if not exists goal_target int not null default 0;  -- weekly XP target (0 = none)
alter table public.guilds
  add column if not exists goal_week text not null default '';  -- Monday dateKey the goal is for
alter table public.guild_members
  add column if not exists xp_baseline int not null default 0;  -- member's total_xp when the goal started

-- 2. Membership helper (used by the chat read policy) -----------------------
create or replace function public.is_guild_member(g_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(
    select 1 from guild_members where guild_id = g_id and user_id = auth.uid()
  );
$$;
grant execute on function public.is_guild_member(uuid) to authenticated;

-- 3. Owner sets the weekly goal and rebaselines everyone to "now" -----------
create or replace function public.set_guild_goal(g_id uuid, p_target int, p_week text)
returns guilds language plpgsql security definer set search_path = public as $$
declare v_g guilds;
begin
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
grant execute on function public.set_guild_goal(uuid, int, text) to authenticated;

-- 4. Re-create the list RPCs to carry owner_id + goal fields -----------------
-- (return-type change requires dropping the old functions first).
drop function if exists public.discover_guilds(text);
create or replace function public.discover_guilds(p_query text)
returns table (id uuid, name text, description text, owner_id uuid,
               goal_target int, goal_week text, member_count int, is_member boolean)
language sql security definer stable set search_path = public as $$
  select g.id, g.name, g.description, g.owner_id, g.goal_target, g.goal_week,
    (select count(*) from guild_members m where m.guild_id = g.id)::int,
    exists(select 1 from guild_members m
           where m.guild_id = g.id and m.user_id = auth.uid())
  from guilds g
  where coalesce(trim(p_query), '') = ''
     or g.name ilike '%' || trim(p_query) || '%'
  order by (select count(*) from guild_members m where m.guild_id = g.id) desc,
           g.created_at desc
  limit 30;
$$;
grant execute on function public.discover_guilds(text) to authenticated;

drop function if exists public.my_guilds();
create or replace function public.my_guilds()
returns table (id uuid, name text, description text, owner_id uuid,
               goal_target int, goal_week text, member_count int, is_member boolean)
language sql security definer stable set search_path = public as $$
  select g.id, g.name, g.description, g.owner_id, g.goal_target, g.goal_week,
    (select count(*) from guild_members m2 where m2.guild_id = g.id)::int, true
  from guilds g
  join guild_members m on m.guild_id = g.id
  where m.user_id = auth.uid()
  order by g.name;
$$;
grant execute on function public.my_guilds() to authenticated;

-- 5. Re-create the roster RPC to carry xp_baseline (for goal progress) ------
drop function if exists public.guild_members_info(uuid);
create or replace function public.guild_members_info(g_id uuid)
returns table (id uuid, username text, name text, total_xp int, streak int,
               prestige int, border_id text, xp_baseline int)
language sql security definer stable set search_path = public as $$
  select pr.id, pr.username, pr.name, pr.total_xp, pr.streak, pr.prestige,
         pr.border_id, m.xp_baseline
  from guild_members m
  join profiles pr on pr.id = m.user_id
  where m.guild_id = g_id
  order by pr.total_xp desc
  limit 50;
$$;
grant execute on function public.guild_members_info(uuid) to authenticated;

-- 6. Guild chat: members read via RLS; sending goes through a membership-
-- checked RPC that stamps the author name. Streams live via realtime. --------
create table if not exists public.guild_messages (
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references public.guilds (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  author_name text not null default '',
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists guild_messages_guild_time
  on public.guild_messages (guild_id, created_at);

alter table public.guild_messages enable row level security;

drop policy if exists "members read guild messages" on public.guild_messages;
create policy "members read guild messages"
  on public.guild_messages for select to authenticated
  using (public.is_guild_member(guild_id));

create or replace function public.send_guild_message(g_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
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

grant execute on function public.send_guild_message(uuid, text) to authenticated;

-- Live updates for members (idempotent: only add to the publication once).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'guild_messages'
  ) then
    alter publication supabase_realtime add table public.guild_messages;
  end if;
end $$;
