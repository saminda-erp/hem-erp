-- ============================================================
-- HE Manufacturing — Leave Portal: addendum #2
-- Run this ONCE, after leave-portal-setup.sql, in the same Supabase SQL Editor.
-- Adds the one policy that was deliberately left out before: letting an authenticated
-- ERP session (office staff, already signed in) push employee records directly, for the
-- new "Add employee" / "Batch import" / "Resync everything to portal" tools.
-- The portal itself (anonymous/public key) still gets NO direct access to this table —
-- it only ever reaches it through login_employee(), which never exposes the password.
-- ============================================================

drop policy if exists "authenticated insert employees" on hem_employees;
create policy "authenticated insert employees" on hem_employees for insert with check (auth.role() = 'authenticated');

drop policy if exists "authenticated update employees" on hem_employees;
create policy "authenticated update employees" on hem_employees for update using (auth.role() = 'authenticated');

-- (hem_leave_applications already allows authenticated insert/update from the first script —
-- nothing to add there.)
