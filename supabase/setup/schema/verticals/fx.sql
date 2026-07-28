-- =====================================================================
-- KAREYA SILO — NBC RATE SYNC + FX GAIN/LOSS (fx)
-- ---------------------------------------------------------------------
-- Cambodian businesses invoice in USD and settle tax in KHR, so the riel
-- value of a receivable moves between the day it is invoiced and the day
-- it is paid. That movement is a real gain or loss and has to land
-- somewhere.
--
-- ACCOUNT CODES. The obvious choice, 5200, is already Rent in Kareya's
-- chart — writing FX there would corrupt existing books. So realized and
-- unrealized FX get their own codes, and crucially they are resolved
-- through account_roles rather than hardcoded, because the CIFRS 6-digit
-- chart renumbers everything. A posting asks for "the realized FX
-- account"; the mapping decides which code that is today.
--
-- REALIZED vs UNREALIZED:
--   realized    the invoice was actually settled. The difference between
--               the riel value at issue and at payment is banked.
--   unrealized  the invoice is still open at period end. Its riel value
--               has moved but nothing has been received, so the movement
--               is provisional and revalued again next period.
--
-- Unrealized revaluation posts only the MOVEMENT since the last one, and
-- records the rate it revalued to. Posting the full difference every month
-- would count the same swing repeatedly.
--
-- WHY A SYNC LOG. A rate that silently fails to arrive is worse than no
-- rate at all: invoices keep issuing against a stale figure and nobody
-- notices for weeks. Every attempt is recorded, successful or not.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.nbc_exchange_rates (verticals/gdt-invoice.sql),
--             public.invoices, public.bills, public.chart_of_accounts.
-- =====================================================================

-- ---- account roles ------------------------------------------------------
-- The indirection that makes a chart-of-accounts migration survivable.
-- Code asks for a ROLE; this table says which account currently plays it.
CREATE TABLE IF NOT EXISTS public.account_roles (
  role text NOT NULL,
  account_code text,
  description text,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT account_roles_pkey PRIMARY KEY (role)
);

INSERT INTO public.account_roles (role, account_code, description)
SELECT v.* FROM (VALUES
  ('cash',                 '1000','Cash on hand'),
  ('bank',                 '1010','Bank'),
  ('accounts_receivable',  '1100','Trade receivables'),
  ('inventory',            '1200','Inventory'),
  ('accounts_payable',     '2000','Trade payables'),
  ('tax_payable',          '2100','Tax payable'),
  ('consignment_payable',  '2130','Consignment payable'),
  ('deposits_held',        '2140','Customer deposits held'),
  ('commission_payable',   '2150','Commission payable'),
  ('sales_revenue',        '4000','Sales revenue'),
  ('other_income',         '4100','Other income'),
  ('cogs',                 '5000','Cost of goods sold'),
  ('salaries',             '5100','Salaries and wages'),
  ('commission_expense',   '5150','Commission expense'),
  ('fx_realized',          '5250','Realized exchange gain/loss'),
  ('fx_unrealized',        '5260','Unrealized exchange gain/loss')
) AS v(role, account_code, description)
WHERE NOT EXISTS (SELECT 1 FROM public.account_roles x WHERE x.role = v.role);

/** The account currently playing a role. Postings call this instead of
 *  naming a code, so renumbering the chart is a data change. */
CREATE OR REPLACE FUNCTION public.account_for_role(p_role text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT c.id FROM account_roles r
  JOIN chart_of_accounts c ON c.code = r.account_code
  WHERE r.role = p_role
  LIMIT 1;
$function$;
GRANT EXECUTE ON FUNCTION public.account_for_role(text) TO authenticated;

-- ---- the two FX accounts ------------------------------------------------
-- Guarded on the chart existing, like the other add-on accounts: seeding
-- orphans into an empty chart makes the main seeder skip everything.
INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '5250', 'Realized Exchange Gain/Loss', 'expense', 'other', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '5250');

INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '5260', 'Unrealized Exchange Gain/Loss', 'expense', 'other', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '5260');

-- ---- sync log -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.nbc_sync_log (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  ran_at timestamp with time zone DEFAULT now(),
  status text DEFAULT 'ok'::text,                -- ok | failed | skipped
  rate_date date,
  usd_to_khr numeric,
  source_url text,
  http_status integer,
  message text,
  CONSTRAINT nbc_sync_log_pkey PRIMARY KEY (id),
  CONSTRAINT nbc_sync_log_status_check CHECK (status = ANY (ARRAY['ok','failed','skipped']))
);
CREATE INDEX IF NOT EXISTS idx_nbc_sync_log_ran_at ON public.nbc_sync_log (ran_at DESC);

