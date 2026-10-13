-- =====================================================================
-- neptsBI · 01_schema.sql
-- Run once in Supabase: SQL Editor → New query → paste → Run.
-- Then run 02_demo_data.sql, then 03_nightly_reset.sql.
--
-- Everything lives in its own schema "neptsbi", so it never touches the
-- parking app's tables. Supabase must be told to expose it once
-- (see SETUP.md, step 2).
--
-- ALL DATA IS DUMMY DEMO DATA. People are roles/numbers, never real names.
--
-- Design rules
--   * Store facts (tests, bookings, rules); work out status (overdue, due
--     soon, OK) in views – never typed in.
--   * Rules (e.g. "warn 30 days before MOT") live in the rules table, so
--     changing a rule changes every screen.
--   * Rolling clock: demo_clock.data_date is the day the stored dates are
--     "true" for. Each night (or on first visit of the day) every date is
--     moved forward, so the demo always looks current.
--   * Anything added during a demo (demo_seed = false) is wiped by
--     reset_demo(), so every demo starts from the same story.
-- =====================================================================

create schema if not exists neptsbi;
set search_path = neptsbi, public;

-- ---------- Organisation ----------
create table regions (
  id     smallint generated always as identity primary key,
  name   text not null unique,
  sort   smallint not null default 0
);

create table bases (
  id         smallint generated always as identity primary key,
  region_id  smallint not null references regions(id),
  name       text not null unique,
  sort       smallint not null default 0
);

-- ---------- Vehicles ----------
create table vehicle_classes (
  id     smallint generated always as identity primary key,
  name   text not null unique,          -- e.g. "Patient Transport Ambulance"
  short  text not null unique,          -- e.g. "PTS"
  sort   smallint not null default 0
);

create table vehicles (
  id               int generated always as identity primary key,
  registration     text not null unique,               -- demo regs: AMB001…
  fleet_number     text not null unique,
  make             text not null,
  model            text not null,
  class_id         smallint not null references vehicle_classes(id),
  base_id          smallint not null references bases(id),
  first_registered date not null,                      -- first MOT due 3 years after this
  fuel             text not null check (fuel in ('Diesel', 'Electric', 'Petrol', 'Hybrid')),
  ownership        text not null check (ownership in ('Owned', 'Leased')),
  lessor           text,                               -- leasing company (made up)
  lease_end        date,
  active           boolean not null default true,
  demo_seed        boolean not null default false,
  check (ownership = 'Owned' or lease_end is not null)
);
create index vehicles_base on vehicles (base_id);

-- ---------- People & roles (demo: roles and numbers only) ----------
create table roles (
  key          text primary key,                       -- used in links: ?as=ceo
  label        text not null,
  scope        text not null check (scope in ('company', 'region', 'base', 'self')),
  can_record   boolean not null default false,         -- may add MOTs, bookings…
  available    boolean not null default true,          -- false = "coming soon" tile
  description  text,
  sort         smallint not null default 0
);

create table people (
  id         int generated always as identity primary key,
  code       text not null unique,                     -- used in links: ?as=base-canvey
  name       text not null,                            -- e.g. "Canvey Base Manager", "Driver 001"
  role_key   text not null references roles(key),
  region_id  smallint references regions(id),
  base_id    smallint references bases(id),
  featured   boolean not null default false,           -- shown as a big tile on the sign-in page
  sort       smallint not null default 0
);

-- ---------- Rules (editable thresholds) ----------
create table rules (
  key          text primary key,
  value        numeric not null,
  unit         text not null,
  label        text not null,
  description  text
);

-- ---------- MOT ----------
create table mot_centres (
  id        smallint generated always as identity primary key,
  name      text not null unique,
  location  text,
  active    boolean not null default true
);

create table mot_tests (
  id               int generated always as identity primary key,
  vehicle_id       int not null references vehicles(id),
  test_date        date not null,
  result           text not null check (result in ('Pass', 'Fail')),
  expiry_date      date,                               -- from the certificate (passes only)
  mileage          int check (mileage >= 0),
  advisories       text,                               -- "|" separates items
  failure_reasons  text,                               -- "|" separates items
  centre_id        smallint references mot_centres(id),
  recorded_at      timestamptz not null default now(),
  recorded_by      int references people(id),
  demo_seed        boolean not null default false,
  check ((result = 'Pass') = (expiry_date is not null)),
  check (expiry_date is null or expiry_date > test_date)
);
create index mot_tests_vehicle on mot_tests (vehicle_id, test_date desc);

