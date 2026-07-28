-- =====================================================================
-- KAREYA — DEMO RESET
-- ---------------------------------------------------------------------
-- Empties the workspace so you can test the same flow again from a clean
-- slate. Wipes ALL business data: master records (clients, stock, menus,
-- rooms…) and every transaction (invoices, journals, sales, bookings…).
--
-- WHAT SURVIVES, and why:
--   employees, departments  — so you do not lock yourself out of your own
--                             Silo the moment the script finishes.
--   workspace_config        — keeps your modules switched on and skips a
--                             second trip through onboarding.
--   *_config singletons     — AI keys, payment/e-sign/e-invoice settings.
--                             These hold credentials you do not want to
--                             re-enter, and no test depends on clearing them.
--   library_policy          — loan period, fine rate and limits are settings
--                             the librarian tuned, not test data.
--
-- The table list is derived from the live schema rather than hard-coded, so
-- tables added by future verticals are cleared too instead of quietly
-- surviving a "reset". Only the short PRESERVE list below is hand-managed.
--
-- HOW TO RUN
--   1. Supabase Studio -> SQL Editor -> run this whole file.
--   2. Re-run demo-seed.sql to get the master data back.
--   3. Accounting -> Accounts -> "Install Standard Accounts" (the chart of
--      accounts is data, so it is cleared too — re-install it or nothing
--      will post to the ledger).
--
-- THIS IS DESTRUCTIVE AND CANNOT BE UNDONE. Never run it against a Silo
-- that holds real business records.
-- =====================================================================

DO $reset$
DECLARE
  -- Everything NOT in this list gets truncated.
  v_preserve text[] := ARRAY[
    'employees', 'departments', 'workspace_config',
    'ai_config', 'payment_config', 'esign_config', 'einvoice_config', 'connect_config',
    'library_policy'
  ];
  v_tables text;
  v_count  int;
BEGIN
  SELECT string_agg(format('public.%I', tablename), ', '), count(*)
    INTO v_tables, v_count
  FROM pg_tables
  WHERE schemaname = 'public'
    AND NOT (tablename = ANY (v_preserve));

  IF v_tables IS NULL THEN
    RAISE NOTICE 'Nothing to reset.';
    RETURN;
  END IF;

  -- One statement: TRUNCATE resolves foreign keys itself, so no ordering
  -- to get wrong. CASCADE only ever reaches tables in this same set,
  -- because nothing on the preserve list is referenced by a cleared table.
  EXECUTE 'TRUNCATE TABLE ' || v_tables || ' RESTART IDENTITY CASCADE';

  RAISE NOTICE 'Reset complete: % tables cleared, % preserved.', v_count, array_length(v_preserve, 1);
END $reset$;

-- ---------------------------------------------------------------------
-- Next: run demo-seed.sql, then Accounting -> Accounts ->
-- "Install Standard Accounts".
-- ---------------------------------------------------------------------
