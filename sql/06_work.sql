-- =====================================================================
-- neptsBI · 06_work.sql   (run after 01–05)
-- For the Work page (book → test → log the result):
--   * a booking stays "open" until its result is logged (up to 14 days
--     after the appointment), shown as "Waiting for result"
--   * a failed MOT with no pass since is flagged as a Retest
--   * booking again replaces any open booking for that van
--   * a few demo bookings are moved to the last couple of days, so there
--     are results waiting to be logged in every demo
-- =====================================================================
set search_path = neptsbi, public;
begin;

-- ---------- MOT position (same as before + awaiting_result + retest) ----------
create or replace view vehicle_mot with (security_invoker = true) as
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
    and bk.appointment_date >= current_date - 14          -- open until the result is logged
  order by bk.vehicle_id, bk.appointment_date
), calc as (
  select d.*,
    lp.test_date   as last_pass_date,
    lp.mileage     as last_mot_mileage,
    lt.test_date   as last_test_date,
    lt.result      as last_test_result,
    (lp.vehicle_id is null) as first_mot,
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
  (booking_id is not null) as booked,
  (booking_id is not null and booking_date <= current_date) as awaiting_result,
  (last_test_result = 'Fail' and (last_pass_date is null or last_test_date > last_pass_date)) as retest
from calc;

-- ---------- Service position (same as before + awaiting_result) ----------
create or replace view vehicle_service with (security_invoker = true) as
with last_service as (
  select distinct on (vehicle_id) vehicle_id, id, service_date, odometer, service_type
  from service_records order by vehicle_id, service_date desc, id desc
), next_booking as (
  select distinct on (bk.vehicle_id) bk.vehicle_id, bk.id, bk.appointment_date, bk.notes, sp.name as provider_name
  from service_bookings bk left join service_providers sp on sp.id = bk.provider_id
  where not bk.cancelled and bk.completed_by_service is null and bk.appointment_date >= current_date - 14
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
  (booking_id is not null) as booked,
  (booking_id is not null and booking_date <= current_date) as awaiting_result
from calc2;

grant select on vehicle_mot, vehicle_service to anon, authenticated;

-- ---------- Booking again replaces any open booking (past or future) ----------
create or replace function book_mot(
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
  update mot_bookings set cancelled = true
  where vehicle_id = vid and not cancelled and completed_by_test is null;
  insert into mot_bookings (vehicle_id, appointment_date, centre_id, notes, recorded_by)
  values (vid, p_date, p_centre_id, nullif(left(trim(p_notes), 500), ''), pid)
  returning id into new_id;
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
  where vehicle_id = vid and not cancelled and completed_by_service is null;
  insert into service_bookings (vehicle_id, appointment_date, provider_id, notes, recorded_by)
  values (vid, p_date, p_provider_id, nullif(left(trim(p_notes), 500), ''), pid)
  returning id into new_id;
  return new_id;
end $$;

-- ---------- Logging any MOT result closes its booking (a fail becomes a Retest) ----------
create or replace function record_mot(
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

  -- Logging a result (pass or fail) closes the open booking. A fail then shows
  -- in "To book" as a Retest until a pass is logged.
  update mot_bookings set completed_by_test = new_id
  where vehicle_id = vid and not cancelled and completed_by_test is null
    and appointment_date <= current_date + 60;
  return new_id;
end $$;

-- ---------- Demo story: results waiting to be logged ----------
-- Pick vans whose MOT is due in 3–28 days (so a test in the last couple of days keeps
-- the anniversary) – 2 at Canvey, 1 at every other base – and give them a booking
-- for yesterday / the day before. Only runs once, even if this file is run again.
create temporary table chosen on commit drop as
with cand as (
  select vm.id as vehicle_id, b.name as base,
         row_number() over (partition by vm.base_id order by vm.booked, vm.days_to_due, vm.id) as rn
  from vehicle_mot vm join bases b on b.id = vm.base_id
  where vm.days_to_due between 3 and 28
    and vm.registration not in ('AMB017', 'AMB058', 'AMB183', 'AMB224')
)
select vehicle_id, rn from cand
where (rn = 1 or (base = 'Canvey' and rn = 2))
  and not exists (select 1 from mot_bookings x where x.demo_seed and not x.cancelled
                  and x.completed_by_test is null and x.appointment_date <= current_date);

update mot_bookings bk set appointment_date = current_date - ch.rn::int
from chosen ch
where bk.vehicle_id = ch.vehicle_id and bk.demo_seed and not bk.cancelled and bk.completed_by_test is null;

insert into mot_bookings (vehicle_id, appointment_date, centre_id, recorded_at, recorded_by, demo_seed)
select ch.vehicle_id, current_date - ch.rn::int,
       (select mc.id from mot_centres mc join vehicles v on v.id = ch.vehicle_id join bases b on b.id = v.base_id
        where mc.name like b.name || '%' or (b.name like 'Base X%' and mc.name like 'Region X%')
           or (b.name like 'Base Y%' and mc.name like 'Region Y%') order by mc.id limit 1),
       now() - interval '9 days', (select id from people where code = 'admin'), true
from chosen ch
where not exists (select 1 from mot_bookings bk where bk.vehicle_id = ch.vehicle_id and bk.demo_seed
                  and not bk.cancelled and bk.completed_by_test is null);

with ranked as (
  select bk.id, row_number() over (partition by v.base_id order by bk.appointment_date, bk.id) as rn
  from service_bookings bk
  join vehicles v on v.id = bk.vehicle_id
  join vehicle_service vs on vs.vehicle_id = v.id
  where bk.demo_seed and not bk.cancelled and bk.completed_by_service is null
    and vs.status = 'Due soon' and bk.appointment_date > current_date
)
update service_bookings bk set appointment_date = current_date - 1
from ranked r where r.id = bk.id and r.rn = 1
  and not exists (select 1 from service_bookings x where x.demo_seed and not x.cancelled
                  and x.completed_by_service is null and x.appointment_date <= current_date);

commit;
notify pgrst, 'reload schema';
