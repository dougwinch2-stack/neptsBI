-- =====================================================================
-- neptsBI · 09_cleans_oxygen.sql   (run after 01–08)
--
-- DEEP CLEAN – every 12 weeks per van. One contractor per region comes in
-- early in the morning and does 3–4 vans a day, Monday to Friday, working
-- through his rota base by base (Essex: 200 vans / 12 weeks ≈ 3.3 a day).
-- The rota is worked out from the calendar, so it always lands on weekdays
-- as the demo clock rolls. Extra cleans "as required" are logged in
-- deep_cleans and reset the clock.
--   Demo story "problems": the requirement becomes 8 weeks but the
--   contractor's rota stays at 12 → a backlog builds (capacity story).
--
-- OXYGEN – no oxygen on WAVs. Vans with a stretcher (HDU, Bariatric and
-- most PTS): 1 HX + 2 CX (one CX lives on the stretcher). PTS without a
-- stretcher (about 1 in 5): 1 HX + 1 CX. Each cylinder has its own expiry
-- (test date, spread over the next 5 years). Crews check levels daily and
-- swap from the base locker – that belongs with the daily checks (later).
--   Demo story "problems": a couple of out-of-date cylinders still on vans.
--
-- Also: roll_clock and reset_demo now include the new dates and records.
-- Safe to run more than once.
-- =====================================================================
set search_path = neptsbi, public;
begin;

-- ---------- Rules ----------
insert into rules (key, value, unit, label, description) values
  ('deep_clean_weeks',         12, 'weeks', 'Deep clean interval',           'Each van deep cleaned this often (the contractor''s rota)'),
  ('deep_clean_problem_weeks',  8, 'weeks', 'Demo: deep clean requirement', 'Demo "problems" story – required interval while the rota stays at deep_clean_weeks'),
  ('clean_warning_days',        7, 'days',  'Deep clean warning',            'Show a deep clean as Due soon this many days before it is due'),
  ('oxygen_warning_days',      30, 'days',  'Oxygen cylinder warning',       'Show a cylinder as Due soon this many days before its test date runs out')
on conflict (key) do nothing;

-- =====================================================================
-- DEEP CLEAN
-- =====================================================================
create table if not exists deep_cleans (
  id          int generated always as identity primary key,
  vehicle_id  int not null references vehicles(id),
  clean_date  date not null,
  kind        text not null default 'Extra' check (kind in ('Rota', 'Extra')),
  notes       text,
  recorded_at timestamptz not null default now(),
  recorded_by text,
  demo_seed   boolean not null default false
);
create index if not exists deep_cleans_vehicle on deep_cleans(vehicle_id, clean_date desc);

-- Weekdays counted from Monday 1 Jan 2024 (Mon–Fri only), and back again
create or replace function weekday_index(d date) returns int language sql immutable as $$
  select ((d - date '2024-01-01') / 7) * 5 + least(extract(isodow from d)::int, 5) - 1
$$;
create or replace function weekday_from_index(i int) returns date language sql immutable as $$
  select date '2024-01-01' + (i / 5) * 7 + (i % 5)
$$;

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
    case when coalesce(rule('demo_problems'), 0) = 1 then rule('deep_clean_problem_weeks') else rule('deep_clean_weeks') end::int as weeks
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

-- =====================================================================
-- OXYGEN (cylinders are equipment items with their own expiry)
-- =====================================================================
insert into equipment_types (key, label, check_months, sort) values ('oxygen', 'Oxygen', 60, 3)
on conflict (key) do update set label = excluded.label, check_months = excluded.check_months, sort = excluded.sort;
alter table equipment_items add column if not exists expiry_date date;

insert into equipment_items (vehicle_id, kind, serial, position, expiry_date, demo_seed)
select v.id, 'oxygen', 'OX-' || lpad(v.id::text, 5, '0') || '-' || p.n, p.position,
       -- spread over the next 5 years, never inside the first 45 days (demo stays green until the story switches)
       current_date + 45 + ((v.id * 37 + p.n * 211) % 1780),
       true
from vehicles v
join vehicle_classes c on c.id = v.class_id
cross join (values (1, 'HX'), (2, 'CX'), (3, 'CX (stretcher)')) as p(n, position)
where c.short <> 'WAV'
  and (p.n < 3 or c.short in ('HDU', 'BAR') or (c.short = 'PTS' and v.id % 5 <> 0))   -- about 1 in 5 PTS has no stretcher
  and not exists (select 1 from equipment_items e where e.vehicle_id = v.id and e.kind = 'oxygen');

-- "Problems" story: a couple of out-of-date cylinders still on vans
update equipment_items set demo_missed = false where kind = 'oxygen' and demo_missed;
with picks(base, position, n) as (values ('Canvey', 'CX (stretcher)', 3), ('Southend', 'HX', 2)),
ranked as (
  select e.id, b.name as base, e.position,
         row_number() over (partition by b.name, e.position order by v.registration) as n
  from equipment_items e join vehicles v on v.id = e.vehicle_id join bases b on b.id = v.base_id
  where e.kind = 'oxygen'
)
update equipment_items e set demo_missed = true
from ranked r join picks p on p.base = r.base and p.position = r.position and p.n = r.n
where e.id = r.id;

