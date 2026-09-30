-- ============================================================
-- HE Manufacturing — New-joiner registration (join.html) + staff documents
-- 2026-09-30 — applied to project znxtvkpnwzrzevljdsgx as migration "new_joiners_staff_docs".
-- Safe to re-run: every statement is idempotent.
--
-- Who can do what:
--   * anonymous (the public join.html page, opened from the Permanent or Part-time QR)
--       -> INSERT one registration only. Never SELECT / UPDATE / DELETE, so one new joiner can
--          never read another's IC, bank account or address — not even their own afterwards.
--       -> upload their own IC / photo / other files into hem-staff-docs under J####-####/…
--          (cannot list, open, overwrite or delete anything).
--   * authenticated (a signed-in ERP session) -> read, update, delete registrations; upload,
--       view (short-lived signed links) and delete any file in hem-staff-docs — this is where HR
--       files the offer letter and appointment letter.
-- ============================================================

create table if not exists hem_new_joiners (
  id            text primary key,                 -- J2609-4821 (shown to the joiner as their reference)
  submitted_at  timestamptz not null default now(),
  staff_type    text not null,                    -- 'Permanent' | 'Part-time' — decided by which QR was scanned
  full_name     text,
  phone         text,
  data          jsonb not null default '{}'::jsonb,   -- everything else the joiner entered
  status        text not null default 'new'
);

alter table hem_new_joiners enable row level security;

drop policy if exists "anon insert joiners" on hem_new_joiners;
create policy "anon insert joiners" on hem_new_joiners
  for insert to anon
  with check (
        status = 'new'
    and staff_type in ('Permanent','Part-time')
    and id ~ '^J[0-9]{4}-[0-9]{4}$'
    and char_length(coalesce(full_name,'')) between 2 and 150
    and char_length(data::text) < 20000
  );

drop policy if exists "staff all joiners" on hem_new_joiners;
create policy "staff all joiners" on hem_new_joiners
  for all to authenticated using (true) with check (true);

grant insert on hem_new_joiners to anon;
grant select, insert, update, delete on hem_new_joiners to authenticated;

create index if not exists hem_new_joiners_submitted_idx on hem_new_joiners (submitted_at desc);

-- ---- private bucket for staff documents -------------------------------------------------
--   J####-####/<file>        joiner's own uploads from join.html (IC / passport, photo, other)
--   emp/<emp no>/<file>      letters HR files in the ERP (offer letter, appointment letter, …)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hem-staff-docs','hem-staff-docs', false, 10485760,
        array['application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif',
              'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "hem-staff-docs anon upload" on storage.objects;
create policy "hem-staff-docs anon upload" on storage.objects
  for insert to anon
  with check (bucket_id = 'hem-staff-docs'
          and name ~ '^J[0-9]{4}-[0-9]{4}/[A-Za-z0-9_-]{1,60}\.(pdf|jpg|jpeg|png|webp|heic|heif)$');

drop policy if exists "hem-staff-docs staff read" on storage.objects;
create policy "hem-staff-docs staff read" on storage.objects
  for select to authenticated using (bucket_id = 'hem-staff-docs');

drop policy if exists "hem-staff-docs staff upload" on storage.objects;
create policy "hem-staff-docs staff upload" on storage.objects
  for insert to authenticated with check (bucket_id = 'hem-staff-docs');

drop policy if exists "hem-staff-docs staff update" on storage.objects;
create policy "hem-staff-docs staff update" on storage.objects
  for update to authenticated using (bucket_id = 'hem-staff-docs') with check (bucket_id = 'hem-staff-docs');

drop policy if exists "hem-staff-docs staff delete" on storage.objects;
create policy "hem-staff-docs staff delete" on storage.objects
  for delete to authenticated using (bucket_id = 'hem-staff-docs');
