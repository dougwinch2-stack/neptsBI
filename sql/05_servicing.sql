-- =====================================================================
-- neptsBI · 05_servicing.sql   (run after 01–04)
-- Servicing: due every 6 months OR 12,000 miles, whichever comes first
-- (both numbers live in the rules table). Service history, bookings,
-- recording a service, and 2 years of demo history built from the
-- daily mileage. Safe to run again: it rebuilds the demo servicing.
-- =====================================================================
set search_path = neptsbi, public;

-- ---------- Rules ----------
insert into rules (key, value, unit, label, description) values
  ('service_warning_days', 30, 'days', 'Service warning (time)', 'Show a service as Due soon this many days before it is due'),
  ('service_warning_miles', 1500, 'miles', 'Service warning (miles)', 'Show a service as Due soon when this many miles are left')
on conflict (key) do nothing;

-- ---------- Tables ----------
create table if not exists service_providers (
  id        smallint generated always as identity primary key,
  name      text not null unique,
  location  text,
  active    boolean not null default true
);

create table if not exists service_records (
  id             int generated always as identity primary key,
  vehicle_id     int not null references vehicles(id),
  service_date   date not null,
  odometer       int not null check (odometer >= 0),
  service_type   text not null check (service_type in ('Interim', 'Full')),
  provider_id    smallint references service_providers(id),
  work_done      text,                 -- "|" separates items
  defects_found  text,                 -- "|" separates items (fixed at the service)
  labour_cost    numeric(8,2) check (labour_cost >= 0),
  parts_cost     numeric(8,2) check (parts_cost >= 0),
  recorded_at    timestamptz not null default now(),
  recorded_by    int references people(id),
  demo_seed      boolean not null default false
);
create index if not exists service_records_vehicle on service_records (vehicle_id, service_date desc);

create table if not exists service_bookings (
  id                    int generated always as identity primary key,
  vehicle_id            int not null references vehicles(id),
  appointment_date      date not null,
  provider_id           smallint references service_providers(id),
  notes                 text,
  cancelled             boolean not null default false,
  completed_by_service  int references service_records(id) on delete set null,
  recorded_at           timestamptz not null default now(),
  recorded_by           int references people(id),
  demo_seed             boolean not null default false
);
create index if not exists service_bookings_vehicle on service_bookings (vehicle_id, appointment_date);

insert into service_providers (name, location) values
  ('Canvey Fleet Workshop (demo)', 'Canvey Island, Essex'),
  ('Chelmsford Van Centre (demo)', 'Chelmsford, Essex'),
  ('Southend Commercial Garage (demo)', 'Southend-on-Sea, Essex'),
  ('Region X Workshop (demo)', 'Region X'),
  ('Region Y Workshop (demo)', 'Region Y')
on conflict (name) do nothing;

-- Which workshop each base normally uses (for the demo data and form defaults)
create or replace function home_provider(p_base_id smallint) returns smallint
language sql stable set search_path = neptsbi as $$
  select sp.id from bases b join service_providers sp on sp.name = case
    when b.name in ('Canvey', 'Chelmsford', 'Southend') then
      case b.name when 'Canvey' then 'Canvey Fleet Workshop (demo)'
                  when 'Chelmsford' then 'Chelmsford Van Centre (demo)'
                  else 'Southend Commercial Garage (demo)' end
    when b.name like 'Base X%' then 'Region X Workshop (demo)'
    else 'Region Y Workshop (demo)' end
  where b.id = p_base_id;
$$;


-- ---------- Where every vehicle stands (worked out, never stored) ----------
create or replace view vehicle_service with (security_invoker = true) as
with last_service as (
  select distinct on (vehicle_id) vehicle_id, id, service_date, odometer, service_type
  from service_records order by vehicle_id, service_date desc, id desc
), next_booking as (
  select distinct on (bk.vehicle_id) bk.vehicle_id, bk.id, bk.appointment_date, bk.notes, sp.name as provider_name
  from service_bookings bk left join service_providers sp on sp.id = bk.provider_id
  where not bk.cancelled and bk.completed_by_service is null and bk.appointment_date >= current_date
  order by bk.vehicle_id, bk.appointment_date
), calc as (
  select v.id as vehicle_id,
    ls.service_date as last_service_date, ls.odometer as last_service_odometer, ls.service_type as last_service_type,
    (coalesce(ls.service_date, v.first_registered) + make_interval(months => rule('service_months')::int))::date as due_date,
    coalesce(ls.odometer, 0) + rule('service_miles')::int as due_odometer,
    coalesce(vm.odometer, ls.odometer, 0) as odometer,
    greatest(coalesce(vm.miles_30, 0) / 30.0, 1) as miles_per_day,
    nb.id as booking_id, nb.appointment_date as booking_date, nb.provider_name as booking_provider, nb.notes as booking_notes
  from vehicles v
  left join last_service ls on ls.vehicle_id = v.id
  left join vehicle_mileage vm on vm.vehicle_id = v.id
  left join next_booking nb on nb.vehicle_id = v.id
  where v.active
), calc2 as (
  select calc.*,
    due_odometer - odometer as miles_left,
    -- the day the miles will run out at its recent rate
    (current_date + floor((due_odometer - odometer) / miles_per_day)::int) as miles_due_date
  from calc
)
select calc2.*,
  least(due_date, miles_due_date) as effective_due_date,
  case when miles_due_date < due_date then 'miles' else 'time' end as due_by,
  case
    when due_date < current_date or miles_left < 0 then 'Overdue'
    when due_date - current_date <= rule('service_warning_days')
      or miles_left <= rule('service_warning_miles')
      or miles_due_date - current_date <= rule('service_warning_days') then 'Due soon'
    else 'OK'
  end as status,
  (booking_id is not null) as booked
