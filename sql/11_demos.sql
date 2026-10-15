-- =====================================================================
-- neptsBI · 11_demos.sql   (run after 01–10)
-- Numbered demos, each showing one thing. Picking one in the app (⋮ › Demo) resets
-- everything and loads that story. Reset demo (and the 2:30am job) restarts the current one.
--   Demo 1 – Base manager's day: a handful of everyday problems to fix on the phone;
--            deep cleans on target (required 12 weeks = the contractor's rota)
--   Demo 2 – Cleaning capacity: deep cleans required every 8 weeks, contractor's rota still
--            12 → backlog; everything else green (MOT / service problems already sorted)
-- More demos: add a row to demos and a branch in apply_demo_story.
-- Replaces the "Demo story" on/off switch (set_demo_problems). Safe to run more than once.
-- Fix 15 Oct 22:50: every UPDATE inside the reset has a WHERE – Supabase refuses UPDATEs without one
-- when they come from the app ("UPDATE requires a WHERE clause").
-- =====================================================================
set search_path = neptsbi, public;
begin;

create table if not exists demos (
  n           smallint primary key,
  title       text not null,
  description text not null
);
insert into demos (n, title, description) values
  (1, 'Base manager''s day', 'A handful of everyday problems – an MOT result to confirm, a failed MOT, services due, a missed extinguisher, an out-of-date cylinder. Fix them on the phone and watch the rows go green.'),
  (2, 'Cleaning capacity',   'Deep cleans now needed every 8 weeks, but the contractor only gets round every 12. Everything else is green, so the backlog stands out – which bases, how bad, and is one contractor enough?')
on conflict (n) do update set title = excluded.title, description = excluded.description;

insert into rules (key, value, unit, label, description) values
  ('demo_story', 1, 'demo', 'Demo: which story is loaded', 'Demo only – set from the app (⋮ › Demo)'),
  ('deep_clean_required_weeks', 12, 'weeks', 'Deep clean required every', 'How often each van must be deep cleaned (deep_clean_weeks is how often the contractor gets round)')
on conflict (key) do nothing;
delete from rules where key = 'deep_clean_problem_weeks';      -- replaced by deep_clean_required_weeks

-- Deep clean: due = last clean + the REQUIRED interval (was: switched by demo_problems)
drop view if exists vehicle_clean;
create view vehicle_clean with (security_invoker = true) as
with vans as (   -- each region's contractor works through its vans base by base
  select v.id as vehicle_id, b.region_id,
    row_number() over (partition by b.region_id order by b.sort, b.name, v.registration) - 1 as r,
    count(*)     over (partition by b.region_id) as n
  from vehicles v join bases b on b.id = v.base_id
  where v.active
), rota as (
  select vans.*,
    (rule('deep_clean_weeks')::int * 5) as cycle,
    floor(r * rule('deep_clean_weeks')::int * 5 / n)::int as slot,
    weekday_index(current_date - greatest(extract(isodow from current_date)::int - 5, 0)) as today_ix
  from vans
), visits as (
  select vehicle_id, cycle,
    weekday_from_index(today_ix - (((today_ix - slot) % cycle) + cycle) % cycle)         as last_visit,
    weekday_from_index(today_ix - (((today_ix - slot) % cycle) + cycle) % cycle + cycle) as next_visit
  from rota
), calc as (
  select vi.vehicle_id,
    greatest(vi.last_visit, (select max(dc.clean_date) from deep_cleans dc where dc.vehicle_id = vi.vehicle_id)) as last_check,
    vi.next_visit,
    rule('deep_clean_required_weeks')::int as weeks   -- what's required; the rota above is what the contractor can do
  from visits vi
)
select vehicle_id,
  last_check,
  (last_check + weeks * 7) as due_date,
  (last_check + weeks * 7) - current_date as days_to_due,
  case
    when last_check + weeks * 7 < current_date                                   then 'Overdue'
    when (last_check + weeks * 7) - current_date <= rule('clean_warning_days')   then 'Due soon'
    else 'OK'
  end as status,
  (next_visit <= last_check + weeks * 7) as booked,       -- the contractor's next visit comes in time
  next_visit as booking_date,
  false as awaiting_result,
  weeks
from calc;

-- ---------- Load the current story (called after every reset) ----------
create or replace function apply_demo_story() returns void
language plpgsql security definer set search_path = neptsbi as $$
declare
  story int := coalesce(rule('demo_story'), 1)::int;
  centre smallint := (select min(id) from mot_centres where active);
  provider smallint := (select min(id) from service_providers where active);
begin
  update rules set value = case when story = 1 then 1 else 0 end  where key = 'demo_problems';
  update rules set value = case when story = 2 then 8 else 12 end where key = 'deep_clean_required_weeks';

  if story = 2 then
    -- MOT: every VOR van tested and passed (on its booking day if it had one), bookings closed
    drop table if exists fix_mot;
    create temp table fix_mot on commit drop as
      select id as vehicle_id, booking_date, awaiting_result,
             -- on its booking day; otherwise yesterday – or the day of its last test if later (a fail today → passed today)
             case when awaiting_result then greatest(booking_date, coalesce(last_test_date, booking_date))
                  else least(current_date, greatest(current_date - 1, coalesce(last_test_date, current_date - 1))) end as test_date
      from vehicle_mot where vor;
    insert into mot_tests (vehicle_id, test_date, result, expiry_date, mileage, centre_id, recorded_at)
    select f.vehicle_id, f.test_date, 'Pass', mot_expiry_for(f.vehicle_id, f.test_date),
           (select odometer from daily_mileage dm where dm.vehicle_id = f.vehicle_id and dm.day <= f.test_date order by day desc limit 1),
           centre, f.test_date::timestamptz + interval '15 hours'
    from fix_mot f;
    update mot_bookings bk set completed_by_test =
      (select max(t.id) from mot_tests t where t.vehicle_id = bk.vehicle_id and not t.demo_seed)
    where bk.vehicle_id in (select vehicle_id from fix_mot) and not bk.cancelled and bk.completed_by_test is null;
    -- MOT due soon, not booked → booked
    insert into mot_bookings (vehicle_id, appointment_date, centre_id, recorded_at)
    select id, current_date + 5 + id % 10, centre, now() - interval '3 days'
    from vehicle_mot where status = 'Due soon' and not booked and not vor;

    -- Service: overdue / waiting for a result → serviced (on its booking day if it had one), bookings closed
    drop table if exists fix_svc;
    create temp table fix_svc on commit drop as
      select vehicle_id, case when awaiting_result then booking_date else current_date - 1 end as service_date
      from vehicle_service where status = 'Overdue' or awaiting_result;
    insert into service_records (vehicle_id, service_date, odometer, service_type, provider_id, work_done, recorded_at)
    select f.vehicle_id, f.service_date,
           (select odometer from daily_mileage dm where dm.vehicle_id = f.vehicle_id and dm.day <= f.service_date order by day desc limit 1),
           'Full', provider, 'Full service', f.service_date::timestamptz + interval '15 hours'
    from fix_svc f;
    update service_bookings bk set completed_by_service =
      (select max(r.id) from service_records r where r.vehicle_id = bk.vehicle_id and not r.demo_seed)
    where bk.vehicle_id in (select vehicle_id from fix_svc) and not bk.cancelled and bk.completed_by_service is null;
    -- Service due soon, not booked → booked
    insert into service_bookings (vehicle_id, appointment_date, provider_id, recorded_at)
    select vehicle_id, current_date + 3 + vehicle_id % 10, provider, now() - interval '3 days'
    from vehicle_service where status = 'Due soon' and not booked and not awaiting_result;
  end if;
end $$;

-- roll_clock: every UPDATE has a WHERE (Supabase refuses UPDATEs without one from the app)
create or replace function roll_clock() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  shift int;
begin
  select current_date - data_date into shift from demo_clock for update;
  if shift is null or shift = 0 then return 0; end if;

  update vehicles         set first_registered = first_registered + shift,
                              lease_end        = lease_end + shift where true;
  update mot_tests        set test_date   = test_date + shift,
                              expiry_date = expiry_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift) where true;
  update mot_bookings     set appointment_date = appointment_date + shift,
                              recorded_at      = recorded_at + make_interval(days => shift) where true;
  update daily_mileage    set day = day + shift where true;
  update service_records  set service_date = service_date + shift,
                              recorded_at  = recorded_at + make_interval(days => shift) where true;
  update service_bookings set appointment_date = appointment_date + shift,
                              recorded_at      = recorded_at + make_interval(days => shift) where true;
  update equipment_items  set expiry_date = expiry_date + shift where expiry_date is not null;
  update equipment_items  set fitted_at   = fitted_at + shift   where fitted_at is not null;
  update equipment_checks set check_date  = check_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift) where true;
  update deep_cleans      set clean_date  = clean_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift) where true;
  update demo_clock       set data_date = current_date where true;
  return shift;
