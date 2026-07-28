-- =====================================================================
-- KAREYA SILO — ANNUAL TAX ON INCOME (TOI) & TAX DEPRECIATION (toi)
-- ---------------------------------------------------------------------
-- The annual GDT return is not the profit-and-loss account. It starts
-- from accounting profit and then adjusts it:
--
--   accounting profit
--   + book depreciation           (removed — it is not the tax figure)
--   - tax depreciation            (the GDT allowance, by asset class)
--   + non-deductible expenses     (added back)
--   = taxable income
--   x tax on income rate
--   - monthly 1% prepayments already made
--   = balance to pay
--
-- Two design rules make this safe to run against a live book:
--
-- 1. TAX DEPRECIATION NEVER POSTS TO THE LEDGER. It is a parallel
--    calculation kept in its own table. Book depreciation stays exactly
--    as it is, because the accounts must show the accountant's view and
--    the return must show the GDT's, and they are different on purpose.
--    A system that posted both would double-count; one that posted only
--    the tax figure would falsify the financial statements.
--
-- 2. NOTHING IS AUTO-DISALLOWED. An expense is deductible until a human
--    marks it otherwise. The system SUGGESTS candidates (a bill with no
--    supplier VATTIN, entertainment) and a person decides. Silently
--    disallowing somebody's cost is how a return ends up overstating
--    tax with nobody able to explain why.
--
-- RATES AND CLASSES ARE CONFIGURABLE. The four classes below are seeded
-- with the rates this deployment asked for. VERIFY THEM against the
-- current Law on Taxation and Prakas before filing — published figures
-- for Article 13 that were available when this was written differ
-- (buildings 5% straight line; computers and software 50% declining;
-- vehicles and office furniture 25% declining; other property 20%
-- declining). Whichever is right, edit the rate in
-- Accounting -> Annual Return; nothing here hardcodes it.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.assets, public.bills, public.expense_claims,
--             public.journal_entries, public.journal_lines,
--             public.chart_of_accounts, public.tax_config,
--             public.tax_returns, public.has_any_role(text[]).
-- =====================================================================

-- ---- configuration ------------------------------------------------------
ALTER TABLE public.tax_config ADD COLUMN IF NOT EXISTS toi_rate numeric DEFAULT 20;
ALTER TABLE public.tax_config ADD COLUMN IF NOT EXISTS subject_to_minimum_tax boolean DEFAULT false;
ALTER TABLE public.tax_config ADD COLUMN IF NOT EXISTS minimum_tax_rate numeric DEFAULT 1;
-- A declining balance never reaches zero: 25% of something is always
-- something. Without a rule, a laptop bought in 2020 is still carrying a
-- written-down value in 2060. So below this figure the remainder is
-- allowed in full and the asset closes. It is a threshold in your books'
-- currency, so check it if you keep them in riel.
ALTER TABLE public.tax_config ADD COLUMN IF NOT EXISTS dep_writeoff_threshold numeric DEFAULT 100;

COMMENT ON COLUMN public.tax_config.subject_to_minimum_tax IS
  'Minimum tax of 1% of turnover applies to taxpayers without properly maintained accounting records. Leave off if your records qualify; your accountant decides, not the software.';

-- ---- GDT tax depreciation classes ---------------------------------------
CREATE TABLE IF NOT EXISTS public.tax_asset_classes (
  class_no integer NOT NULL,
  name text NOT NULL,
  name_kh text,
  rate numeric NOT NULL,                         -- percent per year
  method text NOT NULL,                          -- straight_line | declining_balance
  description text,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tax_asset_classes_pkey PRIMARY KEY (class_no),
  CONSTRAINT tax_asset_classes_no_check CHECK (class_no BETWEEN 1 AND 4),
  CONSTRAINT tax_asset_classes_rate_check CHECK (rate > 0 AND rate <= 100),
  CONSTRAINT tax_asset_classes_method_check CHECK (method = ANY (ARRAY['straight_line','declining_balance']))
);