create table mot_bookings (
  id                 int generated always as identity primary key,
  vehicle_id         int not null references vehicles(id),
  appointment_date   date not null,
  centre_id          smallint references mot_centres(id),
  notes              text,
  cancelled          boolean not null default false,
  completed_by_test  int references mot_tests(id) on delete set null,   -- set when the MOT is recorded
  recorded_at        timestamptz not null default now(),
  recorded_by        int references people(id),
  demo_seed          boolean not null default false
);
create index mot_bookings_vehicle on mot_bookings (vehicle_id, appointment_date);

-- ---------- Rolling clock ----------
create table demo_clock (
  id          boolean primary key default true check (id),   -- only ever one row
  data_date   date not null,                                 -- stored dates are correct for this day
  last_reset  timestamptz
);


-- =====================================================================
-- VIEWS (what the app reads)
-- =====================================================================

create function rule(p_key text) returns numeric
language sql stable set search_path = neptsbi as $$
  select value from rules where key = p_key;
$$;

-- One row per vehicle with its organisation details
create view vehicle_details with (security_invoker = true) as
select
  v.id, v.registration, v.fleet_number, v.make, v.model,
  c.name  as class_name, c.short as class_short,
  b.id    as base_id,   b.name as base_name,
  r.id    as region_id, r.name as region_name,
  v.first_registered,
  date_part('year', v.first_registered)::int as year,
  v.fuel, v.ownership, v.lessor, v.lease_end, v.active
from vehicles v
join vehicle_classes c on c.id = v.class_id
join bases b   on b.id = v.base_id
join regions r on r.id = b.region_id;

-- MOT position of every active vehicle, worked out from the facts
create view vehicle_mot with (security_invoker = true) as
with last_pass as (
  select distinct on (vehicle_id) vehicle_id, test_date, expiry_date, mileage, centre_id
  from mot_tests where result = 'Pass'
  order by vehicle_id, test_date desc, id desc
), last_test as (
  select distinct on (vehicle_id) vehicle_id, test_date, result
  from mot_tests
  order by vehicle_id, test_date desc, id desc
), next_booking as (
  select distinct on (bk.vehicle_id) bk.vehicle_id, bk.id, bk.appointment_date, bk.notes,
         mc.name as centre_name
  from mot_bookings bk
  left join mot_centres mc on mc.id = bk.centre_id
  where not bk.cancelled and bk.completed_by_test is null
    and bk.appointment_date >= current_date
  order by bk.vehicle_id, bk.appointment_date
), calc as (
  select d.*,
    lp.test_date   as last_pass_date,
    lp.mileage     as last_mot_mileage,
    lt.test_date   as last_test_date,
    lt.result      as last_test_result,
    (lp.vehicle_id is null) as first_mot,
    -- No MOT yet: first one is due on the 3rd anniversary of registration
    coalesce(lp.expiry_date, (d.first_registered + interval '3 years')::date) as due_date,
    nb.id               as booking_id,
    nb.appointment_date as booking_date,
    nb.centre_name      as booking_centre,
    nb.notes            as booking_notes
  from vehicle_details d
  left join last_pass lp on lp.vehicle_id = d.id
  left join last_test lt on lt.vehicle_id = d.id
  left join next_booking nb on nb.vehicle_id = d.id
  where d.active
)
select calc.*,
  (due_date - current_date) as days_to_due,
  case
    when due_date < current_date                                    then 'Overdue'
    when due_date - current_date <= rule('mot_warning_days')        then 'Due soon'
    else 'OK'
  end as status,
  (booking_id is not null) as booked
from calc;

-- Full history for one vehicle's page (newest first)
create view mot_history with (security_invoker = true) as
select t.id, t.vehicle_id, v.registration, t.test_date, t.result, t.expiry_date, t.mileage,
       t.advisories, t.failure_reasons, mc.name as centre_name,
       t.recorded_at, p.name as recorded_by
