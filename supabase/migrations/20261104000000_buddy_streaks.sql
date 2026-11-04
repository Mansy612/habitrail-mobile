-- Buddy streaks: two friends keep one shared streak that grows on days they
-- both check in (finish at least one habit or task). The server only stores
-- who checked in on which day; the app counts the streak from those days.
-- Like parties, the tables have RLS on with no direct policies (= deny direct
-- access); everything goes through the SECURITY DEFINER functions below.

create table if not exists public.checkins (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null, -- the user's local calendar day
  primary key (user_id, day)
);

create table if not exists public.buddies (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references auth.users (id) on delete cascade,
  addressee uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'active')),
  started_on date, -- the day the invite was accepted; days before don't count
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);

-- One buddy streak per pair, whoever invited whom.
create unique index if not exists buddies_pair
  on public.buddies (least(requester, addressee), greatest(requester, addressee));

alter table public.checkins enable row level security;
alter table public.buddies enable row level security;

-- Record the caller's check-in days. Days are the client's local dates, so
-- allow a little slack around the server's date for time zones and catching
-- up after a few offline days.
create or replace function public.check_in(p_days date[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into checkins (user_id, day)
    select auth.uid(), d from unnest(p_days) as d
    where d between current_date - 8 and current_date + 1
  on conflict do nothing;
end;
$$;

-- Invite a friend (someone the caller has added). If they already invited the
-- caller, this accepts theirs instead. At most 5 buddies, pending included.
create or replace function public.invite_buddy(p_friend uuid, p_today date)
returns buddies language plpgsql security definer set search_path = public as $$
declare v buddies;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_friend = auth.uid() then raise exception 'cannot buddy yourself'; end if;
  if not exists (
    select 1 from friendships where user_id = auth.uid() and friend_id = p_friend
  ) then raise exception 'not friends'; end if;
  select * into v from buddies
    where least(requester, addressee) = least(auth.uid(), p_friend)
      and greatest(requester, addressee) = greatest(auth.uid(), p_friend);
  if v.id is not null then
    if v.status = 'pending' and v.addressee = auth.uid() then
      update buddies
        set status = 'active',
            started_on = least(greatest(p_today, current_date - 1), current_date + 1)
        where id = v.id returning * into v;
    end if;
    return v;
  end if;
  if (select count(*) from buddies where auth.uid() in (requester, addressee)) >= 5
  then raise exception 'buddy limit'; end if;
  insert into buddies (requester, addressee) values (auth.uid(), p_friend)
    returning * into v;
  return v;
end;
$$;

-- Accept or decline an invite the caller received. Accepting also adds the
-- inviter to the caller's friends, so each sees the other.
create or replace function public.respond_buddy(p_id uuid, p_accept boolean, p_today date)
returns buddies language plpgsql security definer set search_path = public as $$
declare v buddies;
begin
  select * into v from buddies
    where id = p_id and addressee = auth.uid() and status = 'pending';
  if v.id is null then raise exception 'invite not found'; end if;
  if not p_accept then
    delete from buddies where id = p_id;
    return null;
  end if;
  if (select count(*) from buddies
      where status = 'active' and auth.uid() in (requester, addressee)) >= 5
  then raise exception 'buddy limit'; end if;
  update buddies
    set status = 'active',
        started_on = least(greatest(p_today, current_date - 1), current_date + 1)
    where id = p_id returning * into v;
  insert into friendships (user_id, friend_id) values (auth.uid(), v.requester)
    on conflict do nothing;
  return v;
end;
$$;

-- Either buddy can end the streak (or withdraw an invite).
create or replace function public.end_buddy(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from buddies where id = p_id and auth.uid() in (requester, addressee);
end;
$$;

-- The caller's buddies and invites, with both sides' check-in days since the
-- streak began (up to three years back).
create or replace function public.my_buddies()
returns table (
  id uuid, status text, incoming boolean, started_on date,
  buddy_id uuid, username text, name text, border_id text,
  my_days date[], their_days date[]
) language sql security definer stable set search_path = public as $$
  select b.id, b.status, b.addressee = auth.uid(), b.started_on,
         p.id, p.username, p.name, p.border_id,
         case when b.status = 'active' then array(
           select c.day from checkins c
           where c.user_id = auth.uid()
             and c.day >= greatest(b.started_on, current_date - 1100)
           order by c.day) else '{}'::date[] end,
         case when b.status = 'active' then array(
           select c.day from checkins c
           where c.user_id = p.id
             and c.day >= greatest(b.started_on, current_date - 1100)
           order by c.day) else '{}'::date[] end
  from buddies b
  join profiles p
    on p.id = case when b.requester = auth.uid() then b.addressee else b.requester end
  where auth.uid() in (b.requester, b.addressee)
  order by b.status, b.created_at;
$$;

grant execute on function public.check_in(date[]) to authenticated;
grant execute on function public.invite_buddy(uuid, date) to authenticated;
grant execute on function public.respond_buddy(uuid, boolean, date) to authenticated;
grant execute on function public.end_buddy(uuid) to authenticated;
grant execute on function public.my_buddies() to authenticated;
