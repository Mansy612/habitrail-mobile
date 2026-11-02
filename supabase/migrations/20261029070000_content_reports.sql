-- Chat moderation (App Store Guideline 1.2): a table where any signed-in user
-- can file a report of a message. Reporters may INSERT their own reports; there
-- is no SELECT policy, so operators review reports via the service role / the
-- Supabase dashboard. Blocking is handled on the client. Optional — chat still
-- works without it, but report filing silently no-ops until this is deployed.

create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users (id) on delete cascade,
  scope text not null,          -- 'party' | 'guild' | 'global'
  message_id text not null,
  author_id uuid,
  created_at timestamptz not null default now()
);

alter table public.content_reports enable row level security;

drop policy if exists "file own reports" on public.content_reports;
create policy "file own reports" on public.content_reports
  for insert to authenticated with check (auth.uid() = reporter_id);
