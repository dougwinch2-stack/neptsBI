-- =====================================================================
-- neptsBI · 04_mileage.sql   (run after 01–03)
-- Daily mileage: one row per vehicle per day for the last 2 years.
-- The demo data is generated right here in the database (no huge file
-- to paste), and lines up with the mileages on the MOT certificates.
-- Safe to run again: it rebuilds the mileage from scratch.
-- =====================================================================
set search_path = neptsbi, public;

create table if not exists daily_mileage (
  vehicle_id  int  not null references vehicles(id),
  day         date not null,
  miles       int  not null check (miles >= 0),
  odometer    int  not null check (odometer >= 0),
  demo_seed   boolean not null default false,
  -- checked at the end of each statement, so the rolling clock can move every day at once
  constraint daily_mileage_pk primary key (vehicle_id, day) deferrable initially immediate
);
create index if not exists daily_mileage_day on daily_mileage (day);

-- ---------- Demo data generator ----------
-- A repeatable "random" number 0–1 for a vehicle, a day and a purpose
create or replace function demo_rand(v int, d date, salt text) returns float8
language sql immutable as $$
  select (hashtext(v::text || ':' || d::text || ':' || salt)::bigint & 2147483647) / 2147483647.0;
$$;

create or replace function generate_demo_mileage() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  n int;
begin
  delete from daily_mileage;

  -- MOT mileages must never go down (tidies the demo history)
  update mot_tests t set mileage = x.m
  from (select id, max(mileage) over (partition by vehicle_id order by test_date, id) as m
        from mot_tests where mileage is not null) x
  where x.id = t.id and t.mileage <> x.m;

  with params as (
    select v.id, v.first_registered, v.fuel, c.short as cls,
           greatest(current_date - 730, v.first_registered) as start_day,
           -- Last MOT before the 2-year window gives the starting mileage
           a.test_date as anchor_date, a.mileage as anchor_miles,
           -- Miles per day from the MOT history (fallback ~30k a year)
           coalesce(r.rate, 82.0) as rate,
           m.due_date as mot_due
    from vehicles v
    join vehicle_classes c on c.id = v.class_id
    join vehicle_mot m on m.id = v.id
    left join lateral (
      select t.test_date, t.mileage from mot_tests t
      where t.vehicle_id = v.id and t.mileage is not null
        and t.test_date < greatest(current_date - 730, v.first_registered)
      order by t.test_date desc limit 1) a on true
    left join lateral (   -- needs at least 6 months between MOTs; kept between 50 and 115 a day
      select case when max(t.test_date) - min(t.test_date) >= 180 then
               least(115, greatest(50, (max(t.mileage) - min(t.mileage))::numeric / (max(t.test_date) - min(t.test_date))))
             end as rate
      from mot_tests t where t.vehicle_id = v.id and t.mileage is not null and t.result = 'Pass') r on true
  ),
  days as (
    select p.*, d::date as day, extract(isodow from d)::int as dow, extract(month from d)::int as mon
    from params p, generate_series(p.start_day, current_date - 1, interval '1 day') d
  ),
  miles as (
    select id, day, start_day, first_registered, anchor_date, anchor_miles, rate,
      case
        when day > mot_due then 0                                           -- off road: MOT expired
        when exists (select 1 from mot_tests t where t.vehicle_id = days.id and t.test_date = days.day)
          then 12 + (demo_rand(id, day, 'mot') * 20)::int                     -- trip to the test centre
        when demo_rand(id, day, 'off') < 0.025 then 0                         -- off for a repair / spare
        else round(rate * 1.07
             * case when dow <= 5 then 1.12 when dow = 6 then 0.7 else 0.45 end  -- quieter weekends
             * case when mon in (12, 1, 2) then 1.05 when mon = 8 then 0.9 else 1.0 end
             * (0.6 + demo_rand(id, day, 'noise') * 0.8)
             * case when cls in ('HDU', 'BAR') then 0.9 else 1.0 end)::int
      end as miles
    from days
  )
  insert into daily_mileage (vehicle_id, day, miles, odometer, demo_seed)
  select id, day, miles,
         (coalesce(anchor_miles, 0)
          -- no earlier MOT: miles since first registration at the usual rate
          + (rate * (start_day - coalesce(anchor_date, first_registered)))::int
          + sum(miles) over (partition by id order by day))::int,
         true
  from miles;
  get diagnostics n = row_count;

  -- MOT certificates in the window now show the odometer reading for that day
  update mot_tests t set mileage = d.odometer
  from daily_mileage d
  where d.vehicle_id = t.vehicle_id and d.day = t.test_date;

  -- A test today (no mileage row yet) mustn't show less than yesterday's odometer
  update mot_tests t set mileage = d.odometer + 10
  from daily_mileage d
  where d.vehicle_id = t.vehicle_id and d.day = current_date - 1
    and t.test_date >= current_date and t.mileage < d.odometer;

  return n;