INSERT INTO public.tax_asset_classes (class_no, name, name_kh, rate, method, description)
SELECT v.* FROM (VALUES
  (1,'Buildings and structural improvements','អគារ និងសំណង់',20,'straight_line',
     'Buildings, structures and improvements to them'),
  (2,'Computers, electronic equipment and software','កុំព្យូទ័រ និងសូហ្វវែរ',25,'declining_balance',
     'Computers, electronic information systems, data handling equipment and software'),
  (3,'Automobiles, trucks and office furniture','យានយន្ត និងសម្ភារៈការិយាល័យ',20,'declining_balance',
     'Automobiles, trucks and office furniture and equipment'),
  (4,'All other tangible property','ទ្រព្យរូបីផ្សេងទៀត',15,'declining_balance',
     'Every other item of tangible property used in the business')
) AS v(class_no, name, name_kh, rate, method, description)
WHERE NOT EXISTS (SELECT 1 FROM public.tax_asset_classes x WHERE x.class_no = v.class_no);

-- ---- assets gain a tax class -------------------------------------------
-- tax_basis is separate from price: what an asset cost the business and
-- what the GDT accepts as its depreciable base are not always the same
-- figure, and overwriting one with the other loses the difference.
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS tax_class integer;
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS tax_basis numeric;
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS tax_depreciation_start date;

DO $c$ BEGIN
  ALTER TABLE public.assets ADD CONSTRAINT assets_tax_class_fkey
    FOREIGN KEY (tax_class) REFERENCES public.tax_asset_classes(class_no) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.assets ADD CONSTRAINT assets_tax_basis_check CHECK (tax_basis IS NULL OR tax_basis >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_assets_tax_class ON public.assets (tax_class);

-- ---- the tax depreciation register -------------------------------------
-- One row per asset per fiscal year. Deliberately NOT posted to the
-- ledger: see rule 1 at the top of this file.
CREATE TABLE IF NOT EXISTS public.tax_depreciation_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  asset_id uuid NOT NULL,
  fiscal_year integer NOT NULL,
  class_no integer,
  method text,
  rate numeric,
  opening_basis numeric DEFAULT 0 NOT NULL,      -- written-down value at year start
  amount numeric DEFAULT 0 NOT NULL,             -- the year's allowance
  closing_basis numeric DEFAULT 0 NOT NULL,
  computed_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tax_depreciation_entries_pkey PRIMARY KEY (id),
  CONSTRAINT tax_depreciation_entries_asset_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE,
  CONSTRAINT tax_depreciation_entries_class_fkey FOREIGN KEY (class_no) REFERENCES public.tax_asset_classes(class_no) ON DELETE SET NULL,
  CONSTRAINT tax_depreciation_entries_year_check CHECK (fiscal_year BETWEEN 2000 AND 2200),
  CONSTRAINT tax_depreciation_entries_amount_check CHECK (amount >= 0 AND opening_basis >= 0 AND closing_basis >= 0)
);

-- An asset cannot be depreciated twice in the same year: that is a
-- doubled allowance and an understated tax bill.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tax_depreciation_asset_year
  ON public.tax_depreciation_entries (asset_id, fiscal_year);
CREATE INDEX IF NOT EXISTS idx_tax_depreciation_year ON public.tax_depreciation_entries (fiscal_year);

-- ---- non-deductible expense tagging ------------------------------------
-- Distinct from input_vat_deductible, which answers a different question:
-- VAT you cannot reclaim is still usually a deductible cost for tax on
-- income. Conflating them gets one of the two returns wrong.
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS toi_deductible boolean DEFAULT true;
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS toi_addback_reason text;
ALTER TABLE public.expense_claims ADD COLUMN IF NOT EXISTS toi_deductible boolean DEFAULT true;
ALTER TABLE public.expense_claims ADD COLUMN IF NOT EXISTS toi_addback_reason text;

CREATE TABLE IF NOT EXISTS public.toi_addback_reasons (
  code text NOT NULL,
  label text NOT NULL,
  label_kh text,
  guidance text,
  is_standard boolean DEFAULT true,
  CONSTRAINT toi_addback_reasons_pkey PRIMARY KEY (code)
);

