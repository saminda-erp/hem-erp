-- ============================================================
-- HE Manufacturing — Overtime v2 (2026-10-02): day + night shift in one request, HOD confirms actuals
-- Applied to project znxtvkpnwzrzevljdsgx as migration "overtime_v2_shifts_hod_confirm".
--
-- 1) One request can now hold BOTH shifts. Every line carries:
--      shift     'day' | 'night'
--      date      the real calendar date the overtime starts. Day shift = the overtime date.
--                Night shift starting before 12:00 = the NEXT morning (e.g. request for Thu,
--                night shift 05:00–08:00 → Fri). Night shift starting 12:00 or later = same date.
--      day_type  'rest' when that line's own date is a Sunday, else 'normal' (HR can change it,
--                e.g. public holiday, when verifying).
--    The double-booking check now compares real start/end timestamps across neighbouring
--    dates, so a night-shift 05:00 line on Fri also clashes with a Fri day-shift request.
--    Old lines without shift/date are read as shift 'day' on the request's ot_date.
--
-- 2) After the overtime is worked, the HOD confirms the ACTUAL attendance / times / work done on
--    overtime.html (ot_hod_confirm). Their figures are kept on each line as hod_attended,
--    hod_start, hod_end, hod_hours, hod_completed, hod_remark, plus hod_confirmed_by / _at /
--    hod_note on the request. HR then does the final check in the ERP (actual_* fields,
--    status 'verified'), pre-filled from the HOD's figures; payroll pays actual_hours.
--    The HOD can correct their confirmation until HR has verified.
-- ============================================================

alter table hem_ot_requests add column if not exists hod_confirmed_by text;
alter table hem_ot_requests add column if not exists hod_confirmed_at timestamptz;
alter table hem_ot_requests add column if not exists hod_note text;

-- real start timestamp (Kuala Lumpur wall-clock) of one line, and its length in minutes
create or replace function public._ot_line_start(x jsonb, d date) returns timestamp
language sql immutable set search_path to 'public' as $$
  select coalesce(nullif(x->>'date','')::date, d) + make_interval(mins => _ot_mins(x->>'start'))
$$;
create or replace function public._ot_line_mins(x jsonb) returns int
language sql immutable set search_path to 'public' as $$
  select case when _ot_mins(x->>'start') is null or _ot_mins(x->>'end') is null then null
              when _ot_mins(x->>'end') > _ot_mins(x->>'start') then _ot_mins(x->>'end') - _ot_mins(x->>'start')
              else _ot_mins(x->>'end') + 1440 - _ot_mins(x->>'start') end
$$;

