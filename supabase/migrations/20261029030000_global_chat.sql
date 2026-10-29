-- Global chat: one shared room every signed-in user can read and post to (no
-- joining). Reads are open to authenticated users (RLS); posting goes through a
-- SECURITY DEFINER RPC that stamps the author name. Messages stream live via
-- realtime. (A per-user rate limit / moderation is a sensible future add.)

create table if not exists public.global_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  author_name text not null default '',
  body text not null,
  created_at timestamptz not null default now()
);

create index if not exists global_messages_time
  on public.global_messages (created_at);

alter table public.global_messages enable row level security;

drop policy if exists "global messages readable" on public.global_messages;
create policy "global messages readable"
  on public.global_messages for select to authenticated using (true);

create or replace function public.send_global_message(p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if length(trim(p_body)) = 0 then return; end if;
  select coalesce(name, username, 'Player') into v_name
    from profiles where id = auth.uid();
  insert into public.global_messages (user_id, author_name, body)
    values (auth.uid(), coalesce(v_name, 'Player'), left(trim(p_body), 500));
end;
$$;

grant execute on function public.send_global_message(text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'global_messages'
  ) then
    alter publication supabase_realtime add table public.global_messages;
  end if;
end $$;
