-- =====================================================================
-- neptsBI · 08_equipment.sql   (run after 01–07)
-- Fire extinguishers and defibs on each vehicle, checked once a year on a
-- check day per base (someone visits and does them all in one go):
--   * fire extinguishers – a Saturday; each base a different month (Canvey: October)
--   * defibs             – a Sunday, when most vans are at base; each base a
--                          different month (Canvey: May)
--   * one defib per vehicle; one extinguisher per vehicle, two on the big
--     vans with a bulkhead (High Dependency and Bariatric)
-- Check days are stored as "nth weekday of a month", so they always land on
-- the right day as the demo clock rolls on. An item is in date until the end
-- of the month, a year after its check (like a service label).
-- Until a check is logged, an item counts as checked on its base's last check day.
-- Two demo stories (switch in the app's ⋮ menu): all green, or a few items
-- missed / not written up on their last check day (rule demo_problems = 1).
-- Safe to run more than once.
-- =====================================================================
set search_path = neptsbi, public;
begin;

create table if not exists equipment_types (
  key          text primary key,
  label        text not null,
  check_months smallint not null default 12,
  sort         smallint not null default 0
);
insert into equipment_types (key, label, check_months, sort) values
  ('fire',  'Fire extinguisher', 12, 1),
  ('defib', 'Defib',             12, 2)
on conflict (key) do update set label = excluded.label, check_months = excluded.check_months, sort = excluded.sort;

create table if not exists equipment_items (
  id         int generated always as identity primary key,
  vehicle_id int not null references vehicles(id),
  kind       text not null references equipment_types(key),
  serial     text not null unique,
  position   text,
  active     boolean not null default true,
  demo_seed  boolean not null default false
);
create index if not exists equipment_items_vehicle on equipment_items(vehicle_id);
-- Demo only: missed on its last check day, in the "a few problems" story
alter table equipment_items add column if not exists demo_missed boolean not null default false;

-- One check day a year per base and kind: the nth <weekday> of <month> (weekday 0 = Sunday … 6 = Saturday)
create table if not exists equipment_check_days (
  base_id smallint not null references bases(id),
  kind    text not null references equipment_types(key),
  month   smallint not null check (month between 1 and 12),
  nth     smallint not null check (nth between 1 and 4),
  weekday smallint not null check (weekday between 0 and 6),
  primary key (base_id, kind)
);

-- Results logged on a check day (empty until logging is built)
create table if not exists equipment_checks (
  id          int generated always as identity primary key,
  item_id     int not null references equipment_items(id),
  check_date  date not null,
  result      text not null check (result in ('Pass', 'Fail', 'Replaced')),
  notes       text,
  recorded_at timestamptz not null default now(),
  recorded_by text,
  demo_seed   boolean not null default false
);
create index if not exists equipment_checks_item on equipment_checks(item_id, check_date desc);

-- nth weekday of a month, e.g. the 2nd Saturday of October 2026
create or replace function nth_weekday(p_year int, p_month int, p_nth int, p_weekday int)
returns date language sql immutable as $$
  select (make_date(p_year, p_month, 1)
          + ((p_weekday - extract(dow from make_date(p_year, p_month, 1))::int + 7) % 7)
          + (p_nth - 1) * 7)::date
$$;

-- ---------- Demo data: check days (fire = Saturday, defib = Sunday; a different month per base) ----------
insert into equipment_check_days (base_id, kind, month, nth, weekday)
select b.id, d.kind, d.month, d.nth, d.weekday
from (values
  ('Canvey',     'fire', 10, 2, 6), ('Southend',   'fire',  3, 1, 6), ('Chelmsford', 'fire',  6, 3, 6),
  ('Base X1',    'fire',  2, 2, 6), ('Base X2',    'fire',  8, 1, 6), ('Base Y1',    'fire', 11, 2, 6),
  ('Base Y2',    'fire',  4, 3, 6),
  ('Canvey',     'defib', 5, 2, 0), ('Southend',   'defib', 9, 1, 0), ('Chelmsford', 'defib', 12, 3, 0),
  ('Base X1',    'defib', 4, 2, 0), ('Base X2',    'defib', 7, 4, 0), ('Base Y1',    'defib',  1, 1, 0),
  ('Base Y2',    'defib', 11, 3, 0)
) as d(base, kind, month, nth, weekday)
join bases b on b.name = d.base
on conflict (base_id, kind) do update set month = excluded.month, nth = excluded.nth, weekday = excluded.weekday;

-- The "a few problems" story: on/off switch (0 = all green, 1 = a few missed)
insert into rules (key, value, unit, label, description)
values ('demo_problems', 1, 'on/off', 'Demo: a few equipment checks missed',
        'Demo only – 1 shows a few extinguishers / defibs missed or not written up on their last check day')
on conflict (key) do nothing;

-- ---------- Demo data: the items on each van (only if none yet) ----------
insert into equipment_items (vehicle_id, kind, serial, position, demo_seed)
select v.id, 'defib', 'DF-' || lpad(v.id::text, 5, '0'), 'Saloon', true
from vehicles v
where not exists (select 1 from equipment_items e where e.vehicle_id = v.id and e.kind = 'defib');

insert into equipment_items (vehicle_id, kind, serial, position, demo_seed)
select v.id, 'fire', 'FE-' || lpad(v.id::text, 5, '0') || '-' || p.n, p.position, true
from vehicles v
join vehicle_classes c on c.id = v.class_id
cross join (values (1, 'Cab'), (2, 'Saloon')) as p(n, position)
where (p.n = 1 or c.short in ('HDU', 'BAR'))
  and not exists (select 1 from equipment_items e where e.vehicle_id = v.id and e.kind = 'fire');

-- Which items were "missed" in the problems story (a spread of bases, checks and ages)
update equipment_items set demo_missed = false where demo_missed;
with picks(base, kind, n, second_only) as (values
  ('Canvey',     'fire',  1, true),    -- the 2nd extinguisher on a big van: "1 of 2", runs out end of this month
  ('Canvey',     'fire',  7, false),   -- missed on Saturday: runs out end of this month
  ('Southend',   'fire',  3, false),   -- missed in March: out of date since April
  ('Chelmsford', 'defib', 5, false),   -- not written up in December: out of date since January
  ('Base X1',    'fire',  4, false),   -- missed in February
  ('Base Y2',    'defib', 2, false)    -- not written up last November
), ranked as (
  select e.id, b.name as base, e.kind, e.serial,
         row_number() over (partition by b.name, e.kind, (e.serial like '%-2') order by v.registration) as n,
         (e.serial like '%-2') as is_second
  from equipment_items e join vehicles v on v.id = e.vehicle_id join bases b on b.id = v.base_id
)
update equipment_items e set demo_missed = true
from ranked r join picks p on p.base = r.base and p.kind = r.kind and p.n = r.n and p.second_only = r.is_second
where e.id = r.id;

-- ---------- Position per vehicle and kind (like vehicle_mot / vehicle_service) ----------
drop view if exists vehicle_equipment;   -- columns changed since the first version
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
  select e.vehicle_id, e.kind, e.id,
    coalesce((select max(ch.check_date) from equipment_checks ch
              where ch.item_id = e.id and ch.result in ('Pass', 'Replaced')),
             case when e.demo_missed and coalesce(rule('demo_problems'), 0) = 1 then s.prev_check_day else s.last_check_day end) as last_check,
    (e.demo_missed and coalesce(rule('demo_problems'), 0) = 1) as missed,
    s.last_check_day, s.check_months, s.next_check_day
  from equipment_items e
  join vehicles v on v.id = e.vehicle_id and v.active
  join sched s on s.base_id = v.base_id and s.kind = e.kind
  where e.active
), items2 as (
  -- in date until the end of the month, a year after the check
  select items.*, (date_trunc('month', last_check + make_interval(months => check_months)) + interval '1 month - 1 day')::date as item_due
  from items
), per_vehicle as (
  select vehicle_id, kind,
    count(*)                                                    as items,
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
    when pv.due_date < current_date                                  then 'Overdue'
    when pv.due_date - current_date <= rule('mot_warning_days')      then 'Due soon'
    else 'OK'
  end as status,
  (pv.next_check_day <= pv.due_date) as booked,          -- the base's next check day comes before it runs out
  pv.next_check_day as booking_date,
  false as awaiting_result
from per_vehicle pv;

-- ---------- Access: anyone can read (writes will come through checked functions) ----------
alter table equipment_types      enable row level security;
alter table equipment_items      enable row level security;
alter table equipment_check_days enable row level security;
alter table equipment_checks     enable row level security;
drop policy if exists "Anyone can read" on equipment_types;
drop policy if exists "Anyone can read" on equipment_items;
drop policy if exists "Anyone can read" on equipment_check_days;
drop policy if exists "Anyone can read" on equipment_checks;
create policy "Anyone can read" on equipment_types      for select using (true);
create policy "Anyone can read" on equipment_items      for select using (true);
create policy "Anyone can read" on equipment_check_days for select using (true);
create policy "Anyone can read" on equipment_checks     for select using (true);
grant select on equipment_types, equipment_items, equipment_check_days, equipment_checks, vehicle_equipment to anon, authenticated;
grant execute on function nth_weekday(int, int, int, int) to anon, authenticated;

-- Demo: switch the "a few problems" story on or off (⋮ menu in the app)
create or replace function set_demo_problems(p_on boolean) returns void
language sql security definer set search_path = neptsbi as $$
  update rules set value = case when p_on then 1 else 0 end where key = 'demo_problems';
$$;
revoke execute on function set_demo_problems(boolean) from public;
grant execute on function set_demo_problems(boolean) to anon, authenticated;

commit;
notify pgrst, 'reload schema';