from calc2;

create or replace view service_history with (security_invoker = true) as
select s.id, s.vehicle_id, v.registration, s.service_date, s.odometer, s.service_type,
       sp.name as provider_name, s.work_done, s.defects_found, s.labour_cost, s.parts_cost,
       coalesce(s.labour_cost, 0) + coalesce(s.parts_cost, 0) as total_cost,
       s.recorded_at, p.name as recorded_by
from service_records s
join vehicles v on v.id = s.vehicle_id
left join service_providers sp on sp.id = s.provider_id
left join people p on p.id = s.recorded_by;


-- ---------- Demo history, built from the daily mileage ----------
create or replace function generate_demo_servicing() returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  v record; d record;
  last_day date; last_odo int; miles_t int; days_t int; n_full int; prev_odo int;
  admin_id int; svc_type text; defects text; dparts numeric; pid smallint;
  defect_list text[] := array[
    'Front brake pads replaced', 'Front brake discs and pads replaced', 'Rear brake pads replaced',
    'Wiper blades replaced', 'Headlamp bulb replaced', 'Battery replaced', 'Coolant leak repaired',
    'Anti-roll bar link replaced', 'Exhaust bracket repaired', 'Nearside rear tyre replaced',
    'Air conditioning re-gassed', 'Wheel bearing replaced'];
  wav_defects text[] := array['Tail lift serviced and adjusted', 'Wheelchair restraint replaced', 'Ramp hinge lubricated and adjusted'];
  n int := 0;