from mot_tests t
join vehicles v on v.id = t.vehicle_id
left join mot_centres mc on mc.id = t.centre_id
left join people p on p.id = t.recorded_by;


-- =====================================================================
-- ROLLING CLOCK & DEMO RESET
-- =====================================================================

-- Move every stored date forward so the data is "true" for today.
-- Safe to call any number of times; does nothing if already up to date.
create function roll_clock() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  shift int;
begin
  select current_date - data_date into shift from demo_clock for update;
  if shift is null or shift = 0 then return 0; end if;

  update vehicles     set first_registered = first_registered + shift,
                          lease_end        = lease_end + shift;
  update mot_tests    set test_date   = test_date + shift,
                          expiry_date = expiry_date + shift,
                          recorded_at = recorded_at + make_interval(days => shift);
  update mot_bookings set appointment_date = appointment_date + shift,
                          recorded_at      = recorded_at + make_interval(days => shift);
  update demo_clock   set data_date = current_date;
  return shift;
end $$;

-- Wipe anything added during demos, then bring dates up to today.
create function reset_demo() returns text
language plpgsql security definer set search_path = neptsbi as $$
declare
  removed_tests int; removed_bookings int;
begin
  -- Stop it being hammered: at most once every 20 seconds
  if exists (select 1 from demo_clock where last_reset > now() - interval '20 seconds') then
    return 'Demo was reset moments ago';
  end if;

  delete from mot_bookings where not demo_seed;
  get diagnostics removed_bookings = row_count;
  delete from mot_tests where not demo_seed;          -- seed bookings they completed re-open
  get diagnostics removed_tests = row_count;
  delete from vehicles where not demo_seed;

  perform roll_clock();
  update demo_clock set last_reset = now();
  return format('Demo reset: removed %s MOT record(s) and %s booking(s)', removed_tests, removed_bookings);
end $$;


-- =====================================================================
-- ACTIONS (the only way the app can change data)
-- =====================================================================

-- Rate limit for demo actions: nobody can flood the tables
create function check_rate_limit() returns void
language plpgsql security definer set search_path = neptsbi as $$
begin
  if (select count(*) from mot_tests    where not demo_seed and recorded_at > now() - interval '1 hour')
   + (select count(*) from mot_bookings where not demo_seed and recorded_at > now() - interval '1 hour') >= 200 then
    raise exception 'Too many changes in the last hour – please try again later';
  end if;
end $$;

create function person_id_for(p_code text, need_record boolean) returns int
language plpgsql stable security definer set search_path = neptsbi as $$
declare
  pid int; allowed boolean;
begin
  select p.id, r.can_record into pid, allowed
  from people p join roles r on r.key = p.role_key where p.code = p_code;
  if pid is null then raise exception 'Unknown person'; end if;
  if need_record and not allowed then raise exception 'This role can''t record changes'; end if;
  return pid;
end $$;

-- Expiry printed on a new pass certificate (UK rule): tested up to a month
-- (minus a day) before the current expiry → keeps the anniversary date.
create function mot_expiry_for(p_vehicle_id int, p_test_date date) returns date
language sql stable security definer set search_path = neptsbi as $$
  select case
    when m.due_date is not null
     and p_test_date >= (m.due_date - interval '1 month' + interval '1 day')::date
     and p_test_date <= m.due_date
      then (m.due_date + interval '1 year')::date
    else (p_test_date + interval '1 year' - interval '1 day')::date
  end
  from (select max(expiry_date) as due_date from mot_tests
        where vehicle_id = p_vehicle_id and result = 'Pass') m;
$$;

