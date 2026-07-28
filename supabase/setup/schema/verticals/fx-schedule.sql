-- =====================================================================
-- KAREYA SILO — NBC RATE SYNC SCHEDULE (optional)
-- ---------------------------------------------------------------------
-- Runs nbc-rate-sync at 10:30 Phnom Penh time on weekdays. Phnom Penh is
-- UTC+7 and does not observe daylight saving, so that is 03:30 UTC all
-- year — no seasonal drift to correct for.
--
-- OPTIONAL. It needs pg_cron and pg_net, which are available on Supabase
-- but not on every self-hosted stack, so the whole thing is guarded: if
-- the extensions are missing the file still applies and you enter rates
-- by hand instead. Nothing else depends on this running.
--
-- Set the two settings below to your project before running:
--   ALTER DATABASE postgres SET app.settings.functions_url = 'https://<ref>.supabase.co/functions/v1';
--   ALTER DATABASE postgres SET app.settings.service_role_key = '<service-role-key>';
-- =====================================================================

DO $sched$
DECLARE
  v_url text;
  v_key text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron')
     OR NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net') THEN
    RAISE NOTICE 'pg_cron/pg_net unavailable — skipping the NBC sync schedule. Enter rates manually in Accounting -> Tax Invoice (GDT).';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;
  CREATE EXTENSION IF NOT EXISTS pg_net;

  v_url := current_setting('app.settings.functions_url', true);
  v_key := current_setting('app.settings.service_role_key', true);
  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE NOTICE 'app.settings.functions_url / service_role_key are not set — skipping the schedule.';
    RETURN;
  END IF;

  PERFORM cron.unschedule('nbc-rate-sync') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'nbc-rate-sync');

  -- 03:30 UTC = 10:30 Phnom Penh, Monday to Friday.
  PERFORM cron.schedule('nbc-rate-sync', '30 3 * * 1-5', format(
    $job$ SELECT net.http_post(
      url := %L,
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || %L),
      body := '{}'::jsonb
    ) $job$, v_url || '/nbc-rate-sync', v_key));

  RAISE NOTICE 'NBC rate sync scheduled for 03:30 UTC (10:30 Phnom Penh), weekdays.';
END $sched$;