begin
  delete from service_bookings where demo_seed;
  delete from service_records where demo_seed;
  select id into admin_id from people where code = 'admin';

  for v in
    select ve.id, ve.registration, ve.base_id, ve.first_registered, c.short as cls
    from vehicles ve join vehicle_classes c on c.id = ve.class_id
    where ve.demo_seed order by ve.id
  loop
    pid := home_provider(v.base_id);
    select min(day) into last_day from daily_mileage where vehicle_id = v.id;
    if last_day is null then continue; end if;
    select odometer - miles into prev_odo from daily_mileage where vehicle_id = v.id and day = last_day;
    n_full := (demo_rand(v.id, last_day, 'full') < 0.5)::int;

    if last_day > v.first_registered + 30 then
      -- A service shortly before the 2-year window starts
      last_day := last_day - (20 + demo_rand(v.id, last_day, 'pre') * 120)::int;
      last_odo := greatest(0, prev_odo - ((select avg(miles) from daily_mileage where vehicle_id = v.id) * (
                    (select min(day) from daily_mileage where vehicle_id = v.id) - last_day))::int);
      insert into service_records (vehicle_id, service_date, odometer, service_type, provider_id, work_done,
                                   labour_cost, parts_cost, recorded_at, recorded_by, demo_seed)
      values (v.id, last_day, last_odo, 'Interim', pid, 'Oil and filter change|Safety inspection',
              180, 85, last_day + time '15:30', admin_id, true);
    else
      last_day := v.first_registered; last_odo := 0;
    end if;

    -- Services are usually done a little before they're due
    miles_t := 12000 - (300 + demo_rand(v.id, last_day, 'mt') * 1300)::int;
    days_t  := 182 - (3 + demo_rand(v.id, last_day, 'dt') * 18)::int;

    for d in select day, odometer from daily_mileage where vehicle_id = v.id order by day loop
      if (d.odometer - last_odo >= miles_t or d.day - last_day >= days_t)
         and extract(isodow from d.day) <= 5 then
        n_full := n_full + 1;
        svc_type := case when n_full % 2 = 0 then 'Full' else 'Interim' end;
        defects := null; dparts := 0;
        if demo_rand(v.id, d.day, 'def') < 0.32 then
          defects := defect_list[1 + (demo_rand(v.id, d.day, 'd1') * (array_length(defect_list, 1) - 1))::int];
          dparts := 40 + round((demo_rand(v.id, d.day, 'dc') * 340)::numeric, 0);
          if demo_rand(v.id, d.day, 'def2') < 0.25 then
            defects := defects || '|' || defect_list[1 + (demo_rand(v.id, d.day, 'd2') * (array_length(defect_list, 1) - 1))::int];
            dparts := dparts + 60;
          end if;
        end if;
        if v.cls = 'WAV' and demo_rand(v.id, d.day, 'wav') < 0.4 then
          defects := concat_ws('|', defects, wav_defects[1 + (demo_rand(v.id, d.day, 'w1') * 2)::int]);
          dparts := dparts + 35;
        end if;
        insert into service_records (vehicle_id, service_date, odometer, service_type, provider_id, work_done,
                                     defects_found, labour_cost, parts_cost, recorded_at, recorded_by, demo_seed)
        values (v.id, d.day, d.odometer, svc_type, pid,
                case when svc_type = 'Full'
                  then 'Oil and filter change|Air and fuel filters|Brake fluid check|Full safety inspection'
                  else 'Oil and filter change|Safety inspection' end,
                defects,
                case when svc_type = 'Full' then 260 + round((demo_rand(v.id, d.day, 'lab') * 80)::numeric, 0)
                     else 160 + round((demo_rand(v.id, d.day, 'lab') * 60)::numeric, 0) end,
                case when svc_type = 'Full' then 120 + round((demo_rand(v.id, d.day, 'prt') * 100)::numeric, 0)
                     else 60 + round((demo_rand(v.id, d.day, 'prt') * 50)::numeric, 0) end + dparts,
                d.day + time '16:00' + make_interval(mins => (demo_rand(v.id, d.day, 'rt') * 120)::int),
                admin_id, true);
        n := n + 1;
        last_day := d.day; last_odo := d.odometer;
        miles_t := 12000 - (300 + demo_rand(v.id, d.day, 'mt') * 1300)::int;
        days_t  := 182 - (3 + demo_rand(v.id, d.day, 'dt') * 18)::int;
      end if;
    end loop;
  end loop;

  -- Planted story: a few vans whose last service slipped (now overdue on miles)
  delete from service_records s using (
    select distinct on (ve.base_id) s2.id
    from service_records s2 join vehicles ve on ve.id = s2.vehicle_id join bases b on b.id = ve.base_id
    where s2.demo_seed and b.name in ('Canvey', 'Southend', 'Base Y1')
      and s2.service_date between current_date - 25 and current_date - 10
      and s2.id = (select max(id) from service_records where vehicle_id = s2.vehicle_id)
      and ve.registration not in ('AMB017', 'AMB058', 'AMB183', 'AMB224')
    order by ve.base_id, s2.service_date desc
  ) x where s.id = x.id;
  -- A second one at Canvey, so the base manager has two to deal with
  delete from service_records s using (
    select s2.id from service_records s2 join vehicles ve on ve.id = s2.vehicle_id join bases b on b.id = ve.base_id
    where s2.demo_seed and b.name = 'Canvey' and s2.service_date between current_date - 40 and current_date - 26
      and s2.id = (select max(id) from service_records where vehicle_id = s2.vehicle_id)
      and ve.registration not in ('AMB017', 'AMB058')
    order by s2.service_date desc limit 1
  ) x where s.id = x.id;

  -- Book most of the vans that are due soon (and one of the overdue ones per base)
  insert into service_bookings (vehicle_id, appointment_date, provider_id, notes, recorded_at, recorded_by, demo_seed)
  select vs.vehicle_id,
         case when vs.status = 'Overdue' then current_date + 2
              else least(greatest(current_date + 1, vs.effective_due_date - 3), current_date + 28) end,
         home_provider(ve.base_id),
         case when vs.status = 'Overdue' then 'Over the mileage – first free slot' end,
         now() - make_interval(days => 1 + (demo_rand(vs.vehicle_id, current_date, 'bk') * 10)::int),
         admin_id, true
  from vehicle_service vs join vehicles ve on ve.id = vs.vehicle_id
  where (vs.status = 'Due soon' and demo_rand(vs.vehicle_id, current_date, 'book') < 0.6)
     or (vs.status = 'Overdue' and demo_rand(vs.vehicle_id, current_date, 'book') < 0.5);

  return n;
