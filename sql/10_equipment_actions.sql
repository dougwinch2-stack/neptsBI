-- =====================================================================
-- neptsBI · 10_equipment_actions.sql   (run after 01–09)
-- The one action in each panel for the newer checks:
--   * Deep clean  – log_deep_clean: an extra clean (as required) restarts the clock
--   * Oxygen      – swap_oxygen: the old cylinder comes off the van, a new one goes on with
--                   the expiry from its label
--   * Fire / defib – log_equipment_check: checked (or replaced) on a date → in date to the end
--                   of the month a year later; covers items missed on the check day
-- Writes only through these functions (like record_mot). Reset demo wipes them.
-- Safe to run more than once.
-- =====================================================================
set search_path = neptsbi, public;
begin;

-- Who recorded it: a person, like the MOT and service tables (both tables are empty until now)
do $$ begin
  if (select data_type from information_schema.columns where table_schema = 'neptsbi' and table_name = 'deep_cleans' and column_name = 'recorded_by') = 'text' then
    alter table deep_cleans alter column recorded_by type int using nullif(recorded_by, '')::int;
  end if;
  if (select data_type from information_schema.columns where table_schema = 'neptsbi' and table_name = 'equipment_checks' and column_name = 'recorded_by') = 'text' then
    alter table equipment_checks alter column recorded_by type int using nullif(recorded_by, '')::int;
  end if;
end $$;
alter table equipment_items  add column if not exists fitted_at   date;
alter table equipment_items  add column if not exists recorded_by int;

-- ---------- Deep clean: log an extra clean ----------
create or replace function log_deep_clean(p_registration text, p_date date, p_notes text, p_person text)
returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  vid int; pid int; new_id int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select id into vid from vehicles where registration = upper(trim(p_registration)) and active;
  if vid is null then raise exception 'Vehicle not found'; end if;
  if p_date is null or p_date > current_date then raise exception 'The clean date can''t be in the future'; end if;
  if p_date < current_date - 30 then raise exception 'The clean date is more than 30 days ago'; end if;
  if exists (select 1 from deep_cleans where vehicle_id = vid and clean_date = p_date) then
    raise exception 'A deep clean is already logged for this van on that day';
  end if;
  insert into deep_cleans (vehicle_id, clean_date, kind, notes, recorded_by)
  values (vid, p_date, 'Extra', nullif(left(trim(p_notes), 500), ''), pid)
  returning id into new_id;
  return new_id;
end $$;

-- ---------- Oxygen: swap a cylinder ----------
create or replace function swap_oxygen(p_item_id int, p_new_expiry date, p_person text)
returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  old equipment_items; pid int; new_id int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select * into old from equipment_items where id = p_item_id and kind = 'oxygen' and active;
  if old.id is null then raise exception 'That cylinder isn''t on the van any more – someone may have just swapped it'; end if;
  if p_new_expiry is null or p_new_expiry <= current_date then raise exception 'The new cylinder''s expiry must be after today'; end if;
  if p_new_expiry > current_date + interval '10 years' then raise exception 'That expiry is more than 10 years away – check the label'; end if;
  update equipment_items set active = false where id = old.id;
  insert into equipment_items (vehicle_id, kind, serial, position, expiry_date, fitted_at, recorded_by)
  values (old.vehicle_id, 'oxygen', 'OX-' || lpad(old.vehicle_id::text, 5, '0') || '-' || left(md5(random()::text || clock_timestamp()::text), 6),
          old.position, p_new_expiry, current_date, pid)
  returning id into new_id;
  return new_id;
end $$;

-- ---------- Fire / defib: log a check for every item of that kind on the van ----------
create or replace function log_equipment_check(p_registration text, p_kind text, p_date date, p_result text, p_person text)
returns int
language plpgsql security definer set search_path = neptsbi as $$
declare
  vid int; pid int; n int;
begin
  perform check_rate_limit();
  pid := person_id_for(p_person, true);
  select id into vid from vehicles where registration = upper(trim(p_registration)) and active;
  if vid is null then raise exception 'Vehicle not found'; end if;
  if p_kind not in ('fire', 'defib') then raise exception 'Only extinguishers and defibs are checked this way'; end if;
  if p_result not in ('Pass', 'Replaced') then raise exception 'Result must be Pass or Replaced'; end if;
  if p_date is null or p_date > current_date then raise exception 'The check date can''t be in the future'; end if;
  if p_date < current_date - 30 then raise exception 'The check date is more than 30 days ago'; end if;
  insert into equipment_checks (item_id, check_date, result, recorded_by)
  select id, p_date, p_result, pid from equipment_items where vehicle_id = vid and kind = p_kind and active;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No % on this van', case when p_kind = 'fire' then 'extinguisher' else 'defib' end; end if;
  return n;
end $$;

-- ---------- Equipment view: a logged check clears the demo "missed" flag
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
    -- demo "missed" only until someone logs a check for the item
    (e.demo_missed and coalesce(rule('demo_problems'), 0) = 1
       and not exists (select 1 from equipment_checks ch where ch.item_id = e.id)) as missed,
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

-- ---------- Reset demo: also put swapped cylinders back ----------
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
  delete from equipment_items where not demo_seed;       get diagnostics c = row_count; removed := removed + c;
  update equipment_items set active = true where demo_seed and not active;
  update service_bookings set cancelled = false where demo_seed and cancelled;
  update mot_bookings set cancelled = false where demo_seed and cancelled;
  delete from vehicles where not demo_seed;
  perform roll_clock();
  update demo_clock set last_reset = now();
  return format('Demo reset: removed %s demo change(s)', removed);
end $$;

-- roll_clock: new cylinders' fitted date moves too
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
  update equipment_items  set fitted_at   = fitted_at + shift   where fitted_at is not null;
  update equipment_checks set check_date  = check_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift);
  update deep_cleans      set clean_date  = clean_date + shift,
                              recorded_at = recorded_at + make_interval(days => shift);
  update demo_clock       set data_date = current_date;
  return shift;
end $$;

-- ---------- Access: the demo app calls these as anon (like record_mot) ----------
revoke execute on function log_deep_clean(text, date, text, text)            from public;
revoke execute on function swap_oxygen(int, date, text)                      from public;
revoke execute on function log_equipment_check(text, text, date, text, text) from public;
grant  execute on function log_deep_clean(text, date, text, text)            to anon, authenticated;
grant  execute on function swap_oxygen(int, date, text)                      to anon, authenticated;
grant  execute on function log_equipment_check(text, text, date, text, text) to anon, authenticated;
grant select on vehicle_equipment to anon, authenticated;

commit;
notify pgrst, 'reload schema';