end $$;

-- ---------- Reset: wipe demo changes, roll dates, load the current story ----------
create or replace function do_reset_demo() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  removed int := 0; c int;
begin
  delete from mot_bookings where not demo_seed;          get diagnostics c = row_count; removed := removed + c;
  delete from mot_tests where not demo_seed;             get diagnostics c = row_count; removed := removed + c;
  delete from service_bookings where not demo_seed;      get diagnostics c = row_count; removed := removed + c;
  delete from service_records where not demo_seed;       get diagnostics c = row_count; removed := removed + c;
  delete from equipment_checks where not demo_seed;      get diagnostics c = row_count; removed := removed + c;
  delete from deep_cleans where not demo_seed;           get diagnostics c = row_count; removed := removed + c;
  delete from equipment_items where not demo_seed;       get diagnostics c = row_count; removed := removed + c;
  update equipment_items set active = true where demo_seed and not active;
  update service_bookings set cancelled = false where demo_seed and cancelled;
  update mot_bookings set cancelled = false where demo_seed and cancelled;
  delete from vehicles where not demo_seed;
  perform roll_clock();
  perform apply_demo_story();
  update demo_clock set last_reset = now() where true;
  return removed;
end $$;

create or replace function reset_demo() returns text
language plpgsql security definer set search_path = neptsbi as $$
begin
  if exists (select 1 from demo_clock where last_reset > now() - interval '20 seconds') then
    return 'Demo was reset moments ago';
  end if;
  perform do_reset_demo();
  return format('Demo %s restarted', coalesce(rule('demo_story'), 1)::int);
end $$;

-- Pick a demo: load it from a clean start
create or replace function set_demo(p_n int) returns text
language plpgsql security definer set search_path = neptsbi as $$
declare
  t text;
begin
  select title into t from demos where n = p_n;
  if t is null then raise exception 'No demo %', p_n; end if;
  if exists (select 1 from demo_clock where last_reset > now() - interval '5 seconds') then
    raise exception 'A demo was loaded moments ago – try again in a few seconds';
  end if;
  update rules set value = p_n where key = 'demo_story';
  perform do_reset_demo();
  return format('Demo %s – %s', p_n, t);
end $$;

drop function if exists set_demo_problems(boolean);

-- ---------- Access ----------
alter table demos enable row level security;
drop policy if exists "Anyone can read" on demos;
create policy "Anyone can read" on demos for select using (true);
grant select on demos, vehicle_clean to anon, authenticated;
revoke execute on function apply_demo_story(), do_reset_demo() from public, anon, authenticated;
revoke execute on function set_demo(int) from public;
grant  execute on function set_demo(int), reset_demo() to anon, authenticated;

-- Start on Demo 1
update rules set value = 1 where key = 'demo_story';
select do_reset_demo();

commit;
notify pgrst, 'reload schema';
