-- =====================================================================
-- neptsBI · 07_vor.sql   (run after 01–06)
-- Adds a "vor" (vehicle off road) column to vehicle_mot, so the rule lives
-- in one place and every screen and report agrees:
--   VOR = MOT expired, OR tested and the result not logged yet,
--         OR last test a fail with no pass since.
-- Safe to run more than once.
-- =====================================================================
set search_path = neptsbi, public;
begin;

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
  (last_test_result = 'Fail' and (last_pass_date is null or last_test_date > last_pass_date)) as retest,
  -- VOR (vehicle off road) – strict company rule, agreed 14 Oct 2026: the MOT has expired, OR the van has been
  -- tested and the result isn't logged yet, OR its last test was a fail with no pass since
  (due_date < current_date
   or (booking_id is not null and booking_date <= current_date)
   or coalesce(last_test_result = 'Fail' and (last_pass_date is null or last_test_date > last_pass_date), false)) as vor
from calc;

grant select on vehicle_mot to anon, authenticated;
commit;
notify pgrst, 'reload schema';