end $$;
revoke execute on function generate_demo_mileage() from public, anon, authenticated;

select generate_demo_mileage();


-- ---------- Views the app reads ----------
-- One row per vehicle: odometer and recent miles
create or replace view vehicle_mileage with (security_invoker = true) as
select d.vehicle_id,
  (array_agg(d.odometer order by d.day desc))[1]                          as odometer,
  max(d.day)                                                              as odometer_date,
  coalesce(sum(d.miles) filter (where d.day >= current_date - 7), 0)::int   as miles_7,
  coalesce(sum(d.miles) filter (where d.day >= current_date - 30), 0)::int  as miles_30,
  coalesce(sum(d.miles) filter (where d.day >= current_date - 365), 0)::int as miles_365,
  count(*) filter (where d.day >= current_date - 30 and d.miles > 0)::int as days_used_30
from daily_mileage d
group by d.vehicle_id;

-- Weekly miles per base (last 2 years), for trend charts
create or replace view mileage_weekly with (security_invoker = true) as
select v.base_id, date_trunc('week', d.day)::date as week_start,
       sum(d.miles)::int as miles,
       count(distinct d.vehicle_id) filter (where d.miles > 0)::int as vans_used
from daily_mileage d
join vehicles v on v.id = d.vehicle_id
group by v.base_id, date_trunc('week', d.day);

-- Average miles per van by day of the week (last 13 weeks): the busiest days
create or replace view mileage_weekday with (security_invoker = true) as
select v.base_id, extract(isodow from d.day)::int as dow,
       sum(d.miles)::int as miles, count(*)::int as van_days
from daily_mileage d
join vehicles v on v.id = d.vehicle_id
where d.day >= current_date - 91
group by v.base_id, extract(isodow from d.day);


-- ---------- Rolling clock now moves mileage too ----------
create or replace function roll_clock() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  shift int;
begin
  select current_date - data_date into shift from demo_clock for update;
  if shift is null or shift = 0 then return 0; end if;

  update vehicles      set first_registered = first_registered + shift,
                           lease_end        = lease_end + shift;
  update mot_tests     set test_date   = test_date + shift,
                           expiry_date = expiry_date + shift,
                           recorded_at = recorded_at + make_interval(days => shift);
  update mot_bookings  set appointment_date = appointment_date + shift,
                           recorded_at      = recorded_at + make_interval(days => shift);
  update daily_mileage set day = day + shift;
  update demo_clock    set data_date = current_date;
  return shift;
end $$;

-- Security: read-only for the app
alter table daily_mileage enable row level security;
drop policy if exists "Anyone can read" on daily_mileage;
create policy "Anyone can read" on daily_mileage for select using (true);
grant select on daily_mileage, vehicle_mileage, mileage_weekly, mileage_weekday to anon, authenticated;
grant execute on function demo_rand(int, date, text) to anon, authenticated;

notify pgrst, 'reload schema';
