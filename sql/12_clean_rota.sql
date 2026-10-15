-- =====================================================================
-- neptsBI · 12_clean_rota.sql   (run after 01–11)
-- The deep clean contractor's rota as he really works (Doug, 15 Oct): a run of a few days at each
-- base in turn – Essex: 3 days Canvey, 2 Chelmsford, 1 Southend, then round again (6-day run,
-- ~3–4 vans a day, every van once in 12 weeks). Each base sees him every run, so a backlog (Demo 2)
-- builds at every base in proportion to its size instead of piling up at one.
-- Days per base in a run = bases.clean_run_days (Region X / Y guessed 3 + 2).
-- Safe to run more than once.
-- =====================================================================
set search_path = neptsbi, public;
begin;

alter table bases add column if not exists clean_run_days smallint;
update bases b set clean_run_days = d.days
from (values ('Canvey', 3), ('Chelmsford', 2), ('Southend', 1),
             ('Base X1', 3), ('Base X2', 2), ('Base Y1', 3), ('Base Y2', 2)) as d(name, days)
where b.name = d.name;

drop view if exists vehicle_clean;
create view vehicle_clean with (security_invoker = true) as
with base_days as (   -- the contractor's run through a region: a few days at each base in turn (Essex: 3 Canvey, 2 Chelmsford, 1 Southend)
  select b.id as base_id, b.region_id, greatest(coalesce(b.clean_run_days, 1), 1) as days,
    coalesce(sum(greatest(coalesce(b.clean_run_days, 1), 1)) over (partition by b.region_id order by b.sort, b.name
      rows between unbounded preceding and 1 preceding), 0)::int as run_start,
    sum(greatest(coalesce(b.clean_run_days, 1), 1)) over (partition by b.region_id)::int as run_len
  from bases b
), vans as (         -- each base's vans in reg order, spread over that base's days in the 12-week cycle
  select v.id as vehicle_id, bd.*,
    row_number() over (partition by v.base_id order by v.registration) - 1 as r,
    count(*)     over (partition by v.base_id) as n,
    rule('deep_clean_weeks')::int * 5 as cycle
  from vehicles v join base_days bd on bd.base_id = v.base_id
  where v.active
), rota as (
  select vans.*,
    -- j = which of the base's days in the cycle; that day sits in run j/days, at run_start + j%days
    ((floor(r * ((cycle / run_len) * days) / n)::int / days) * run_len + run_start
       + floor(r * ((cycle / run_len) * days) / n)::int % days) as slot,
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

grant select on vehicle_clean to anon, authenticated;

commit;
notify pgrst, 'reload schema';