create or replace function public.ot_request(p_emp_no text, p_password text, p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare e hem_employees; tdy date := (now() at time zone 'Asia/Kuala_Lumpur')::date; d date; ln jsonb; outl jsonb := '[]'; s int; t int; h numeric; tot numeric := 0;
  emp hem_employees; rid text := p->>'id'; clash text; area text := left(btrim(coalesce(p->>'area','')),80); work text := left(btrim(coalesce(p->>'work','')),1000);
  sh text; ld date; ns timestamp; ne timestamp;
begin
  e := _ot_hod(p_emp_no, p_password);
  if e.emp_no is null then return jsonb_build_object('ok',false,'code','auth'); end if;
  if e.emp_no = '#notallowed' then return jsonb_build_object('ok',false,'code','not_hod'); end if;
  if rid is null or rid !~ '^OT-[0-9]{12,16}$' then return jsonb_build_object('ok',false,'code','bad_id'); end if;
  if exists(select 1 from hem_ot_requests where id=rid) then return jsonb_build_object('ok',false,'code','dup_id'); end if;
  begin d := (p->>'ot_date')::date; exception when others then return jsonb_build_object('ok',false,'code','bad_date'); end;
  if d is null or d < tdy or d > tdy + 60 then return jsonb_build_object('ok',false,'code','bad_date'); end if;
  if length(area) < 2 then return jsonb_build_object('ok',false,'code','area'); end if;
  if length(work) < 10 then return jsonb_build_object('ok',false,'code','work'); end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then return jsonb_build_object('ok',false,'code','no_staff'); end if;
  if jsonb_array_length(p->'lines') > 80 then return jsonb_build_object('ok',false,'code','too_many'); end if;
  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into emp from hem_employees where emp_no = ln->>'emp_no' and status='active';
    if not found then return jsonb_build_object('ok',false,'code','bad_staff','emp_no',ln->>'emp_no'); end if;
    if outl @> jsonb_build_array(jsonb_build_object('emp_no',emp.emp_no)) then return jsonb_build_object('ok',false,'code','dup_staff','name',emp.name); end if;
    sh := coalesce(nullif(ln->>'shift',''),'day');
    if sh not in ('day','night') then return jsonb_build_object('ok',false,'code','bad_shift','name',emp.name); end if;
    s := _ot_mins(ln->>'start'); t := _ot_mins(ln->>'end');
    if s is null or t is null or s = t then return jsonb_build_object('ok',false,'code','bad_time','name',emp.name); end if;
    h := round(((case when t > s then t - s else t + 1440 - s end)::numeric) / 60, 2);
    if h > 12 then return jsonb_build_object('ok',false,'code','too_long','name',emp.name); end if;
    ld := case when sh = 'night' and s < 720 then d + 1 else d end;
    ns := ld + make_interval(mins => s);
    ne := ns + make_interval(mins => (case when t > s then t - s else t + 1440 - s end));
    -- same person already booked for overlapping overtime (real times, neighbouring dates too)
    select r.id into clash from hem_ot_requests r, jsonb_array_elements(r.lines) x
      where r.ot_date between d - 2 and d + 2 and r.status in ('pending','approved')
        and x->>'emp_no' = emp.emp_no and coalesce((x->>'approved')::boolean,true)
        and _ot_line_mins(x) is not null
        and _ot_line_start(x, r.ot_date) < ne
        and _ot_line_start(x, r.ot_date) + make_interval(mins => _ot_line_mins(x)) > ns
      limit 1;
    if clash is not null then return jsonb_build_object('ok',false,'code','clash','name',emp.name,'ref',clash); end if;
    outl := outl || jsonb_build_array(jsonb_build_object('emp_no',emp.emp_no,'name',emp.name,'department',emp.department,
              'shift',sh,'date',ld,'day_type',case when extract(dow from ld) = 0 then 'rest' else 'normal' end,
              'start',ln->>'start','end',ln->>'end','hours',h,'approved',true));
    tot := tot + h;
  end loop;
  insert into hem_ot_requests(id, requested_by, requester_name, ot_date, area, product, work, lines, total_hours, day_type)
  values (rid, e.emp_no, e.name, d, area, nullif(left(btrim(coalesce(p->>'product','')),120),''), work, outl, tot,
          case when extract(dow from d) = 0 then 'rest' else 'normal' end);
  return jsonb_build_object('ok',true,'id',rid,'total_hours',tot,'people',jsonb_array_length(outl));
end $function$;

-- HOD confirms the actual overtime worked (can re-confirm until HR has verified)
--   p = {lines:[{emp_no, attended:bool, start:'HH:MM', end:'HH:MM', completed:'yes'|'partly'|'no', remark}], note}
create or replace function public.ot_hod_confirm(p_emp_no text, p_password text, p_id text, p jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare e hem_employees; r hem_ot_requests; nowkl timestamp := now() at time zone 'Asia/Kuala_Lumpur';
  first_start timestamp; outl jsonb := '[]'; ln jsonb; inp jsonb; s int; t int; h numeric; att boolean; comp text; tot numeric := 0; people int := 0;
begin
  e := _ot_hod(p_emp_no, p_password);
  if e.emp_no is null or e.emp_no = '#notallowed' then return jsonb_build_object('ok',false,'code','auth'); end if;
  select * into r from hem_ot_requests where id = p_id for update;
  if not found or r.requested_by <> e.emp_no then return jsonb_build_object('ok',false,'code','not_found'); end if;
  if r.status <> 'approved' then return jsonb_build_object('ok',false,'code','not_open','status',r.status); end if;
  select min(_ot_line_start(x, r.ot_date)) into first_start
    from jsonb_array_elements(r.lines) x where coalesce((x->>'approved')::boolean,true) and _ot_mins(x->>'start') is not null;
  if first_start is not null and nowkl < first_start then return jsonb_build_object('ok',false,'code','too_early'); end if;
  if jsonb_typeof(p->'lines') <> 'array' then return jsonb_build_object('ok',false,'code','bad_input'); end if;
  for ln in select * from jsonb_array_elements(r.lines) loop
    if not coalesce((ln->>'approved')::boolean,true) then outl := outl || jsonb_build_array(ln); continue; end if;
    inp := null;
    select x into inp from jsonb_array_elements(p->'lines') x where x->>'emp_no' = ln->>'emp_no' limit 1;
    if inp is null then return jsonb_build_object('ok',false,'code','missing','name',ln->>'name'); end if;
    att := coalesce((inp->>'attended')::boolean, true);
    if att then
      s := _ot_mins(inp->>'start'); t := _ot_mins(inp->>'end');
      if s is null or t is null or s = t then return jsonb_build_object('ok',false,'code','bad_time','name',ln->>'name'); end if;
      h := round(((case when t > s then t - s else t + 1440 - s end)::numeric) / 60, 2);
      if h > 16 then return jsonb_build_object('ok',false,'code','too_long','name',ln->>'name'); end if;
      comp := coalesce(nullif(inp->>'completed',''),'yes');
      if comp not in ('yes','partly','no') then comp := 'yes'; end if;
      people := people + 1;
    else
      h := 0; comp := 'no';
    end if;
    outl := outl || jsonb_build_array(ln || jsonb_build_object(
      'hod_attended', att,
      'hod_start', case when att then inp->>'start' else '' end,
      'hod_end',   case when att then inp->>'end' else '' end,
      'hod_hours', h, 'hod_completed', comp,
      'hod_remark', left(btrim(coalesce(inp->>'remark','')),200)));
    tot := tot + h;
  end loop;
  update hem_ot_requests set lines = outl, hod_confirmed_by = e.name, hod_confirmed_at = now(),
         hod_note = nullif(left(btrim(coalesce(p->>'note','')),300),''), updated_at = now()
   where id = p_id;
  return jsonb_build_object('ok',true,'hours',tot,'people',people);
end $function$;

grant execute on function public.ot_hod_confirm(text,text,text,jsonb) to anon, authenticated;

-- ot_data also returns the server's Kuala Lumpur time, so the page knows which overtime has finished
create or replace function public.ot_data(p_emp_no text, p_password text)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare e hem_employees; tdy date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  e := _ot_hod(p_emp_no, p_password);
  if e.emp_no is null then return jsonb_build_object('ok',false,'code','auth'); end if;
  if e.emp_no = '#notallowed' then return jsonb_build_object('ok',false,'code','not_hod','name',e.name); end if;
  return jsonb_build_object('ok',true,'today',tdy,
    'now', to_char(now() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD"T"HH24:MI'),
    'me', jsonb_build_object('emp_no',e.emp_no,'name',e.name,'department',e.department,'position',e.position),
    'areas', coalesce((select value::jsonb from hem_portal_settings where key='ot_areas'),'[]'::jsonb),
    'hr_phone', coalesce((select value from hem_portal_settings where key='ot_hr_whatsapp'),(select value from hem_portal_settings where key='hr_whatsapp')),
    'hr_name', coalesce((select value from hem_portal_settings where key='ot_hr_name'),(select value from hem_portal_settings where key='hr_name')),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('emp_no',emp_no,'name',name,'department',department,'staff_type',staff_type) order by department nulls last, name),'[]')
              from hem_employees where status='active'),
    'requests', (select coalesce(jsonb_agg(to_jsonb(r) - 'updated_at' order by r.ot_date desc, r.created_at desc),'[]')
              from (select * from hem_ot_requests where requested_by = e.emp_no and ot_date >= tdy - 45 order by ot_date desc limit 60) r));
end $function$;