INSERT INTO public.toi_addback_reasons (code, label, label_kh, guidance)
SELECT v.* FROM (VALUES
  ('entertainment','Entertainment and amusement','ការកម្សាន្ត',
    'Entertainment, amusement and recreation costs are not deductible, and the input VAT on them is not claimable either.'),
  ('personal','Personal expense','ចំណាយផ្ទាល់ខ្លួន',
    'A cost of the owner or of staff personally, paid through the business.'),
  ('no_vattin','Receipt without a VATTIN','វិក្កយបត្រគ្មានលេខអតប',
    'An unverified receipt: no supplier tax identification number, so the expense cannot be substantiated.'),
  ('excessive','Above the allowed limit','លើសកម្រិតកំណត់',
    'The part of a cost that exceeds what the GDT permits. Split the bill and add back only the excess.'),
  ('donation','Donation or gift','អំណោយ',
    'Charitable and other gifts, except those specifically allowed.'),
  ('fine_penalty','Fine or penalty','ការពិន័យ',
    'Fines, penalties and late-payment charges imposed by an authority.'),
  ('provision','Unrealised provision or reserve','សំវិធានធន',
    'A provision for a cost not yet incurred is not deductible until it is.'),
  ('other','Other non-deductible','ផ្សេងៗ',
    'Anything else your accountant disallows. Say why in the note.')
) AS v(code, label, label_kh, guidance)
WHERE NOT EXISTS (SELECT 1 FROM public.toi_addback_reasons x WHERE x.code = v.code);

DO $c$ BEGIN
  ALTER TABLE public.bills ADD CONSTRAINT bills_toi_addback_fkey
    FOREIGN KEY (toi_addback_reason) REFERENCES public.toi_addback_reasons(code) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.expense_claims ADD CONSTRAINT expense_claims_toi_addback_fkey
    FOREIGN KEY (toi_addback_reason) REFERENCES public.toi_addback_reasons(code) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- A disallowed cost with no stated reason cannot be defended in an audit,
