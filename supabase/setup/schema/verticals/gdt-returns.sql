-- =====================================================================
-- KAREYA SILO — CAMBODIA GDT MONTHLY TAX RETURN (gdt-returns)
-- ---------------------------------------------------------------------
-- របាយការណ៍ប្រកាសពន្ធប្រចាំខែ — the monthly filing, built from the ledger.
--
-- A report can only summarise what was captured, so this file is really
-- two things: the CLASSIFICATIONS that must be recorded as business
-- happens, and the GENERATOR that adds them up at month end.
--
-- Four decisions here are load-bearing:
--
-- 1. VAT CREDIT CARRIES FORWARD. When input VAT exceeds output VAT the
--    excess is not refunded — it becomes a credit against next month. So
--    each month's return depends on the one before it. That makes the
--    returns a CHAIN, and an error in one month compounds through every
--    month after it, which is why generate_tax_return reads the prior
--    period rather than recomputing from scratch.
--
-- 2. NON-DEDUCTIBLE INPUT VAT IS RECORDED, NOT OMITTED. VAT on
--    entertainment and passenger cars cannot be claimed. Simply not
--    entering it would leave you unable to show you excluded it, so it is
--    captured with a reason and reported separately.
--
-- 3. WHT IS WITHHELD WHEN YOU PAY, NOT WHEN YOU ARE BILLED. A bill sitting
--    unpaid has withheld nothing. Deductions therefore hang off payments.
--
-- 4. THE 1% PREPAYMENT IS ON TURNOVER INCLUDING ALL TAXES EXCEPT VAT. So
--    specific taxes (PLT, accommodation, STCMS) ARE part of that base.
--    Easy to get wrong in the direction that underpays.
--
-- RATES ARE CONFIGURABLE, in tax_config. They are set by Prakas and they
-- change; hardcoding them would guarantee the software is wrong eventually.
-- The defaults shipped here must be checked against the current law.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.invoices, public.bills, public.payments, public.vendors,
--             public.products_services, public.employees,
--             public.has_any_role(text[]), public.is_employee().
-- =====================================================================

-- ---- rates --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tax_config (
  id boolean DEFAULT true NOT NULL,
  vat_rate numeric DEFAULT 10,                   -- standard VAT
  toi_prepayment_rate numeric DEFAULT 1,         -- monthly prepayment of tax on income
  plt_rate numeric DEFAULT 3,                    -- public lighting tax, on alcohol & tobacco
  accommodation_rate numeric DEFAULT 2,          -- accommodation tax on room charges
  vat_registered boolean DEFAULT true,
  fiscal_year_start_month integer DEFAULT 1,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tax_config_pkey PRIMARY KEY (id),
  CONSTRAINT tax_config_singleton CHECK (id = true),
  CONSTRAINT tax_config_rates_check CHECK (
    vat_rate >= 0 AND toi_prepayment_rate >= 0 AND plt_rate >= 0 AND accommodation_rate >= 0),
  CONSTRAINT tax_config_month_check CHECK (fiscal_year_start_month BETWEEN 1 AND 12)
);
INSERT INTO public.tax_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---- 1. classification on sales ----------------------------------------
-- Zero-rated (exports) and exempt supplies are both reported, separately,
-- and neither carries output VAT. Lumping them together loses information
-- the form asks for.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS vat_treatment text DEFAULT 'standard';
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS specific_tax_type text;   -- plt | accommodation | stcms
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS specific_tax_rate numeric DEFAULT 0;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS specific_tax_amount numeric DEFAULT 0;

