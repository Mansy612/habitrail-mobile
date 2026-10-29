-- Party chat: messages within a party. Members read directly (RLS); sending
-- goes through a SECURITY DEFINER RPC that checks membership and stamps the
-- author's display name (denormalised so realtime payloads carry it too).
-- Requires the parties schema (20261029000000_parties.sql) first.

create table if not exists public.party_messages (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  author_name text not null default '',
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists party_messages_party_time
  on public.party_messages (party_id, created_at);

alter table public.party_messages enable row level security;

-- Members can read their party's messages. Inserts happen via the RPC only.
drop policy if exists "members read party messages" on public.party_messages;
create policy "members read party messages"
  on public.party_messages for select to authenticated
  using (public.is_party_member(party_id));

-- Send a message (membership-checked; stamps the author's display name).
create or replace function public.send_party_message(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
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

grant execute on function public.send_party_message(uuid, text) to authenticated;

-- Live updates for members (idempotent: only add to the publication once).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'party_messages'
  ) then
    alter publication supabase_realtime add table public.party_messages;
  end if;
end $$;
