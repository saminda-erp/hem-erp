-- ============================================================
-- HE Manufacturing — Candidate Application (apply.html) setup
-- Run this ONCE in the Supabase SQL Editor (project znxtvkpnwzrzevljdsgx).
-- Safe to re-run: every statement is idempotent.
--
-- Who can do what:
--   * anonymous (the public apply.html page, no login)  -> INSERT a new application only.
--     It can never SELECT, UPDATE or DELETE, so one candidate can never read another's
--     salary, address or test answers — not even their own after submitting.
--   * authenticated (a signed-in ERP session)            -> read, update, delete.
-- ============================================================

create table if not exists hem_candidates (
  id            text primary key,
  submitted_at  timestamptz not null default now(),
  position      text,
  category      text,          -- 'general' | 'executive' — decides which aptitude test was given
  full_name     text,
  phone         text,
  data          jsonb not null default '{}'::jsonb,   -- everything else the candidate entered
  answers       jsonb not null default '{}'::jsonb,   -- {question id: chosen option index}; marked in the ERP
  test_version  text,
  test_seconds  integer,
  status        text not null default 'new'
);

alter table hem_candidates enable row level security;

-- the public form may only create brand-new, sensibly-sized rows
drop policy if exists "anon insert candidates" on hem_candidates;
create policy "anon insert candidates" on hem_candidates
  for insert to anon
  with check (
        status = 'new'
    and category in ('general','executive')
    and char_length(coalesce(full_name,'')) between 2 and 150
    and char_length(data::text)    < 20000
    and char_length(answers::text) < 2000
  );

drop policy if exists "authenticated read candidates" on hem_candidates;
create policy "authenticated read candidates" on hem_candidates
  for select to authenticated using (true);

drop policy if exists "authenticated update candidates" on hem_candidates;
create policy "authenticated update candidates" on hem_candidates
  for update to authenticated using (true) with check (true);

drop policy if exists "authenticated delete candidates" on hem_candidates;
create policy "authenticated delete candidates" on hem_candidates
  for delete to authenticated using (true);

grant insert on hem_candidates to anon;
grant select, insert, update, delete on hem_candidates to authenticated;

create index if not exists hem_candidates_submitted_idx on hem_candidates (submitted_at desc);

-- ============================================================
-- CV uploads (added 2026-09-29) — private Storage bucket 'hem-cvs'
--   * anonymous (apply.html) -> upload only, into <reference no.>/<file>, max 10 MB, PDF/images.
--     Cannot list, download, overwrite or delete anything.
--   * authenticated ERP users -> view (via short-lived signed links) and delete.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hem-cvs','hem-cvs', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "hem-cvs anon upload" on storage.objects;
create policy "hem-cvs anon upload" on storage.objects
  for insert to anon
  with check (bucket_id = 'hem-cvs' and name ~ '^C[0-9]{4}-[0-9]{4}/[A-Za-z0-9._-]{1,80}$');

drop policy if exists "hem-cvs staff read" on storage.objects;
create policy "hem-cvs staff read" on storage.objects
  for select to authenticated using (bucket_id = 'hem-cvs');

drop policy if exists "hem-cvs staff delete" on storage.objects;
create policy "hem-cvs staff delete" on storage.objects
  for delete to authenticated using (bucket_id = 'hem-cvs');