-- so the reason is required the moment deductibility is switched off.
DO $c$ BEGIN
  ALTER TABLE public.bills ADD CONSTRAINT bills_toi_reason_check
    CHECK (toi_deductible OR toi_addback_reason IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.expense_claims ADD CONSTRAINT expense_claims_toi_reason_check
    CHECK (toi_deductible OR toi_addback_reason IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_bills_toi_deductible ON public.bills (toi_deductible) WHERE toi_deductible = false;
CREATE INDEX IF NOT EXISTS idx_expense_claims_toi_deductible ON public.expense_claims (toi_deductible) WHERE toi_deductible = false;

-- ---- the annual return --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.annual_tax_returns (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  fiscal_year integer NOT NULL,
  status text DEFAULT 'draft' NOT NULL,
  period_start date,
  period_end date,

  turnover numeric DEFAULT 0,                    -- gross, for the minimum-tax test
  accounting_profit numeric DEFAULT 0,

  book_depreciation numeric DEFAULT 0,           -- added back
  tax_depreciation numeric DEFAULT 0,            -- allowed instead
  non_deductible_expenses numeric DEFAULT 0,     -- added back
  other_adjustments numeric DEFAULT 0,           -- entered by hand, may be negative

  taxable_income numeric DEFAULT 0,
  toi_rate numeric DEFAULT 20,
  toi_due numeric DEFAULT 0,
  minimum_tax numeric DEFAULT 0,
  tax_before_credits numeric DEFAULT 0,          -- the greater of the two, when minimum tax applies
  prepayments_made numeric DEFAULT 0,            -- monthly 1% already paid
  balance_payable numeric DEFAULT 0,             -- negative = credit

  generated_at timestamp with time zone,
  filed_at timestamp with time zone,
  filed_by uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT annual_tax_returns_pkey PRIMARY KEY (id),
  CONSTRAINT annual_tax_returns_filed_by_fkey FOREIGN KEY (filed_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT annual_tax_returns_status_check CHECK (status = ANY (ARRAY['draft','generated','filed'])),
  CONSTRAINT annual_tax_returns_year_check CHECK (fiscal_year BETWEEN 2000 AND 2200)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_annual_tax_returns_year
  ON public.annual_tax_returns (fiscal_year);

-- A filed return is a document lodged with the GDT. Editing it in place
-- would leave the books disagreeing with what was filed and no trace of
-- the change. Reopen deliberately, or not at all.
CREATE OR REPLACE FUNCTION public.protect_filed_annual_return()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'filed' THEN
      RAISE EXCEPTION 'Annual return % has been filed and cannot be deleted. Reopen it first.', OLD.fiscal_year;
    END IF;
    RETURN OLD;
  END IF;
  -- Everything is frozen while filed except the act of reopening it and
  -- notes recording why.
  IF OLD.status = 'filed' AND NEW.status = 'filed'
     AND (NEW.taxable_income IS DISTINCT FROM OLD.taxable_income
       OR NEW.toi_due IS DISTINCT FROM OLD.toi_due
       OR NEW.accounting_profit IS DISTINCT FROM OLD.accounting_profit
       OR NEW.tax_depreciation IS DISTINCT FROM OLD.tax_depreciation
       OR NEW.non_deductible_expenses IS DISTINCT FROM OLD.non_deductible_expenses
       OR NEW.other_adjustments IS DISTINCT FROM OLD.other_adjustments
       OR NEW.balance_payable IS DISTINCT FROM OLD.balance_payable) THEN
    RAISE EXCEPTION 'Annual return % has been filed. Reopen it before changing its figures.', OLD.fiscal_year;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_filed_annual_return ON public.annual_tax_returns;
CREATE TRIGGER trg_protect_filed_annual_return
  BEFORE UPDATE OR DELETE ON public.annual_tax_returns
  FOR EACH ROW EXECUTE FUNCTION public.protect_filed_annual_return();

-- ---- fiscal year helper -------------------------------------------------
/** The fiscal year need not be the calendar year. Everything that reports
 *  annually must agree on where it starts, so it is derived here once. */
DROP FUNCTION IF EXISTS public.fiscal_year_range(integer);
CREATE OR REPLACE FUNCTION public.fiscal_year_range(p_year integer)
 RETURNS TABLE (out_start date, out_end date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT s, (s + interval '1 year' - interval '1 day')::date
  FROM (SELECT make_date(p_year, COALESCE((SELECT fiscal_year_start_month FROM tax_config WHERE id), 1), 1) AS s) q;
$function$;
GRANT EXECUTE ON FUNCTION public.fiscal_year_range(integer) TO authenticated;

-- ---- tax depreciation computation ---------------------------------------
/** Compute the GDT allowance for every classified asset for one fiscal
 *  year, and write it to the register. Recomputing a year replaces that
 *  year's figures — which is why the unique index exists, and why the
 *  written-down value is derived from the years BEFORE this one rather
 *  than from a running total that a recompute would corrupt.
 *
 *  An asset earns a full year's allowance in the year it enters service
 *  and none before it. That is the simple reading; if your accountant
 *  prorates, override the amount on the entry. */
DROP FUNCTION IF EXISTS public.compute_tax_depreciation(integer);
CREATE OR REPLACE FUNCTION public.compute_tax_depreciation(p_fiscal_year integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_start date;
  v_end date;
  v_count integer := 0;
  r record;
  v_basis numeric;
  v_prior numeric;
  v_open numeric;
  v_amount numeric;
  v_floor numeric;
BEGIN
  SELECT out_start, out_end INTO v_start, v_end FROM fiscal_year_range(p_fiscal_year);
  SELECT COALESCE(dep_writeoff_threshold, 100) INTO v_floor FROM tax_config WHERE id;
  v_floor := GREATEST(COALESCE(v_floor, 100), 0);

  FOR r IN
    SELECT a.id, a.price, a.tax_basis, a.tax_class,
           COALESCE(a.tax_depreciation_start, a.depreciation_start, a.purchase_date) AS in_service,
           c.rate, c.method
      FROM assets a
      JOIN tax_asset_classes c ON c.class_no = a.tax_class
     WHERE a.tax_class IS NOT NULL
  LOOP
    -- Not yet in service by the end of this year: no allowance at all.
    IF r.in_service IS NULL OR r.in_service > v_end THEN
      DELETE FROM tax_depreciation_entries WHERE asset_id = r.id AND fiscal_year = p_fiscal_year;
      CONTINUE;
    END IF;

    v_basis := COALESCE(NULLIF(r.tax_basis, 0), r.price, 0);
    IF v_basis <= 0 THEN CONTINUE; END IF;

    -- Written-down value carried in from earlier years only. A recompute
    -- of this year must not read its own previous result.
    SELECT COALESCE(SUM(amount), 0) INTO v_prior
      FROM tax_depreciation_entries
     WHERE asset_id = r.id AND fiscal_year < p_fiscal_year;

    v_open := GREATEST(v_basis - v_prior, 0);
    IF v_open <= 0.005 THEN
      DELETE FROM tax_depreciation_entries WHERE asset_id = r.id AND fiscal_year = p_fiscal_year;
      CONTINUE;
    END IF;

    IF r.method = 'straight_line' THEN
      v_amount := v_basis * r.rate / 100.0;
    ELSE
      v_amount := v_open * r.rate / 100.0;
    END IF;

    -- Never write an asset below zero, and close out a tail small enough
    -- that declining balance would otherwise chase it for decades.
    v_amount := LEAST(ROUND(v_amount, 2), v_open);
    IF v_open <= v_floor OR v_open - v_amount <= 0.005 THEN v_amount := v_open; END IF;

    INSERT INTO tax_depreciation_entries
      (asset_id, fiscal_year, class_no, method, rate, opening_basis, amount, closing_basis)
    VALUES
      (r.id, p_fiscal_year, r.tax_class, r.method, r.rate, ROUND(v_open, 2), v_amount, ROUND(v_open - v_amount, 2))
    ON CONFLICT (asset_id, fiscal_year) DO UPDATE
      SET class_no = EXCLUDED.class_no, method = EXCLUDED.method, rate = EXCLUDED.rate,
          opening_basis = EXCLUDED.opening_basis, amount = EXCLUDED.amount,
          closing_basis = EXCLUDED.closing_basis, computed_at = now();
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.compute_tax_depreciation(integer) TO authenticated;

-- ---- suggested add-backs ------------------------------------------------
/** Costs that LOOK non-deductible, for a person to confirm. Nothing here
 *  changes a record; it is a worklist, not a decision. */
DROP FUNCTION IF EXISTS public.suggested_addbacks(integer);
CREATE OR REPLACE FUNCTION public.suggested_addbacks(p_fiscal_year integer)
 RETURNS TABLE (
   out_kind text, out_id uuid, out_date date, out_label text,
   out_amount numeric, out_reason_code text, out_why text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH fy AS (SELECT out_start AS s, out_end AS e FROM fiscal_year_range(p_fiscal_year))
  SELECT 'bill', b.id, b.date,
         COALESCE(v.name, 'Supplier') || COALESCE(' · ' || b.bill_number, ''),
         b.amount, 'no_vattin',
         'No supplier VATTIN on this bill, so the expense is unverified'
    FROM bills b
    LEFT JOIN vendors v ON v.id = b.vendor_id
    CROSS JOIN fy
   WHERE b.date BETWEEN fy.s AND fy.e
     AND b.toi_deductible IS DISTINCT FROM false
     AND COALESCE(NULLIF(btrim(b.supplier_vattin), ''), NULL) IS NULL
  UNION ALL
  SELECT 'bill', b.id, b.date,
         COALESCE(v.name, 'Supplier') || COALESCE(' · ' || b.bill_number, ''),
         b.amount, 'entertainment',
         'Already marked as entertainment for VAT purposes'
    FROM bills b
    LEFT JOIN vendors v ON v.id = b.vendor_id
    CROSS JOIN fy
   WHERE b.date BETWEEN fy.s AND fy.e
     AND b.toi_deductible IS DISTINCT FROM false
     AND b.input_vat_deductible = false
     AND b.non_deductible_reason ILIKE '%entertain%'
  UNION ALL
  SELECT 'expense_claim', c.id, c.date,
         COALESCE(e.name, 'Staff') || ' · ' || COALESCE(c.title, c.category, 'claim'),
         c.amount, 'no_vattin',
         'Expense claim with no receipt attached'
    FROM expense_claims c
    LEFT JOIN employees e ON e.id = c.employee_id
    CROSS JOIN fy
   WHERE c.date BETWEEN fy.s AND fy.e
     AND c.toi_deductible IS DISTINCT FROM false
     AND COALESCE(NULLIF(btrim(c.receipt_url), ''), NULL) IS NULL
  ORDER BY 3 DESC;
$function$;
GRANT EXECUTE ON FUNCTION public.suggested_addbacks(integer) TO authenticated;

-- ---- the annual reconciliation -----------------------------------------
/** Build the year's return from the ledger. Computed in the database so
 *  that no two screens can disagree about what a year owes.
 *
 *  Accounting profit comes from the journal, not from the invoice list:
 *  the journal is the record, and anything posted by hand belongs in the
 *  profit too. */
DROP FUNCTION IF EXISTS public.generate_annual_tax_return(integer);
CREATE OR REPLACE FUNCTION public.generate_annual_tax_return(p_fiscal_year integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_start date;
  v_end date;
  v_cfg record;
  v_income numeric := 0;
  v_expense numeric := 0;
  v_profit numeric := 0;
  v_book_dep numeric := 0;
  v_tax_dep numeric := 0;
  v_nondeduct numeric := 0;
  v_turnover numeric := 0;
  v_prepaid numeric := 0;
  v_other numeric := 0;
  v_taxable numeric := 0;
  v_toi numeric := 0;
  v_min numeric := 0;
  v_before numeric := 0;
  v_id uuid;
  v_status text;
BEGIN
  SELECT out_start, out_end INTO v_start, v_end FROM fiscal_year_range(p_fiscal_year);
  SELECT * INTO v_cfg FROM tax_config WHERE id;

  SELECT status, other_adjustments INTO v_status, v_other
    FROM annual_tax_returns WHERE fiscal_year = p_fiscal_year;
  IF v_status = 'filed' THEN
    RAISE EXCEPTION 'Annual return % has been filed. Reopen it before regenerating.', p_fiscal_year;
  END IF;
  v_other := COALESCE(v_other, 0);

  -- profit from the journal
  SELECT COALESCE(SUM(l.credit - l.debit), 0) INTO v_income
    FROM journal_lines l
    JOIN journal_entries e ON e.id = l.entry_id
    JOIN chart_of_accounts c ON c.id = l.account_id
   WHERE e.date BETWEEN v_start AND v_end AND c.type = 'income';

  SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_expense
    FROM journal_lines l
    JOIN journal_entries e ON e.id = l.entry_id
    JOIN chart_of_accounts c ON c.id = l.account_id
   WHERE e.date BETWEEN v_start AND v_end AND c.type = 'expense';

  v_profit := ROUND(v_income - v_expense, 2);
  v_turnover := ROUND(v_income, 2);

  -- book depreciation, added back because the tax figure replaces it
  SELECT COALESCE(SUM(amount), 0) INTO v_book_dep
    FROM depreciation_entries WHERE period BETWEEN v_start AND v_end;

  SELECT COALESCE(SUM(amount), 0) INTO v_tax_dep
    FROM tax_depreciation_entries WHERE fiscal_year = p_fiscal_year;

  -- disallowed costs, added back
  SELECT COALESCE(SUM(amount), 0) INTO v_nondeduct FROM (
    SELECT b.amount FROM bills b
     WHERE b.date BETWEEN v_start AND v_end AND b.toi_deductible = false
    UNION ALL
    SELECT c.amount FROM expense_claims c
     WHERE c.date BETWEEN v_start AND v_end AND c.toi_deductible = false
       AND c.status <> 'rejected'
  ) q(amount);

  -- monthly 1% prepayments already made against this year
  SELECT COALESCE(SUM(toi_prepayment), 0) INTO v_prepaid
    FROM tax_returns
   WHERE to_date(period || '-01', 'YYYY-MM-DD') BETWEEN v_start AND v_end;

  v_taxable := ROUND(v_profit + v_book_dep - v_tax_dep + v_nondeduct + v_other, 2);
  v_toi := ROUND(GREATEST(v_taxable, 0) * COALESCE(v_cfg.toi_rate, 20) / 100.0, 2);
  v_min := ROUND(GREATEST(v_turnover, 0) * COALESCE(v_cfg.minimum_tax_rate, 1) / 100.0, 2);
  v_before := CASE WHEN COALESCE(v_cfg.subject_to_minimum_tax, false)
                   THEN GREATEST(v_toi, v_min) ELSE v_toi END;

  INSERT INTO annual_tax_returns (
    fiscal_year, status, period_start, period_end, turnover, accounting_profit,
    book_depreciation, tax_depreciation, non_deductible_expenses, other_adjustments,
    taxable_income, toi_rate, toi_due, minimum_tax, tax_before_credits,
    prepayments_made, balance_payable, generated_at
  ) VALUES (
    p_fiscal_year, 'generated', v_start, v_end, v_turnover, v_profit,
    ROUND(v_book_dep, 2), ROUND(v_tax_dep, 2), ROUND(v_nondeduct, 2), v_other,
    v_taxable, COALESCE(v_cfg.toi_rate, 20), v_toi, v_min, v_before,
    ROUND(v_prepaid, 2), ROUND(v_before - v_prepaid, 2), now()
  )
  ON CONFLICT (fiscal_year) DO UPDATE SET
    status = 'generated', period_start = EXCLUDED.period_start, period_end = EXCLUDED.period_end,
    turnover = EXCLUDED.turnover, accounting_profit = EXCLUDED.accounting_profit,
    book_depreciation = EXCLUDED.book_depreciation, tax_depreciation = EXCLUDED.tax_depreciation,
    non_deductible_expenses = EXCLUDED.non_deductible_expenses,
    taxable_income = EXCLUDED.taxable_income, toi_rate = EXCLUDED.toi_rate,
    toi_due = EXCLUDED.toi_due, minimum_tax = EXCLUDED.minimum_tax,
    tax_before_credits = EXCLUDED.tax_before_credits,
    prepayments_made = EXCLUDED.prepayments_made, balance_payable = EXCLUDED.balance_payable,
    generated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.generate_annual_tax_return(integer) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.tax_asset_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_depreciation_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.toi_addback_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.annual_tax_returns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View tax asset classes" ON public.tax_asset_classes;
DROP POLICY IF EXISTS "Manage tax asset classes" ON public.tax_asset_classes;
CREATE POLICY "View tax asset classes" ON public.tax_asset_classes FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tax asset classes" ON public.tax_asset_classes FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View toi addback reasons" ON public.toi_addback_reasons;
DROP POLICY IF EXISTS "Manage toi addback reasons" ON public.toi_addback_reasons;
CREATE POLICY "View toi addback reasons" ON public.toi_addback_reasons FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage toi addback reasons" ON public.toi_addback_reasons FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View tax depreciation" ON public.tax_depreciation_entries;
DROP POLICY IF EXISTS "Manage tax depreciation" ON public.tax_depreciation_entries;
CREATE POLICY "View tax depreciation" ON public.tax_depreciation_entries FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage tax depreciation" ON public.tax_depreciation_entries FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View annual tax returns" ON public.annual_tax_returns;
DROP POLICY IF EXISTS "Manage annual tax returns" ON public.annual_tax_returns;
CREATE POLICY "View annual tax returns" ON public.annual_tax_returns FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage annual tax returns" ON public.annual_tax_returns FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
