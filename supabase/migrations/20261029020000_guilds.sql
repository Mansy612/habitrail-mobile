-- Guilds: public groups you can discover and join. Separate from parties — you
-- have at most one party but can be in many guilds. All access goes through
-- SECURITY DEFINER RPCs; the tables have RLS on with no direct policies.

create table if not exists public.guilds (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  owner_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.guild_members (
  guild_id uuid not null references public.guilds (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (guild_id, user_id)
);

alter table public.guilds enable row level security;
alter table public.guild_members enable row level security;

create or replace function public.create_guild(p_name text, p_desc text)
returns guilds language plpgsql security definer set search_path = public as $$
declare v_g guilds;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
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
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into guild_members (guild_id, user_id) values (g_id, auth.uid())
    on conflict (guild_id, user_id) do nothing;
end;
$$;

create or replace function public.leave_guild(g_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from guild_members where guild_id = g_id and user_id = auth.uid();
  -- disband an empty guild
  delete from guilds g where g.id = g_id
    and not exists (select 1 from guild_members m where m.guild_id = g.id);
end;
$$;

-- Browse public guilds (optionally filtered by name), with counts + membership.
create or replace function public.discover_guilds(p_query text)
returns table (id uuid, name text, description text, member_count int, is_member boolean)
language sql security definer stable set search_path = public as $$
  select g.id, g.name, g.description,
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

create or replace function public.my_guilds()
returns table (id uuid, name text, description text, member_count int, is_member boolean)
language sql security definer stable set search_path = public as $$
  select g.id, g.name, g.description,
    (select count(*) from guild_members m2 where m2.guild_id = g.id)::int, true
  from guilds g
  join guild_members m on m.guild_id = g.id
  where m.user_id = auth.uid()
  order by g.name;
$$;

create or replace function public.guild_members_info(g_id uuid)
returns table (id uuid, username text, name text, total_xp int, streak int,
               prestige int, border_id text)
language sql security definer stable set search_path = public as $$
  select pr.id, pr.username, pr.name, pr.total_xp, pr.streak, pr.prestige,
         pr.border_id
  from guild_members m
  join profiles pr on pr.id = m.user_id
  where m.guild_id = g_id
  order by pr.total_xp desc
  limit 50;
$$;

grant execute on function public.create_guild(text, text) to authenticated;
grant execute on function public.join_guild(uuid) to authenticated;
grant execute on function public.leave_guild(uuid) to authenticated;
grant execute on function public.discover_guilds(text) to authenticated;
grant execute on function public.my_guilds() to authenticated;
grant execute on function public.guild_members_info(uuid) to authenticated;