-- ---- realizations -------------------------------------------------------
-- One row per settlement whose riel value moved. Stored rather than derived
-- so the figure on a filed return cannot change if a rate is later corrected.
CREATE TABLE IF NOT EXISTS public.fx_realizations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  doc_type text NOT NULL,                        -- invoice | bill
  doc_id uuid,
  doc_reference text,
  payment_id uuid,
  currency text DEFAULT 'USD'::text,
  amount_doc numeric DEFAULT 0,                  -- settled amount, document currency
  rate_at_issue numeric,
  rate_at_settlement numeric,
  khr_at_issue numeric,
  khr_at_settlement numeric,
  gain_loss_khr numeric DEFAULT 0,               -- positive = gain, negative = loss
  date date DEFAULT CURRENT_DATE,
  posted boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fx_realizations_pkey PRIMARY KEY (id),
  CONSTRAINT fx_realizations_doc_type_check CHECK (doc_type = ANY (ARRAY['invoice','bill'])),
  CONSTRAINT fx_realizations_rates_check CHECK (
    (rate_at_issue IS NULL OR rate_at_issue > 0) AND (rate_at_settlement IS NULL OR rate_at_settlement > 0))
);
-- One realization per payment. Recording it twice would double the gain.
CREATE UNIQUE INDEX IF NOT EXISTS uq_fx_realization_payment
  ON public.fx_realizations (payment_id) WHERE payment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fx_realizations_date ON public.fx_realizations (date);
CREATE INDEX IF NOT EXISTS idx_fx_realizations_doc ON public.fx_realizations (doc_type, doc_id);

-- ---- unrealized revaluation --------------------------------------------
-- What an open document was last revalued to, so the next run posts only
-- the movement rather than the whole swing again.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS last_revalued_rate numeric;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS last_revalued_at date;

CREATE TABLE IF NOT EXISTS public.fx_revaluations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  period text NOT NULL,                          -- YYYY-MM
  as_of_date date NOT NULL,
  rate_used numeric NOT NULL,
  documents_revalued integer DEFAULT 0,
  movement_khr numeric DEFAULT 0,                -- since the previous revaluation
  posted boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fx_revaluations_pkey PRIMARY KEY (id),
  CONSTRAINT fx_revaluations_period_check CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),
  CONSTRAINT fx_revaluations_rate_check CHECK (rate_used > 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_fx_revaluation_period ON public.fx_revaluations (period);

/** Revalue every open, issued, non-voided invoice to the rate on a date,
 *  returning the movement since each one was last revalued. Only the
 *  movement is reported — revaluing the full difference every month would
 *  book the same swing over and over. */
DROP FUNCTION IF EXISTS public.revalue_open_fx(date);
CREATE OR REPLACE FUNCTION public.revalue_open_fx(p_as_of date)
 RETURNS TABLE (out_documents integer, out_movement_khr numeric, out_rate numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rate  numeric;
  v_count integer := 0;
  v_move  numeric := 0;
  v_period text;
BEGIN
  v_rate := nbc_rate_on(p_as_of);
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'No official NBC rate on or before % — cannot revalue', p_as_of;
  END IF;
  v_period := to_char(p_as_of, 'YYYY-MM');

  -- Movement is measured against whatever each document was last revalued
  -- to, falling back to the rate frozen at issue for one never revalued.
  SELECT COUNT(*), COALESCE(SUM(amount * (v_rate - COALESCE(last_revalued_rate, nbc_rate))), 0)
    INTO v_count, v_move
    FROM invoices
   WHERE COALESCE(issued, false) = true
     AND COALESCE(voided, false) = false
     AND status <> 'paid'
     AND nbc_rate IS NOT NULL
     AND date <= p_as_of;

  UPDATE invoices
     SET last_revalued_rate = v_rate, last_revalued_at = p_as_of
   WHERE COALESCE(issued, false) = true
     AND COALESCE(voided, false) = false
     AND status <> 'paid'
     AND nbc_rate IS NOT NULL
     AND date <= p_as_of;

  INSERT INTO fx_revaluations (period, as_of_date, rate_used, documents_revalued, movement_khr)
  VALUES (v_period, p_as_of, v_rate, v_count, ROUND(v_move, 0))
  ON CONFLICT (period) DO UPDATE SET
    as_of_date = EXCLUDED.as_of_date,
    rate_used = EXCLUDED.rate_used,
    documents_revalued = EXCLUDED.documents_revalued,
    movement_khr = fx_revaluations.movement_khr + EXCLUDED.movement_khr;

  RETURN QUERY SELECT v_count, ROUND(v_move, 0), v_rate;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.revalue_open_fx(date) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.account_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nbc_sync_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fx_realizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fx_revaluations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View account roles" ON public.account_roles;
DROP POLICY IF EXISTS "Manage account roles" ON public.account_roles;
CREATE POLICY "View account roles" ON public.account_roles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage account roles" ON public.account_roles FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View nbc sync log" ON public.nbc_sync_log;
DROP POLICY IF EXISTS "Manage nbc sync log" ON public.nbc_sync_log;
CREATE POLICY "View nbc sync log" ON public.nbc_sync_log FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage nbc sync log" ON public.nbc_sync_log FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View fx realizations" ON public.fx_realizations;
DROP POLICY IF EXISTS "Manage fx realizations" ON public.fx_realizations;
CREATE POLICY "View fx realizations" ON public.fx_realizations FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage fx realizations" ON public.fx_realizations FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View fx revaluations" ON public.fx_revaluations;
DROP POLICY IF EXISTS "Manage fx revaluations" ON public.fx_revaluations;
CREATE POLICY "View fx revaluations" ON public.fx_revaluations FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage fx revaluations" ON public.fx_revaluations FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
