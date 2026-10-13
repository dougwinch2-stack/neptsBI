-- =====================================================================
-- neptsBI · 03_nightly_reset.sql   (run after 01 and 02)
-- Every night at 2:30am: wipe anything added during demos and move every
-- date forward, so each demo starts from the same story, set to today.
-- (The app also moves the dates forward on the first visit of the day,
--  in case this job ever misses a night.)
-- =====================================================================
create extension if not exists pg_cron;

select cron.schedule(
  'neptsbi-nightly-reset',
  '30 2 * * *',
  $$select neptsbi.reset_demo()$$
);