-- Equipment position per vehicle and kind – now including oxygen
drop view if exists vehicle_equipment;
create view vehicle_equipment with (security_invoker = true) as
with days as (
  select cd.base_id, cd.kind, t.check_months,
    nth_weekday(extract(year from current_date)::int,     cd.month, cd.nth, cd.weekday) as this_year,
    nth_weekday(extract(year from current_date)::int - 1, cd.month, cd.nth, cd.weekday) as last_year,
    nth_weekday(extract(year from current_date)::int - 2, cd.month, cd.nth, cd.weekday) as year_before,
    nth_weekday(extract(year from current_date)::int + 1, cd.month, cd.nth, cd.weekday) as next_year
  from equipment_check_days cd join equipment_types t on t.key = cd.kind
), sched as (
  select base_id, kind, check_months,
    case when this_year <= current_date then this_year else last_year end as last_check_day,
    case when this_year <= current_date then last_year else year_before end as prev_check_day,
    case when this_year >  current_date then this_year else next_year end as next_check_day
  from days
), items as (
  select e.vehicle_id, e.kind, e.id, e.position, e.expiry_date,
    (e.demo_missed and coalesce(rule('demo_problems'), 0) = 1) as missed,
    case when e.expiry_date is null then
      coalesce((select max(ch.check_date) from equipment_checks ch
                where ch.item_id = e.id and ch.result in ('Pass', 'Replaced')),
               case when e.demo_missed and coalesce(rule('demo_problems'), 0) = 1 then s.prev_check_day else s.last_check_day end)
    end as last_check,
    s.last_check_day, coalesce(s.check_months, t.check_months) as check_months, s.next_check_day
  from equipment_items e
  join equipment_types t on t.key = e.kind
  join vehicles v on v.id = e.vehicle_id and v.active
  left join sched s on s.base_id = v.base_id and s.kind = e.kind
  where e.active
), items2 as (
  select items.*,
    case
      when expiry_date is not null and missed then current_date - (id % 40 + 3)   -- demo: an out-of-date cylinder still on board
      when expiry_date is not null            then expiry_date
      -- checked items: in date until the end of the month, a year after the check
      else (date_trunc('month', last_check + make_interval(months => check_months)) + interval '1 month - 1 day')::date
    end as item_due
  from items
), per_vehicle as (
  select vehicle_id, kind,
    count(*)                                                    as items,
    string_agg(position, ', ' order by id)                      as positions,
    string_agg(position, ', ' order by id) filter (where item_due < current_date) as overdue_positions,
    min(last_check)                                             as last_check,
    min(item_due)                                               as due_date,
    count(*) filter (where item_due < current_date)             as items_overdue,
    count(*) filter (where missed)                              as items_missed,
    max(last_check_day)                                         as last_check_day,
    min(next_check_day)                                         as next_check_day
  from items2 group by vehicle_id, kind
)
select pv.*,
  pv.due_date - current_date as days_to_due,
  case
    when pv.due_date < current_date then 'Overdue'
    when pv.due_date - current_date <= case when pv.kind = 'oxygen' then rule('oxygen_warning_days') else rule('mot_warning_days') end then 'Due soon'
    else 'OK'
  end as status,
  coalesce(pv.next_check_day <= pv.due_date, false) as booked,   -- the base's next check day comes before it runs out
  pv.next_check_day as booking_date,
  false as awaiting_result
from per_vehicle pv;

-- =====================================================================
-- Demo clock and reset: include the new dates and records
-- =====================================================================
create or replace function roll_clock() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  shift int;
begin
  select current_date - data_date into shift from demo_clock for update;
  if shift is null or shift = 0 then return 0; end if;

  update vehicles         set first_registered = first_registered + shift,
                              lease_end        = lease_end + shift;
  update mot_tests        set test_date   = test_date + shift,
                              expiry_date = expiry_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift);
  update mot_bookings     set appointment_date = appointment_date + shift,
                              recorded_at      = recorded_at + make_interval(days => shift);
  update daily_mileage    set day = day + shift;
  update service_records  set service_date = service_date + shift,
                              recorded_at  = recorded_at + make_interval(days => shift);
  update service_bookings set appointment_date = appointment_date + shift,
                              recorded_at      = recorded_at + make_interval(days => shift);
  update equipment_items  set expiry_date = expiry_date + shift where expiry_date is not null;
  update equipment_checks set check_date  = check_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift);
  update deep_cleans      set clean_date  = clean_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift);
  update demo_clock       set data_date = current_date;
  return shift;
end $$;

create or replace function reset_demo() returns text
language plpgsql security definer set search_path = neptsbi as $$
declare
  removed int := 0; c int;
begin
  if exists (select 1 from demo_clock where last_reset > now() - interval '20 seconds') then
    return 'Demo was reset moments ago';
  end if;
  delete from mot_bookings where not demo_seed;          get diagnostics c = row_count; removed := removed + c;
  delete from mot_tests where not demo_seed;             get diagnostics c = row_count; removed := removed + c;
  delete from service_bookings where not demo_seed;      get diagnostics c = row_count; removed := removed + c;
  delete from service_records where not demo_seed;       get diagnostics c = row_count; removed := removed + c;
  delete from equipment_checks where not demo_seed;      get diagnostics c = row_count; removed := removed + c;
  delete from deep_cleans where not demo_seed;           get diagnostics c = row_count; removed := removed + c;
  update service_bookings set cancelled = false where demo_seed and cancelled;
  update mot_bookings set cancelled = false where demo_seed and cancelled;
  delete from vehicles where not demo_seed;
  perform roll_clock();
  update demo_clock set last_reset = now();
  return format('Demo reset: removed %s demo change(s)', removed);
end $$;

-- ---------- Access ----------
alter table deep_cleans enable row level security;
drop policy if exists "Anyone can read" on deep_cleans;
create policy "Anyone can read" on deep_cleans for select using (true);
grant select on deep_cleans, vehicle_clean, vehicle_equipment, equipment_types, equipment_items to anon, authenticated;
grant execute on function weekday_index(date), weekday_from_index(int) to anon, authenticated;

commit;
notify pgrst, 'reload schema';