DO $c$ BEGIN
  ALTER TABLE public.invoices ADD CONSTRAINT invoices_vat_treatment_check
    CHECK (vat_treatment = ANY (ARRAY['standard','zero_rated','exempt']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.invoices ADD CONSTRAINT invoices_specific_tax_check
    CHECK ((specific_tax_type IS NULL OR specific_tax_type = ANY (ARRAY['plt','accommodation','stcms']))
       AND specific_tax_rate >= 0 AND specific_tax_amount >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- Which specific tax a product attracts, so invoices can be typed from the
-- catalogue rather than remembered line by line.
ALTER TABLE public.products_services ADD COLUMN IF NOT EXISTS specific_tax_type text;
ALTER TABLE public.products_services ADD COLUMN IF NOT EXISTS specific_tax_rate numeric DEFAULT 0;
ALTER TABLE public.products_services ADD COLUMN IF NOT EXISTS vat_treatment text DEFAULT 'standard';

-- ---- 2. input VAT on purchases -----------------------------------------
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS input_vat_deductible boolean DEFAULT true;
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS non_deductible_reason text;  -- entertainment | passenger_car | non_business | no_valid_invoice | other
ALTER TABLE public.bills ADD COLUMN IF NOT EXISTS supplier_vattin text;

DO $c$ BEGIN
  ALTER TABLE public.bills ADD CONSTRAINT bills_non_deductible_reason_check
    CHECK (input_vat_deductible = true
        OR non_deductible_reason = ANY (ARRAY['entertainment','passenger_car','non_business','no_valid_invoice','other']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- ---- 3. withholding tax -------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wht_types (
  code text NOT NULL,
  name text NOT NULL,
  name_kh text,
  rate numeric NOT NULL,
  description text,
  is_active boolean DEFAULT true,
  CONSTRAINT wht_types_pkey PRIMARY KEY (code),
  CONSTRAINT wht_types_rate_check CHECK (rate >= 0 AND rate <= 100)
);

INSERT INTO public.wht_types (code, name, name_kh, rate, description)
SELECT v.* FROM (VALUES
  ('SVC15','Services — non-real regime / individuals','សេវាកម្ម',15,'Services, royalties and management fees paid to individuals or non-real-regime taxpayers'),
  ('RENT10','Rental of immovable property','ជួលអចលនទ្រព្យ',10,'Offices, warehouses, land and buildings'),
  ('INT15','Interest to non-bank resident lenders','ការប្រាក់',15,'Interest paid to resident lenders that are not banks'),
  ('NR14','Payments to non-residents','អ្នកមិនមែននិវាសនជន',14,'Income, services, royalties and interest paid abroad'),
  ('GOODS1','Small taxpayers / individuals','ទិញទំនិញ',1,'Quick purchase withholding on goods and services from small taxpayers')
) AS v(code, name, name_kh, rate, description)
WHERE NOT EXISTS (SELECT 1 FROM public.wht_types x WHERE x.code = v.code);

-- A deduction taken when a supplier is PAID. Vendor identity is snapshotted
-- because the certificate is their evidence and must not change later.
CREATE TABLE IF NOT EXISTS public.wht_deductions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  certificate_no text,
  vendor_id uuid,
  vendor_name_snapshot text,
  vendor_tin_snapshot text,
  vendor_address_snapshot text,
  bill_id uuid,
  payment_id uuid,
  wht_code text NOT NULL,
  rate numeric NOT NULL,                         -- snapshot of the rate applied
  base_amount numeric DEFAULT 0,                 -- the payment the tax is computed on
  wht_amount numeric DEFAULT 0,
  date date DEFAULT CURRENT_DATE,
  period text,                                   -- YYYY-MM, the filing period
  status text DEFAULT 'draft'::text,             -- draft | issued
  issued_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT wht_deductions_pkey PRIMARY KEY (id),
  CONSTRAINT wht_deductions_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL,
  CONSTRAINT wht_deductions_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES public.bills(id) ON DELETE SET NULL,
  CONSTRAINT wht_deductions_wht_code_fkey FOREIGN KEY (wht_code) REFERENCES public.wht_types(code) ON DELETE RESTRICT,
  CONSTRAINT wht_deductions_amounts_check CHECK (rate >= 0 AND base_amount >= 0 AND wht_amount >= 0),
  CONSTRAINT wht_deductions_status_check CHECK (status = ANY (ARRAY['draft','issued']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wht_certificate_no
  ON public.wht_deductions (certificate_no) WHERE certificate_no IS NOT NULL AND certificate_no <> '';
CREATE INDEX IF NOT EXISTS idx_wht_deductions_period ON public.wht_deductions (period);
CREATE INDEX IF NOT EXISTS idx_wht_deductions_vendor ON public.wht_deductions (vendor_id);
CREATE INDEX IF NOT EXISTS idx_wht_deductions_date ON public.wht_deductions (date);
-- One deduction per payment: withholding twice on one payment overstates
-- what was remitted and leaves the vendor with two certificates.
CREATE UNIQUE INDEX IF NOT EXISTS uq_wht_per_payment
  ON public.wht_deductions (payment_id) WHERE payment_id IS NOT NULL;

-- ---- 4. the monthly return ----------------------------------------------
CREATE TABLE IF NOT EXISTS public.tax_returns (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  period text NOT NULL,                          -- YYYY-MM
  status text DEFAULT 'draft'::text,             -- draft | filed
  -- output VAT
  sales_standard_base numeric DEFAULT 0,
  output_vat numeric DEFAULT 0,
  sales_zero_rated numeric DEFAULT 0,            -- exports
  sales_exempt numeric DEFAULT 0,
  -- input VAT
  purchases_base numeric DEFAULT 0,
  input_vat_claimable numeric DEFAULT 0,
  input_vat_non_deductible numeric DEFAULT 0,
  -- the chain
  credit_brought_forward numeric DEFAULT 0,
  vat_payable numeric DEFAULT 0,
  credit_carried_forward numeric DEFAULT 0,
  -- prepayment of tax on income
  gross_turnover numeric DEFAULT 0,
  toi_prepayment numeric DEFAULT 0,
  -- specific taxes
  plt_base numeric DEFAULT 0,
  plt_amount numeric DEFAULT 0,
  accommodation_base numeric DEFAULT 0,
  accommodation_amount numeric DEFAULT 0,
  stcms_base numeric DEFAULT 0,
  stcms_amount numeric DEFAULT 0,
  -- withholding
  wht_total numeric DEFAULT 0,
  total_payable numeric DEFAULT 0,
  generated_at timestamp with time zone DEFAULT now(),
  filed_at timestamp with time zone,
  filed_by uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tax_returns_pkey PRIMARY KEY (id),
  CONSTRAINT tax_returns_filed_by_fkey FOREIGN KEY (filed_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT tax_returns_period_check CHECK (period ~ '^[0-9]{4}-[0-9]{2}$'),
  CONSTRAINT tax_returns_status_check CHECK (status = ANY (ARRAY['draft','filed'])),
  CONSTRAINT tax_returns_nonneg_check CHECK (
    output_vat >= 0 AND input_vat_claimable >= 0 AND vat_payable >= 0
    AND credit_carried_forward >= 0 AND toi_prepayment >= 0 AND wht_total >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_tax_returns_period ON public.tax_returns (period);

-- A filed return is evidence. It cannot be silently regenerated over.
CREATE OR REPLACE FUNCTION public.protect_filed_return()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.status = 'filed' AND NEW.status = 'filed'
     AND (NEW.output_vat IS DISTINCT FROM OLD.output_vat
       OR NEW.input_vat_claimable IS DISTINCT FROM OLD.input_vat_claimable
       OR NEW.vat_payable IS DISTINCT FROM OLD.vat_payable
       OR NEW.credit_carried_forward IS DISTINCT FROM OLD.credit_carried_forward
       OR NEW.toi_prepayment IS DISTINCT FROM OLD.toi_prepayment) THEN
    RAISE EXCEPTION 'Return for % is filed and its figures cannot change. Unfile it first if it genuinely must be amended.', OLD.period
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_filed_return ON public.tax_returns;
CREATE TRIGGER trg_protect_filed_return
  BEFORE UPDATE ON public.tax_returns
  FOR EACH ROW EXECUTE FUNCTION public.protect_filed_return();

-- ---- the generator ------------------------------------------------------
-- One authoritative computation in the database rather than in a client, so
-- two screens can never disagree about what a month owes.
DROP FUNCTION IF EXISTS public.generate_tax_return(text);
CREATE OR REPLACE FUNCTION public.generate_tax_return(p_period text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg        tax_config%ROWTYPE;
  v_from       date;
  v_to         date;
  v_prev       text;
  v_bf         numeric := 0;
  v_std_base   numeric := 0;
  v_out_vat    numeric := 0;
  v_zero       numeric := 0;
  v_exempt     numeric := 0;
  v_pur_base   numeric := 0;
  v_in_claim   numeric := 0;
  v_in_nonded  numeric := 0;
  v_plt_b      numeric := 0; v_plt_a numeric := 0;
  v_acc_b      numeric := 0; v_acc_a numeric := 0;
  v_stc_b      numeric := 0; v_stc_a numeric := 0;
  v_wht        numeric := 0;
  v_turnover   numeric := 0;
  v_toi        numeric := 0;
  v_net        numeric;
  v_payable    numeric;
  v_cf         numeric;
  v_id         uuid;
  v_existing   tax_returns%ROWTYPE;
BEGIN
  IF p_period !~ '^[0-9]{4}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'Period must look like YYYY-MM, got %', p_period;
  END IF;

  SELECT * INTO v_existing FROM tax_returns WHERE period = p_period;
  IF FOUND AND v_existing.status = 'filed' THEN
    RAISE EXCEPTION 'Return for % has been filed and cannot be regenerated', p_period;
  END IF;

  SELECT * INTO v_cfg FROM tax_config WHERE id = true;
  v_from := (p_period || '-01')::date;
  v_to   := (v_from + INTERVAL '1 month - 1 day')::date;

  -- The chain: last month's unused credit offsets this month.
  v_prev := to_char(v_from - INTERVAL '1 month', 'YYYY-MM');
  SELECT COALESCE(credit_carried_forward, 0) INTO v_bf FROM tax_returns WHERE period = v_prev;
  v_bf := COALESCE(v_bf, 0);

  -- Output side. Voided invoices are excluded — they are not supplies.
  SELECT
    COALESCE(SUM(CASE WHEN vat_treatment = 'standard'   THEN amount END), 0),
    COALESCE(SUM(CASE WHEN vat_treatment = 'standard'   THEN ROUND(amount * COALESCE(tax_rate, v_cfg.vat_rate) / 100.0, 2) END), 0),
    COALESCE(SUM(CASE WHEN vat_treatment = 'zero_rated' THEN amount END), 0),
    COALESCE(SUM(CASE WHEN vat_treatment = 'exempt'     THEN amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'plt'           THEN amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'plt'           THEN specific_tax_amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'accommodation' THEN amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'accommodation' THEN specific_tax_amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'stcms'         THEN amount END), 0),
    COALESCE(SUM(CASE WHEN specific_tax_type = 'stcms'         THEN specific_tax_amount END), 0)
  INTO v_std_base, v_out_vat, v_zero, v_exempt, v_plt_b, v_plt_a, v_acc_b, v_acc_a, v_stc_b, v_stc_a
  FROM invoices
  WHERE date BETWEEN v_from AND v_to
    AND COALESCE(voided, false) = false;

  -- Input side. Non-deductible VAT is reported, not hidden.
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(CASE WHEN COALESCE(input_vat_deductible, true)      THEN tax_amount END), 0),
    COALESCE(SUM(CASE WHEN COALESCE(input_vat_deductible, true) = false THEN tax_amount END), 0)
  INTO v_pur_base, v_in_claim, v_in_nonded
  FROM bills
  WHERE date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(wht_amount), 0) INTO v_wht
  FROM wht_deductions WHERE date BETWEEN v_from AND v_to;

  -- Turnover for the 1% prepayment: all taxes EXCEPT VAT are in the base,
  -- so the specific taxes are included and output VAT is not.
  v_turnover := v_std_base + v_zero + v_exempt + v_plt_a + v_acc_a + v_stc_a;
  v_toi := ROUND(v_turnover * v_cfg.toi_prepayment_rate / 100.0, 2);

  -- Net VAT. A negative net is not a refund — it carries forward.
  v_net := v_out_vat - v_in_claim - v_bf;
  v_payable := GREATEST(v_net, 0);
  v_cf      := GREATEST(-v_net, 0);

  INSERT INTO tax_returns AS t (
    period, status,
    sales_standard_base, output_vat, sales_zero_rated, sales_exempt,
    purchases_base, input_vat_claimable, input_vat_non_deductible,
    credit_brought_forward, vat_payable, credit_carried_forward,
    gross_turnover, toi_prepayment,
    plt_base, plt_amount, accommodation_base, accommodation_amount,
    stcms_base, stcms_amount, wht_total, total_payable, generated_at
  ) VALUES (
    p_period, 'draft',
    v_std_base, v_out_vat, v_zero, v_exempt,
    v_pur_base, v_in_claim, v_in_nonded,
    v_bf, v_payable, v_cf,
    v_turnover, v_toi,
    v_plt_b, v_plt_a, v_acc_b, v_acc_a,
    v_stc_b, v_stc_a, v_wht,
    v_payable + v_toi + v_plt_a + v_acc_a + v_stc_a + v_wht, now()
  )
  ON CONFLICT (period) DO UPDATE SET
    sales_standard_base = EXCLUDED.sales_standard_base,
    output_vat = EXCLUDED.output_vat,
    sales_zero_rated = EXCLUDED.sales_zero_rated,
    sales_exempt = EXCLUDED.sales_exempt,
    purchases_base = EXCLUDED.purchases_base,
    input_vat_claimable = EXCLUDED.input_vat_claimable,
    input_vat_non_deductible = EXCLUDED.input_vat_non_deductible,
    credit_brought_forward = EXCLUDED.credit_brought_forward,
    vat_payable = EXCLUDED.vat_payable,
    credit_carried_forward = EXCLUDED.credit_carried_forward,
    gross_turnover = EXCLUDED.gross_turnover,
    toi_prepayment = EXCLUDED.toi_prepayment,
    plt_base = EXCLUDED.plt_base, plt_amount = EXCLUDED.plt_amount,
    accommodation_base = EXCLUDED.accommodation_base, accommodation_amount = EXCLUDED.accommodation_amount,
    stcms_base = EXCLUDED.stcms_base, stcms_amount = EXCLUDED.stcms_amount,
    wht_total = EXCLUDED.wht_total,
    total_payable = EXCLUDED.total_payable,
    generated_at = now()
  RETURNING t.id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Certificate numbers: sequential per year, like invoices.
DROP FUNCTION IF EXISTS public.issue_wht_certificate(uuid);
CREATE OR REPLACE FUNCTION public.issue_wht_certificate(p_deduction_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ded  wht_deductions%ROWTYPE;
  v_year integer;
  v_next integer;
  v_no   text;
BEGIN
  SELECT * INTO v_ded FROM wht_deductions WHERE id = p_deduction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Deduction not found'; END IF;
  IF v_ded.status = 'issued' THEN RAISE EXCEPTION 'Certificate % has already been issued', v_ded.certificate_no; END IF;

  v_year := EXTRACT(YEAR FROM COALESCE(v_ded.date, CURRENT_DATE))::integer;
  SELECT COALESCE(MAX(NULLIF(regexp_replace(certificate_no, '^WHT-[0-9]{4}-', ''), '')::integer), 0) + 1
    INTO v_next
    FROM wht_deductions
   WHERE certificate_no LIKE 'WHT-' || v_year::text || '-%';

  v_no := 'WHT-' || v_year::text || '-' || LPAD(v_next::text, 5, '0');
  UPDATE wht_deductions
     SET certificate_no = v_no, status = 'issued', issued_at = now()
   WHERE id = p_deduction_id;
  RETURN v_no;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.generate_tax_return(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_wht_certificate(uuid) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.tax_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wht_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wht_deductions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_returns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View tax config" ON public.tax_config;
DROP POLICY IF EXISTS "Manage tax config" ON public.tax_config;
CREATE POLICY "View tax config" ON public.tax_config FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tax config" ON public.tax_config FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View wht types" ON public.wht_types;
DROP POLICY IF EXISTS "Manage wht types" ON public.wht_types;
CREATE POLICY "View wht types" ON public.wht_types FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage wht types" ON public.wht_types FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View wht deductions" ON public.wht_deductions;
DROP POLICY IF EXISTS "Manage wht deductions" ON public.wht_deductions;
CREATE POLICY "View wht deductions" ON public.wht_deductions FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage wht deductions" ON public.wht_deductions FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View tax returns" ON public.tax_returns;
DROP POLICY IF EXISTS "Manage tax returns" ON public.tax_returns;
CREATE POLICY "View tax returns" ON public.tax_returns FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Manage tax returns" ON public.tax_returns FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