create function record_mot(
  p_registration text, p_test_date date, p_result text, p_mileage int,
  p_centre_id smallint, p_advisories text, p_failure_reasons text,
  p_expiry_date date, p_person text
) returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  vid int; pid int; new_id int; expiry date; last_mileage int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select id into vid from vehicles where registration = upper(trim(p_registration)) and active;
  if vid is null then raise exception 'Vehicle not found'; end if;
  if p_result not in ('Pass', 'Fail') then raise exception 'Result must be Pass or Fail'; end if;
  if p_test_date is null or p_test_date > current_date then
    raise exception 'Test date can''t be in the future';
  end if;
  if p_test_date < current_date - 90 then
    raise exception 'Test date is more than 90 days ago';
  end if;
  select max(mileage) into last_mileage from mot_tests where vehicle_id = vid and test_date < p_test_date;
  if p_mileage is not null and last_mileage is not null and p_mileage < last_mileage then
    raise exception 'Mileage is lower than at the last MOT (%)', last_mileage;
  end if;

  if p_result = 'Pass' then
    expiry := coalesce(p_expiry_date, mot_expiry_for(vid, p_test_date));
    if expiry < p_test_date + 300 or expiry > p_test_date + 400 then
      raise exception 'Expiry date doesn''t look right for a test on %', p_test_date;
    end if;
  end if;

  insert into mot_tests (vehicle_id, test_date, result, expiry_date, mileage, advisories,
                         failure_reasons, centre_id, recorded_by)
  values (vid, p_test_date, p_result, expiry, p_mileage,
          nullif(left(trim(p_advisories), 2000), ''),
          case when p_result = 'Fail' then nullif(left(trim(p_failure_reasons), 2000), '') end,
          p_centre_id, pid)
  returning id into new_id;

  -- A pass completes any open booking for this vehicle
  if p_result = 'Pass' then
    update mot_bookings set completed_by_test = new_id
    where vehicle_id = vid and not cancelled and completed_by_test is null
      and appointment_date <= current_date + 60;
  end if;
  return new_id;
end $$;

create function book_mot(
  p_registration text, p_date date, p_centre_id smallint, p_notes text, p_person text
) returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  vid int; pid int; new_id int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select id into vid from vehicles where registration = upper(trim(p_registration)) and active;
  if vid is null then raise exception 'Vehicle not found'; end if;
  if p_date is null or p_date < current_date or p_date > current_date + 120 then
    raise exception 'Pick a date between today and 4 months ahead';
  end if;
  -- One open booking per vehicle: replace any existing one
  update mot_bookings set cancelled = true
  where vehicle_id = vid and not cancelled and completed_by_test is null and appointment_date >= current_date;
  insert into mot_bookings (vehicle_id, appointment_date, centre_id, notes, recorded_by)
  values (vid, p_date, p_centre_id, nullif(left(trim(p_notes), 500), ''), pid)
  returning id into new_id;
  return new_id;
end $$;


-- =====================================================================
-- SECURITY
--   Everyone (it's a public demo): read everything in neptsbi.
--   Changes only through the functions above (validated, rate limited,
--   wiped by the nightly reset). No direct inserts/updates/deletes.
-- =====================================================================

alter table regions         enable row level security;
alter table bases           enable row level security;
alter table vehicle_classes enable row level security;
alter table vehicles        enable row level security;
alter table roles           enable row level security;
alter table people          enable row level security;
alter table rules           enable row level security;
alter table mot_centres     enable row level security;
alter table mot_tests       enable row level security;
alter table mot_bookings    enable row level security;
alter table demo_clock      enable row level security;

create policy "Anyone can read" on regions         for select using (true);
create policy "Anyone can read" on bases           for select using (true);
create policy "Anyone can read" on vehicle_classes for select using (true);
create policy "Anyone can read" on vehicles        for select using (true);
create policy "Anyone can read" on roles           for select using (true);
create policy "Anyone can read" on people          for select using (true);
create policy "Anyone can read" on rules           for select using (true);
create policy "Anyone can read" on mot_centres     for select using (true);
create policy "Anyone can read" on mot_tests       for select using (true);
create policy "Anyone can read" on mot_bookings    for select using (true);
create policy "Anyone can read" on demo_clock      for select using (true);

grant usage on schema neptsbi to anon, authenticated;
grant select on all tables in schema neptsbi to anon, authenticated;
revoke execute on all functions in schema neptsbi from public;
grant execute on function rule(text)                    to anon, authenticated;
grant execute on function roll_clock()                  to anon, authenticated;
grant execute on function reset_demo()                  to anon, authenticated;
grant execute on function mot_expiry_for(int, date)     to anon, authenticated;
grant execute on function record_mot(text, date, text, int, smallint, text, text, date, text) to anon, authenticated;
grant execute on function book_mot(text, date, smallint, text, text)                          to anon, authenticated;

-- Tell Supabase's API to pick up the new tables
notify pgrst, 'reload schema';
