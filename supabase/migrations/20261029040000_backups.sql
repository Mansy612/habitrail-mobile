-- Cloud backup: one row per user holding their full on-device save as JSON, so
-- a reinstall / new device can restore progress. RLS: each user reads and
-- writes only their own row. Direct upsert from the client (no RPC needed).

create table if not exists public.user_backups (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.user_backups enable row level security;

drop policy if exists "own backup read" on public.user_backups;
drop policy if exists "own backup insert" on public.user_backups;
drop policy if exists "own backup update" on public.user_backups;

create policy "own backup read" on public.user_backups
  for select to authenticated using (auth.uid() = user_id);
create policy "own backup insert" on public.user_backups
  for insert to authenticated with check (auth.uid() = user_id);
create policy "own backup update" on public.user_backups
  for update to authenticated using (auth.uid() = user_id);