end $$;
revoke execute on function generate_demo_servicing() from public, anon, authenticated;

select generate_demo_servicing();


-- ---------- Actions ----------
create or replace function record_service(
  p_registration text, p_service_date date, p_odometer int, p_service_type text,
  p_provider_id smallint, p_work_done text, p_defects text,
  p_labour_cost numeric, p_parts_cost numeric, p_person text
) returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  vid int; pid int; new_id int; before_odo int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select id into vid from vehicles where registration = upper(trim(p_registration)) and active;
  if vid is null then raise exception 'Vehicle not found'; end if;
  if p_service_type not in ('Interim', 'Full') then raise exception 'Service type must be Interim or Full'; end if;
  if p_service_date is null or p_service_date > current_date then raise exception 'Service date can''t be in the future'; end if;
  if p_service_date < current_date - 90 then raise exception 'Service date is more than 90 days ago'; end if;
  if p_odometer is null or p_odometer < 0 then raise exception 'Enter the odometer reading'; end if;
  select odometer into before_odo from daily_mileage where vehicle_id = vid and day < p_service_date order by day desc limit 1;
  if before_odo is not null and p_odometer < before_odo then
    raise exception 'Odometer is lower than the reading the day before (%)', before_odo;
  end if;
  if before_odo is not null and p_odometer > before_odo + 2000 then
    raise exception 'Odometer is a lot higher than the last reading (%) – check it', before_odo;
  end if;

  insert into service_records (vehicle_id, service_date, odometer, service_type, provider_id, work_done,
                               defects_found, labour_cost, parts_cost, recorded_by)
  values (vid, p_service_date, p_odometer, p_service_type, p_provider_id,
          nullif(left(trim(p_work_done), 2000), ''), nullif(left(trim(p_defects), 2000), ''),
          greatest(0, p_labour_cost), greatest(0, p_parts_cost), pid)
  returning id into new_id;

  update service_bookings set completed_by_service = new_id
  where vehicle_id = vid and not cancelled and completed_by_service is null
    and appointment_date <= current_date + 60;
  return new_id;
end $$;

create or replace function book_service(
  p_registration text, p_date date, p_provider_id smallint, p_notes text, p_person text
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
  update service_bookings set cancelled = true
  where vehicle_id = vid and not cancelled and completed_by_service is null and appointment_date >= current_date;
  insert into service_bookings (vehicle_id, appointment_date, provider_id, notes, recorded_by)
  values (vid, p_date, p_provider_id, nullif(left(trim(p_notes), 500), ''), pid)
  returning id into new_id;
  return new_id;
end $$;


-- ---------- Rolling clock and reset now include servicing ----------
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
  update service_bookings set cancelled = false where demo_seed and cancelled;
  update mot_bookings set cancelled = false where demo_seed and cancelled;
  delete from vehicles where not demo_seed;
  perform roll_clock();
  update demo_clock set last_reset = now();
  return format('Demo reset: removed %s demo change(s)', removed);
end $$;

create or replace function check_rate_limit() returns void
language plpgsql security definer set search_path = neptsbi as $$
begin
  if (select count(*) from mot_tests        where not demo_seed and recorded_at > now() - interval '1 hour')
   + (select count(*) from mot_bookings     where not demo_seed and recorded_at > now() - interval '1 hour')
   + (select count(*) from service_records  where not demo_seed and recorded_at > now() - interval '1 hour')
   + (select count(*) from service_bookings where not demo_seed and recorded_at > now() - interval '1 hour') >= 200 then
    raise exception 'Too many changes in the last hour – please try again later';
  end if;
end $$;


-- ---------- Security: read-only for the app; changes only through the functions ----------
alter table service_providers enable row level security;
alter table service_records   enable row level security;
alter table service_bookings  enable row level security;
drop policy if exists "Anyone can read" on service_providers;
drop policy if exists "Anyone can read" on service_records;
drop policy if exists "Anyone can read" on service_bookings;
create policy "Anyone can read" on service_providers for select using (true);
create policy "Anyone can read" on service_records   for select using (true);
create policy "Anyone can read" on service_bookings  for select using (true);
grant select on service_providers, service_records, service_bookings, vehicle_service, service_history to anon, authenticated;
revoke execute on function home_provider(smallint) from public;
grant execute on function home_provider(smallint) to anon, authenticated;
grant execute on function record_service(text, date, int, text, smallint, text, text, numeric, numeric, text) to anon, authenticated;
grant execute on function book_service(text, date, smallint, text, text) to anon, authenticated;
revoke execute on function check_rate_limit() from public, anon, authenticated;

notify pgrst, 'reload schema';
