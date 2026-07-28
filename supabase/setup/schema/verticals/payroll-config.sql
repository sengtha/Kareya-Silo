-- =====================================================================
-- KAREYA SILO — PAYROLL CONFIGURATION (payroll-config)
-- ---------------------------------------------------------------------
-- Cambodian payroll as it is actually run, not as a textbook describes
-- it. Three realities the shipped constants could not express:
--
--   1. Many businesses are not registered with NSSF (ប.ស.ស) yet.
--   2. Those that are often contribute at rates and on bases agreed with
--      staff rather than the statutory ones.
--   3. Some businesses pay the employee's Tax on Salary themselves.
--
-- So every rate moves out of the code and into this table, with
-- per-employee overrides on top. The statutory figures remain the
-- DEFAULTS — a business that changes nothing behaves exactly as before.
--
-- THE IMPORTANT PART: every payslip stores THE RATES IT USED. Changing a
-- rate must never silently restate a payslip that has already been paid
-- and filed. Without the snapshot, editing one number would make last
-- year's NSSF and ToS declarations impossible to reconcile against the
-- payslips that produced them. This is the same discipline as freezing
-- the NBC rate onto an issued invoice.
--
-- Nothing here is tax advice, and the defaults must be checked against
-- the current law and against your own agreements.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.payslips,
--             public.has_any_role(text[]), public.is_employee().
-- =====================================================================

-- ---- company-wide settings ---------------------------------------------
CREATE TABLE IF NOT EXISTS public.payroll_config (
  id boolean DEFAULT true NOT NULL,

  -- NSSF (ប.ស.ស). Off entirely for a business that has not registered.
  nssf_enabled boolean DEFAULT false,
  nssf_pension_employee numeric DEFAULT 2,        -- percent of assessable wage
  nssf_pension_employer numeric DEFAULT 2,
  nssf_health_employee numeric DEFAULT 1.3,
  nssf_health_employer numeric DEFAULT 1.3,
  nssf_risk_employer numeric DEFAULT 0.8,         -- occupational risk, employer only
  nssf_cap_enabled boolean DEFAULT true,
  nssf_wage_cap_khr numeric DEFAULT 1200000,      -- assessable-wage ceiling

  -- Tax on Salary (ToS). borne_by = who actually bears it. Either way the
  -- GDT declaration reports the same tax — this decides whose money it is.
  tos_enabled boolean DEFAULT true,
  tos_borne_by text DEFAULT 'employee',           -- employee | employer
  tos_gross_up boolean DEFAULT false,             -- net-pay agreements only
  dependent_relief_khr numeric DEFAULT 150000,
  tos_brackets jsonb DEFAULT '[
    {"upTo": 1300000, "rate": 0},
    {"upTo": 2000000, "rate": 0.05},
    {"upTo": 8500000, "rate": 0.10},
    {"upTo": 12500000, "rate": 0.15},
    {"upTo": null, "rate": 0.20}
  ]'::jsonb,

  -- Seniority indemnity: statutory 15 days a year, varied by agreement.
  seniority_enabled boolean DEFAULT true,
  seniority_days_per_year numeric DEFAULT 15,
  working_days_per_month numeric DEFAULT 26,

  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payroll_config_pkey PRIMARY KEY (id),
  CONSTRAINT payroll_config_singleton CHECK (id = true),
  CONSTRAINT payroll_config_rates_check CHECK (
    nssf_pension_employee BETWEEN 0 AND 100 AND nssf_pension_employer BETWEEN 0 AND 100
    AND nssf_health_employee BETWEEN 0 AND 100 AND nssf_health_employer BETWEEN 0 AND 100
    AND nssf_risk_employer BETWEEN 0 AND 100
    AND nssf_wage_cap_khr >= 0 AND dependent_relief_khr >= 0
    AND seniority_days_per_year >= 0 AND working_days_per_month > 0),
  CONSTRAINT payroll_config_borne_check CHECK (tos_borne_by = ANY (ARRAY['employee','employer'])),
  -- A gross-up only means anything when the employer is bearing the tax.
  CONSTRAINT payroll_config_grossup_check CHECK (NOT tos_gross_up OR tos_borne_by = 'employer')
);

-- Default OFF for NSSF: a business that has not registered should not see
-- deductions it does not make. Turning it on is one switch and deliberate.
INSERT INTO public.payroll_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

COMMENT ON COLUMN public.payroll_config.tos_gross_up IS
  'Net-pay agreements ("you receive $500 in hand"). The tax the employer bears is itself a taxable benefit, so the base is circular and is solved iteratively. Confirm the treatment with your accountant.';

-- ---- per-employee overrides --------------------------------------------
-- "By agreement" usually means one person's package differs, not the whole
-- roster. NULL everywhere means "follow the company settings".
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nssf_enrolled boolean;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nssf_member_no text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nssf_start_date date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nssf_employee_rate numeric;   -- total employee %, overrides pension+health
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nssf_employer_rate numeric;   -- total employer %
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS tos_borne_by text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS national_id text;             -- required by the NSSF export

DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_tos_borne_check
    CHECK (tos_borne_by IS NULL OR tos_borne_by = ANY (ARRAY['employee','employer']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_nssf_rate_check
    CHECK ((nssf_employee_rate IS NULL OR nssf_employee_rate BETWEEN 0 AND 100)
       AND (nssf_employer_rate IS NULL OR nssf_employer_rate BETWEEN 0 AND 100));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_employees_nssf_member ON public.employees (nssf_member_no)
  WHERE nssf_member_no IS NOT NULL;

-- ---- the snapshot on every payslip -------------------------------------
-- What was actually applied, frozen at generation. A payslip must always
-- explain itself, even after the rates change.
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS nssf_applied boolean DEFAULT false;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS nssf_employee_rate numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS nssf_employer_rate numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS nssf_assessable_khr numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS tos_borne_by text DEFAULT 'employee';
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS tos_paid_by_employer numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS grossed_up_amount numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS khr_per_unit numeric DEFAULT 1;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS config_snapshot jsonb;

DO $c$ BEGIN
  ALTER TABLE public.payslips ADD CONSTRAINT payslips_tos_borne_check
    CHECK (tos_borne_by IS NULL OR tos_borne_by = ANY (ARRAY['employee','employer']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- A paid payslip has been handed over and declared. Its figures are
-- history; correcting one is a credit and a re-issue, not an edit.
CREATE OR REPLACE FUNCTION public.protect_paid_payslip()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.status = 'paid' AND NEW.status = 'paid'
     AND (NEW.gross IS DISTINCT FROM OLD.gross
       OR NEW.tax IS DISTINCT FROM OLD.tax
       OR NEW.net IS DISTINCT FROM OLD.net
       OR NEW.nssf_employee IS DISTINCT FROM OLD.nssf_employee
       OR NEW.nssf_employer IS DISTINCT FROM OLD.nssf_employer
       OR NEW.seniority_accrual IS DISTINCT FROM OLD.seniority_accrual) THEN
    RAISE EXCEPTION 'Payslip % has been paid. Its figures cannot be changed.', OLD.period;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_paid_payslip ON public.payslips;
CREATE TRIGGER trg_protect_paid_payslip
  BEFORE UPDATE ON public.payslips
  FOR EACH ROW EXECUTE FUNCTION public.protect_paid_payslip();

-- ---- effective settings for one employee -------------------------------
/** Resolve company settings + employee overrides into the figures a
 *  payslip should actually use. One place, so the payslip screen, the
 *  ledger and the NSSF export cannot disagree about somebody's rate.
 *
 *  p_period ('YYYY-MM') matters: an employee enrolled in June must show
 *  no contribution in May, and re-running May later must still show none. */
DROP FUNCTION IF EXISTS public.effective_payroll_settings(uuid, text);
CREATE OR REPLACE FUNCTION public.effective_payroll_settings(p_employee_id uuid, p_period text DEFAULT NULL)
 RETURNS TABLE (
   out_nssf_applies boolean,
   out_nssf_employee_rate numeric,
   out_nssf_employer_rate numeric,
   out_cap_enabled boolean,
   out_wage_cap_khr numeric,
   out_tos_enabled boolean,
   out_tos_borne_by text,
   out_tos_gross_up boolean,
   out_dependent_relief_khr numeric,
   out_tos_brackets jsonb,
   out_seniority_enabled boolean,
   out_seniority_days numeric,
   out_working_days numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    -- Enrolled when the company runs NSSF AND this person is in it AND
    -- their start date has arrived.
    c.nssf_enabled
      AND COALESCE(e.nssf_enrolled, true)
      AND (e.nssf_start_date IS NULL OR p_period IS NULL
           OR to_date(p_period || '-01', 'YYYY-MM-DD')
              >= date_trunc('month', e.nssf_start_date)::date),
    COALESCE(e.nssf_employee_rate, c.nssf_pension_employee + c.nssf_health_employee),
    COALESCE(e.nssf_employer_rate, c.nssf_pension_employer + c.nssf_health_employer + c.nssf_risk_employer),
    c.nssf_cap_enabled,
    c.nssf_wage_cap_khr,
    c.tos_enabled,
    COALESCE(e.tos_borne_by, c.tos_borne_by),
    c.tos_gross_up AND COALESCE(e.tos_borne_by, c.tos_borne_by) = 'employer',
    c.dependent_relief_khr,
    c.tos_brackets,
    c.seniority_enabled,
    c.seniority_days_per_year,
    c.working_days_per_month
  FROM payroll_config c
  LEFT JOIN employees e ON e.id = p_employee_id
  WHERE c.id;
$function$;
GRANT EXECUTE ON FUNCTION public.effective_payroll_settings(uuid, text) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.payroll_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View payroll config" ON public.payroll_config;
DROP POLICY IF EXISTS "Manage payroll config" ON public.payroll_config;
-- Everyone may read the rates: an employee is entitled to know how their
-- own deductions were worked out. Only payroll may change them.
CREATE POLICY "View payroll config" ON public.payroll_config FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage payroll config" ON public.payroll_config FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']))
  WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']));
