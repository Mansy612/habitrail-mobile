-- Parties (co-op): a small group with an invite code and a shared weekly XP
-- goal. All access goes through SECURITY DEFINER functions that enforce
-- membership/ownership; the tables themselves have RLS on with no direct
-- policies (= deny direct access), which avoids recursive-policy pitfalls.

create table if not exists public.parties (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text unique not null,
  owner_id uuid not null references auth.users (id) on delete cascade,
  goal_target int not null default 0, -- shared weekly XP target (0 = none)
  goal_week text not null default '', -- Monday dateKey the goal is for
  created_at timestamptz not null default now()
);

create table if not exists public.party_members (
  party_id uuid not null references public.parties (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  xp_baseline int not null default 0, -- member's total_xp when the goal started
  joined_at timestamptz not null default now(),
  primary key (party_id, user_id)
);

alter table public.parties enable row level security;
alter table public.party_members enable row level security;

-- Is the caller a member of this party?
create or replace function public.is_party_member(p_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(
    select 1 from party_members where party_id = p_id and user_id = auth.uid()
  );
$$;

-- Create a party; caller becomes owner + first member (baseline = their XP).
create or replace function public.create_party(p_name text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_code text; v_party parties; v_xp int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
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

-- Join a party by its invite code.
create or replace function public.join_party(p_code text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties; v_xp int;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
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

-- Leave a party; the owner leaving disbands it (cascade removes members).
create or replace function public.leave_party(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from parties where id = p_id and owner_id = auth.uid()) then
    delete from parties where id = p_id;
  else
    delete from party_members where party_id = p_id and user_id = auth.uid();
  end if;
end;
$$;

-- The caller's current party (most recent), or no rows.
create or replace function public.my_party()
returns setof parties language sql security definer stable set search_path = public as $$
  select p.* from parties p
  join party_members m on m.party_id = p.id
  where m.user_id = auth.uid()
  order by m.joined_at desc limit 1;
$$;

-- Member list (profile snapshot + baseline) for a party the caller belongs to.
create or replace function public.party_members_info(p_id uuid)
returns table (
  id uuid, username text, name text, total_xp int, streak int,
  prestige int, border_id text, xp_baseline int
) language sql security definer stable set search_path = public as $$
  select pr.id, pr.username, pr.name, pr.total_xp, pr.streak,
         pr.prestige, pr.border_id, m.xp_baseline
  from party_members m
  join profiles pr on pr.id = m.user_id
  where m.party_id = p_id and public.is_party_member(p_id)
  order by pr.total_xp desc;
$$;

-- Owner sets the shared weekly XP goal and rebaselines everyone to "now".
create or replace function public.set_party_goal(p_id uuid, p_target int, p_week text)
returns parties language plpgsql security definer set search_path = public as $$
declare v_party parties;
begin
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

grant execute on function public.is_party_member(uuid) to authenticated;
grant execute on function public.create_party(text) to authenticated;
grant execute on function public.join_party(text) to authenticated;
grant execute on function public.leave_party(uuid) to authenticated;
grant execute on function public.my_party() to authenticated;
grant execute on function public.party_members_info(uuid) to authenticated;
grant execute on function public.set_party_goal(uuid, int, text) to authenticated;
