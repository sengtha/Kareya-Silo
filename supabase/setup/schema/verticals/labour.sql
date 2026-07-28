-- =====================================================================
-- KAREYA SILO — CAMBODIA LABOUR COMPLIANCE (labour)
-- ---------------------------------------------------------------------
-- Ministry of Labour and Vocational Training obligations that payroll on
-- its own cannot express:
--
--   A. Contract type — FDC (fixed duration) vs UDD (undetermined).
--      Different endings, different money: an FDC that expires owes a
--      severance indemnity, a UDD ended by the employer owes notice.
--   B. Seniority indemnity is ACCRUED monthly but PAID twice a year.
--      Accruing without ever paying leaves a provision that grows for
--      ever and staff who never receive what they are owed.
--   C. Overtime is not one rate. Ordinary overtime and night, Sunday or
--      public-holiday overtime are paid differently, and an attendance
--      log that records only "hours" cannot tell them apart afterwards.
--   D. Foreign staff need work permits, and the workforce is subject to
--      a foreign quota. Both are invisible until they are breached.
--   E. Maternity leave is paid at a higher rate to staff with enough
--      tenure, and non-salary benefits attract fringe benefit tax.
--
-- EVERY RATE, THRESHOLD AND PERIOD HERE IS CONFIGURABLE, for the same
-- reason as payroll_config: the law states them, agreements vary, and
-- Prakas change them. The figures seeded are the ones this deployment
-- asked for and MUST be checked against the current Labour Law before
-- anybody is paid or dismissed on the strength of them. Nothing here is
-- legal advice.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.payslips, public.leave_types,
--             public.attendance_records, public.holidays,
--             public.payroll_config, public.has_any_role(text[]),
--             public.is_employee().
-- =====================================================================

-- ---- settings -----------------------------------------------------------
-- The verticals are documented as applicable IN ANY ORDER, and 'labour'
-- sorts before 'payroll-config'. So the shared singleton is created here
-- too if it does not exist yet; both files then add their own columns by
-- ALTER, and whichever runs first leaves a table the other can extend.
CREATE TABLE IF NOT EXISTS public.payroll_config (
  id boolean DEFAULT true NOT NULL,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payroll_config_pkey PRIMARY KEY (id),
  CONSTRAINT payroll_config_singleton CHECK (id = true)
);
INSERT INTO public.payroll_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS fdc_severance_rate numeric DEFAULT 5;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS fdc_max_months integer DEFAULT 24;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS ot_rate_standard numeric DEFAULT 150;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS ot_rate_premium numeric DEFAULT 200;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS standard_day_hours numeric DEFAULT 8;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS night_start_hour integer DEFAULT 22;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS night_end_hour integer DEFAULT 6;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS fbt_rate numeric DEFAULT 20;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS foreign_quota_total numeric DEFAULT 10;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS foreign_quota_office numeric DEFAULT 3;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS foreign_quota_specialized numeric DEFAULT 6;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS foreign_quota_unskilled numeric DEFAULT 1;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS seniority_payout_months integer[] DEFAULT ARRAY[6, 12];
-- The database runs in UTC. Every rule below is about LOCAL time — a shift
-- starting 08:00 in Phnom Penh is 01:00 UTC, which would be scored as night
-- work and paid at the premium rate. So the business timezone is explicit.
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS business_timezone text DEFAULT 'Asia/Phnom_Penh';
-- Read by generate_seniority_payouts and split_overtime. Owned by
-- payroll-config.sql; declared here so this file works whichever ran first.
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS seniority_enabled boolean DEFAULT true;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS seniority_days_per_year numeric DEFAULT 15;
ALTER TABLE public.payroll_config ADD COLUMN IF NOT EXISTS working_days_per_month numeric DEFAULT 26;

COMMENT ON COLUMN public.payroll_config.seniority_payout_months IS
  'Months in which accrued seniority indemnity is actually paid out. June and December by default — accruing without paying leaves staff owed money they never receive.';

DO $c$ BEGIN
  ALTER TABLE public.payroll_config ADD CONSTRAINT payroll_config_labour_check CHECK (
    fdc_severance_rate >= 0 AND fdc_max_months > 0
    AND ot_rate_standard >= 100 AND ot_rate_premium >= 100
    AND standard_day_hours > 0 AND standard_day_hours <= 24
    AND night_start_hour BETWEEN 0 AND 23 AND night_end_hour BETWEEN 0 AND 23
    AND fbt_rate >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- =====================================================================
-- A. CONTRACT CLASSIFICATION (FDC / UDD)
-- =====================================================================
-- hire_date is separate from contract_start: somebody on their third FDC
-- has one hire date and three contract starts, and seniority follows the
-- hire date while severance follows the contract.
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS hire_date date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS contract_type text;      -- fdc | udd
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS contract_start date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS contract_end date;       -- FDC only
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS contract_renewals integer DEFAULT 0;

DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_contract_type_check
    CHECK (contract_type IS NULL OR contract_type = ANY (ARRAY['fdc','udd']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
-- A fixed-duration contract with no end date is not fixed-duration. This
-- is the mistake that silently turns an FDC into a UDD in law while the
-- records still say FDC.
DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_fdc_end_check
    CHECK (contract_type <> 'fdc' OR contract_end IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_contract_dates_check
    CHECK (contract_end IS NULL OR contract_start IS NULL OR contract_end >= contract_start);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_employees_contract_end ON public.employees (contract_end)
  WHERE contract_end IS NOT NULL;

-- Notice due on ending a UDD, by length of service. A table rather than a
-- CASE so it can be corrected without a code change.
CREATE TABLE IF NOT EXISTS public.notice_period_rules (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  from_months integer NOT NULL,                  -- inclusive
  to_months integer,                             -- exclusive; NULL = no upper bound
  notice_days integer NOT NULL,
  label text,
  CONSTRAINT notice_period_rules_pkey PRIMARY KEY (id),
  CONSTRAINT notice_period_rules_range_check CHECK (to_months IS NULL OR to_months > from_months),
  CONSTRAINT notice_period_rules_days_check CHECK (notice_days >= 0)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_notice_period_rules_from ON public.notice_period_rules (from_months);

INSERT INTO public.notice_period_rules (from_months, to_months, notice_days, label)
SELECT v.* FROM (VALUES
  (0,   6,    7,   'Under 6 months'),
  (6,   24,   15,  '6 months to 2 years'),
  (24,  60,   30,  '2 to 5 years'),
  (60,  120,  60,  '5 to 10 years'),
  (120, NULL, 90,  'Over 10 years')
) AS v(from_months, to_months, notice_days, label)
WHERE NOT EXISTS (SELECT 1 FROM public.notice_period_rules x WHERE x.from_months = v.from_months);

-- =====================================================================
-- B. SENIORITY INDEMNITY PAYOUTS (June & December)
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.seniority_payouts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  period text NOT NULL,                          -- 'YYYY-H1' | 'YYYY-H2'
  employee_id uuid NOT NULL,
  days numeric DEFAULT 0,
  daily_wage numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  accrued_to_date numeric DEFAULT 0,             -- what payroll had provided for
  tax_exempt boolean DEFAULT true,
  status text DEFAULT 'draft' NOT NULL,          -- draft | paid
  pay_date date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT seniority_payouts_pkey PRIMARY KEY (id),
  CONSTRAINT seniority_payouts_employee_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT seniority_payouts_status_check CHECK (status = ANY (ARRAY['draft','paid'])),
  CONSTRAINT seniority_payouts_amount_check CHECK (amount >= 0 AND days >= 0)
);
-- Paying the same half-year twice is money out of the door that no report
-- will show as a duplicate.
CREATE UNIQUE INDEX IF NOT EXISTS uq_seniority_payouts_period
  ON public.seniority_payouts (employee_id, period);

CREATE OR REPLACE FUNCTION public.protect_paid_seniority_payout()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'paid' THEN
      RAISE EXCEPTION 'Seniority payout % has been paid and cannot be deleted.', OLD.period;
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status = 'paid' AND NEW.status = 'paid' AND NEW.amount IS DISTINCT FROM OLD.amount THEN
    RAISE EXCEPTION 'Seniority payout % has been paid. Its amount cannot be changed.', OLD.period;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_paid_seniority_payout ON public.seniority_payouts;
CREATE TRIGGER trg_protect_paid_seniority_payout
  BEFORE UPDATE OR DELETE ON public.seniority_payouts
  FOR EACH ROW EXECUTE FUNCTION public.protect_paid_seniority_payout();

/** Build the half-year batch. Half the annual entitlement each time, on
 *  the daily wage derived from the person's most recent payslip — not
 *  from today's salary, so a raise in December does not retrospectively
 *  inflate what was earned in January.
 *
 *  Existing rows are refreshed while draft and left alone once paid. */
DROP FUNCTION IF EXISTS public.generate_seniority_payouts(text);
CREATE OR REPLACE FUNCTION public.generate_seniority_payouts(p_period text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_year integer;
  v_half text;
  v_from date;
  v_to date;
  v_cfg record;
  v_days numeric;
  v_count integer := 0;
  r record;
  v_daily numeric;
  v_accrued numeric;
BEGIN
  IF p_period !~ '^[0-9]{4}-H[12]$' THEN
    RAISE EXCEPTION 'Period must look like 2026-H1 or 2026-H2, not %', p_period;
  END IF;
  v_year := left(p_period, 4)::integer;
  v_half := right(p_period, 1);
  v_from := make_date(v_year, CASE WHEN v_half = '1' THEN 1 ELSE 7 END, 1);
  v_to   := (v_from + interval '6 months' - interval '1 day')::date;

  SELECT * INTO v_cfg FROM payroll_config WHERE id;
  IF NOT COALESCE(v_cfg.seniority_enabled, true) THEN RETURN 0; END IF;

  -- Half the annual entitlement per payout.
  v_days := COALESCE(v_cfg.seniority_days_per_year, 15) / 2.0;

  FOR r IN
    SELECT e.id, e.hire_date, e.status
      FROM employees e
     WHERE e.status <> 'invited'
       -- Not yet started by the end of the half-year earns nothing for it.
       AND (e.hire_date IS NULL OR e.hire_date <= v_to)
  LOOP
    -- Daily wage from the most recent payslip inside the period, falling
    -- back to the latest before it. A person with no payslip at all has
    -- nothing to compute from and is skipped rather than guessed at.
    SELECT COALESCE(p.base_salary, 0) / NULLIF(COALESCE(v_cfg.working_days_per_month, 26), 0)
      INTO v_daily
      FROM payslips p
     WHERE p.employee_id = r.id AND p.pay_date <= v_to
     ORDER BY p.pay_date DESC
     LIMIT 1;

    IF v_daily IS NULL OR v_daily <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(SUM(seniority_accrual), 0) INTO v_accrued
      FROM payslips
     WHERE employee_id = r.id AND pay_date BETWEEN v_from AND v_to;

    INSERT INTO seniority_payouts (period, employee_id, days, daily_wage, amount, accrued_to_date)
    VALUES (p_period, r.id, v_days, ROUND(v_daily, 2), ROUND(v_daily * v_days, 2), ROUND(v_accrued, 2))
    ON CONFLICT (employee_id, period) DO UPDATE
      SET days = EXCLUDED.days, daily_wage = EXCLUDED.daily_wage,
          amount = EXCLUDED.amount, accrued_to_date = EXCLUDED.accrued_to_date
      WHERE seniority_payouts.status = 'draft';
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.generate_seniority_payouts(text) TO authenticated;

-- =====================================================================
-- C. OVERTIME BANDS
-- =====================================================================
-- Recorded per attendance day, because the reason a given hour is premium
-- — night, Sunday, public holiday — is knowable on the day and guesswork
-- three weeks later.
ALTER TABLE public.attendance_records ADD COLUMN IF NOT EXISTS regular_hours numeric DEFAULT 0;
ALTER TABLE public.attendance_records ADD COLUMN IF NOT EXISTS ot_hours_standard numeric DEFAULT 0;  -- 150%
ALTER TABLE public.attendance_records ADD COLUMN IF NOT EXISTS ot_hours_premium numeric DEFAULT 0;   -- 200%
ALTER TABLE public.attendance_records ADD COLUMN IF NOT EXISTS ot_note text;

DO $c$ BEGIN
  ALTER TABLE public.attendance_records ADD CONSTRAINT attendance_ot_check
    CHECK (regular_hours >= 0 AND ot_hours_standard >= 0 AND ot_hours_premium >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** Split one attended day into ordinary hours, ordinary overtime and
 *  premium overtime.
 *
 *  Sunday and public holidays make the WHOLE day premium — there are no
 *  ordinary hours on a rest day. Otherwise hours beyond the standard day
 *  are overtime, and any of them falling in the night window are premium
 *  rather than ordinary. */
DROP FUNCTION IF EXISTS public.split_overtime(timestamptz, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.split_overtime(
  p_check_in timestamptz, p_check_out timestamptz, p_is_holiday boolean DEFAULT NULL)
 RETURNS TABLE (out_regular numeric, out_ot_standard numeric, out_ot_premium numeric, out_note text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg record;
  v_total numeric;
  v_std numeric;
  v_night numeric := 0;
  v_holiday boolean;
  v_day integer;
  v_tz text;
  h integer;
  v_cursor timestamptz;
BEGIN
  IF p_check_in IS NULL OR p_check_out IS NULL OR p_check_out <= p_check_in THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, NULL::text;
    RETURN;
  END IF;

  SELECT * INTO v_cfg FROM payroll_config WHERE id;
  v_std := COALESCE(v_cfg.standard_day_hours, 8);
  v_tz := COALESCE(NULLIF(v_cfg.business_timezone, ''), 'Asia/Phnom_Penh');
  v_total := ROUND(EXTRACT(epoch FROM (p_check_out - p_check_in)) / 3600.0, 2);
  -- Local time throughout: Sunday, the calendar date and the night window
  -- are all local facts, and the database is not.
  v_day := EXTRACT(dow FROM (p_check_in AT TIME ZONE v_tz));   -- 0 = Sunday

  v_holiday := COALESCE(p_is_holiday,
    EXISTS (SELECT 1 FROM holidays WHERE date = (p_check_in AT TIME ZONE v_tz)::date));

  IF v_holiday OR v_day = 0 THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, v_total,
      CASE WHEN v_holiday THEN 'Public holiday — whole day at the premium rate'
           ELSE 'Sunday — whole day at the premium rate' END;
    RETURN;
  END IF;

  IF v_total <= v_std THEN
    RETURN QUERY SELECT v_total, 0::numeric, 0::numeric, NULL::text;
    RETURN;
  END IF;

  -- Count whole night hours inside the shift, hour by hour: the window
  -- wraps past midnight, so arithmetic on the endpoints gets it wrong.
  v_cursor := date_trunc('hour', p_check_in);
  WHILE v_cursor < p_check_out LOOP
    h := EXTRACT(hour FROM (v_cursor AT TIME ZONE v_tz));
    IF (COALESCE(v_cfg.night_start_hour, 22) > COALESCE(v_cfg.night_end_hour, 6)
         AND (h >= COALESCE(v_cfg.night_start_hour, 22) OR h < COALESCE(v_cfg.night_end_hour, 6)))
       OR (COALESCE(v_cfg.night_start_hour, 22) <= COALESCE(v_cfg.night_end_hour, 6)
         AND h >= COALESCE(v_cfg.night_start_hour, 22) AND h < COALESCE(v_cfg.night_end_hour, 6)) THEN
      v_night := v_night + LEAST(1, EXTRACT(epoch FROM (p_check_out - GREATEST(v_cursor, p_check_in))) / 3600.0);
    END IF;
    v_cursor := v_cursor + interval '1 hour';
  END LOOP;

  -- Night hours count as premium overtime, but only up to the overtime
  -- actually worked: night hours inside the ordinary day are ordinary.
  v_night := LEAST(ROUND(v_night, 2), v_total - v_std);

  RETURN QUERY SELECT v_std, ROUND(v_total - v_std - v_night, 2), v_night,
    CASE WHEN v_night > 0 THEN v_night::text || ' night hour(s) at the premium rate' ELSE NULL END;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.split_overtime(timestamptz, timestamptz, boolean) TO authenticated;

/** Recalculate the overtime split for a period. Never touches a day whose
 *  hours were entered by hand — a correction outranks a recomputation. */
DROP FUNCTION IF EXISTS public.recalc_overtime(date, date, uuid);
CREATE OR REPLACE FUNCTION public.recalc_overtime(p_from date, p_to date, p_employee_id uuid DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count integer := 0;
  r record;
  s record;
BEGIN
  FOR r IN
    SELECT id, check_in, check_out FROM attendance_records
     WHERE date BETWEEN p_from AND p_to
       AND (p_employee_id IS NULL OR employee_id = p_employee_id)
       AND check_in IS NOT NULL AND check_out IS NOT NULL
       AND COALESCE(ot_note, '') <> 'manual'
  LOOP
    SELECT * INTO s FROM split_overtime(r.check_in, r.check_out, NULL);
    UPDATE attendance_records
       SET regular_hours = s.out_regular,
           ot_hours_standard = s.out_ot_standard,
           ot_hours_premium = s.out_ot_premium,
           ot_note = s.out_note
     WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.recalc_overtime(date, date, uuid) TO authenticated;

/** Overtime hours for one person in one month, for the payslip. */
DROP FUNCTION IF EXISTS public.overtime_for_period(uuid, date, date);
CREATE OR REPLACE FUNCTION public.overtime_for_period(p_employee_id uuid, p_from date, p_to date)
 RETURNS TABLE (out_ot_standard numeric, out_ot_premium numeric, out_regular numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(SUM(ot_hours_standard), 0), COALESCE(SUM(ot_hours_premium), 0),
         COALESCE(SUM(regular_hours), 0)
    FROM attendance_records
   WHERE employee_id = p_employee_id AND date BETWEEN p_from AND p_to;
$function$;
GRANT EXECUTE ON FUNCTION public.overtime_for_period(uuid, date, date) TO authenticated;

-- The payslip carries the overtime it paid, so a payslip still explains
-- itself after the attendance log has been corrected.
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS ot_hours_standard numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS ot_hours_premium numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS ot_pay numeric DEFAULT 0;

-- =====================================================================
-- D. FOREIGN WORK PERMITS AND QUOTA
-- =====================================================================
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS is_foreign boolean DEFAULT false;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS nationality text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS passport_no text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS passport_expiry date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS work_permit_no text;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS work_permit_expiry date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS visa_expiry date;
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS foreign_category text;   -- office | specialized | unskilled

DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_foreign_category_check
    CHECK (foreign_category IS NULL OR foreign_category = ANY (ARRAY['office','specialized','unskilled']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
-- A foreign employee with no category cannot be counted against any
-- sub-quota, which is how a breach hides.
DO $c$ BEGIN
  ALTER TABLE public.employees ADD CONSTRAINT employees_foreign_needs_category_check
    CHECK (NOT COALESCE(is_foreign, false) OR foreign_category IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_employees_permit_expiry ON public.employees (work_permit_expiry)
  WHERE work_permit_expiry IS NOT NULL;

/** Where the workforce stands against the foreign quota. Percentages are
 *  of ACTIVE headcount — counting people who have left would understate
 *  the ratio and hide a breach. */
DROP FUNCTION IF EXISTS public.foreign_quota_status();
CREATE OR REPLACE FUNCTION public.foreign_quota_status()
 RETURNS TABLE (
   out_category text, out_headcount integer, out_total integer,
   out_percent numeric, out_limit_percent numeric, out_within boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH staff AS (SELECT * FROM employees WHERE status = 'active'),
       total AS (SELECT GREATEST(COUNT(*), 1) AS n FROM staff),
       cfg AS (SELECT * FROM payroll_config WHERE id)
  SELECT q.category,
         COALESCE(c.n, 0)::integer,
         total.n::integer,
         ROUND(COALESCE(c.n, 0) * 100.0 / total.n, 2),
         q.lim,
         ROUND(COALESCE(c.n, 0) * 100.0 / total.n, 2) <= q.lim
    FROM total, cfg,
    LATERAL (VALUES
      ('all foreign', COALESCE(cfg.foreign_quota_total, 10)),
      ('office', COALESCE(cfg.foreign_quota_office, 3)),
      ('specialized', COALESCE(cfg.foreign_quota_specialized, 6)),
      ('unskilled', COALESCE(cfg.foreign_quota_unskilled, 1))
    ) AS q(category, lim)
    LEFT JOIN LATERAL (
      SELECT COUNT(*) AS n FROM staff s
       WHERE s.is_foreign
         AND (q.category = 'all foreign' OR s.foreign_category = q.category)
    ) c ON true;
$function$;
GRANT EXECUTE ON FUNCTION public.foreign_quota_status() TO authenticated;

/** Permits, visas and passports about to lapse — or already lapsed. A
 *  work permit that expired last week is more urgent than one expiring
 *  next month, so expired documents come back with negative days. */
DROP FUNCTION IF EXISTS public.expiring_permits(integer);
CREATE OR REPLACE FUNCTION public.expiring_permits(p_within_days integer DEFAULT 90)
 RETURNS TABLE (
   out_employee_id uuid, out_name text, out_document text,
   out_reference text, out_expires date, out_days_left integer
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT e.id, e.name, d.doc, d.ref, d.expires, (d.expires - CURRENT_DATE)::integer
    FROM employees e
    CROSS JOIN LATERAL (VALUES
      ('Work permit', e.work_permit_no, e.work_permit_expiry),
      ('Passport', e.passport_no, e.passport_expiry),
      ('Visa', NULL::text, e.visa_expiry)
    ) AS d(doc, ref, expires)
   WHERE e.status = 'active' AND e.is_foreign
     AND d.expires IS NOT NULL
     AND d.expires <= CURRENT_DATE + p_within_days
   ORDER BY d.expires;
$function$;
GRANT EXECUTE ON FUNCTION public.expiring_permits(integer) TO authenticated;

-- =====================================================================
-- E. MATERNITY LEAVE AND FRINGE BENEFIT TAX
-- =====================================================================
-- Leave is not all paid at 100%. Maternity is paid above full salary to
-- staff with enough service, and a leave type that cannot express a rate
-- forces somebody to fix it by hand on every payslip.
ALTER TABLE public.leave_types ADD COLUMN IF NOT EXISTS pay_rate_percent numeric DEFAULT 100;
ALTER TABLE public.leave_types ADD COLUMN IF NOT EXISTS min_tenure_months integer DEFAULT 0;
ALTER TABLE public.leave_types ADD COLUMN IF NOT EXISTS is_maternity boolean DEFAULT false;
ALTER TABLE public.leave_types ADD COLUMN IF NOT EXISTS employer_share_percent numeric;  -- rest from NSSF

DO $c$ BEGIN
  ALTER TABLE public.leave_types ADD CONSTRAINT leave_types_pay_rate_check
    CHECK (pay_rate_percent >= 0 AND min_tenure_months >= 0
       AND (employer_share_percent IS NULL OR employer_share_percent BETWEEN 0 AND 100));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

INSERT INTO public.leave_types (name, days_per_year, is_paid, color, is_active,
                                pay_rate_percent, min_tenure_months, is_maternity, employer_share_percent)
SELECT 'Maternity', 90, true, '#ec4899', true, 120, 12, true, 50
WHERE NOT EXISTS (SELECT 1 FROM public.leave_types WHERE is_maternity);

COMMENT ON COLUMN public.leave_types.employer_share_percent IS
  'The share the employer pays directly. For maternity the balance is claimed from NSSF, so the employee receives the full rate while the business bears only this part.';

-- Fringe benefits: housing, a vehicle, an interest-free loan. Taxed
-- separately from salary, so recorded separately from salary.
CREATE TABLE IF NOT EXISTS public.fringe_benefits (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid NOT NULL,
  period text NOT NULL,                          -- 'YYYY-MM'
  benefit_type text NOT NULL,                    -- housing | vehicle | loan | meals | other
  description text,
  amount numeric DEFAULT 0 NOT NULL,
  is_taxable boolean DEFAULT true,               -- some benefits are exempt
  exempt_reason text,
  fbt_rate numeric,                              -- frozen at entry; NULL until computed
  fbt_amount numeric DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fringe_benefits_pkey PRIMARY KEY (id),
  CONSTRAINT fringe_benefits_employee_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT fringe_benefits_type_check CHECK (benefit_type = ANY (ARRAY['housing','vehicle','loan','meals','other'])),
  CONSTRAINT fringe_benefits_amount_check CHECK (amount >= 0 AND fbt_amount >= 0),
  -- An exempt benefit with no stated reason cannot be defended in an audit.
  CONSTRAINT fringe_benefits_exempt_check CHECK (is_taxable OR exempt_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_fringe_benefits_period ON public.fringe_benefits (period, employee_id);

-- Fringe benefit tax is on the employer, at a flat rate on the value of
-- the benefit. Computed on write so the figure cannot drift from the rate
-- that was in force.
CREATE OR REPLACE FUNCTION public.compute_fbt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_rate numeric;
BEGIN
  IF NOT NEW.is_taxable THEN
    NEW.fbt_rate := 0; NEW.fbt_amount := 0;
    RETURN NEW;
  END IF;
  SELECT COALESCE(fbt_rate, 20) INTO v_rate FROM payroll_config WHERE id;
  NEW.fbt_rate := COALESCE(NEW.fbt_rate, v_rate);
  NEW.fbt_amount := ROUND(NEW.amount * NEW.fbt_rate / 100.0, 2);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_compute_fbt ON public.fringe_benefits;
CREATE TRIGGER trg_compute_fbt
  BEFORE INSERT OR UPDATE OF amount, is_taxable, fbt_rate ON public.fringe_benefits
  FOR EACH ROW EXECUTE FUNCTION public.compute_fbt();

-- The payslip records benefits and their tax separately from salary,
-- because they are declared separately.
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS benefits_taxable numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS benefits_exempt numeric DEFAULT 0;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS fbt_amount numeric DEFAULT 0;

/** Benefits for one person in one month, for the payslip. */
DROP FUNCTION IF EXISTS public.benefits_for_period(uuid, text);
CREATE OR REPLACE FUNCTION public.benefits_for_period(p_employee_id uuid, p_period text)
 RETURNS TABLE (out_taxable numeric, out_exempt numeric, out_fbt numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(SUM(amount) FILTER (WHERE is_taxable), 0),
         COALESCE(SUM(amount) FILTER (WHERE NOT is_taxable), 0),
         COALESCE(SUM(fbt_amount), 0)
    FROM fringe_benefits
   WHERE employee_id = p_employee_id AND period = p_period;
$function$;
GRANT EXECUTE ON FUNCTION public.benefits_for_period(uuid, text) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.notice_period_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seniority_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fringe_benefits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View notice rules" ON public.notice_period_rules;
DROP POLICY IF EXISTS "Manage notice rules" ON public.notice_period_rules;
-- Staff may read the notice schedule: it is a term of their employment.
CREATE POLICY "View notice rules" ON public.notice_period_rules FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage notice rules" ON public.notice_period_rules FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Manager']));

DROP POLICY IF EXISTS "View seniority payouts" ON public.seniority_payouts;
DROP POLICY IF EXISTS "Manage seniority payouts" ON public.seniority_payouts;
-- Everyone may see their own; payroll sees them all.
CREATE POLICY "View seniority payouts" ON public.seniority_payouts FOR SELECT TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager'])
      OR employee_id IN (SELECT id FROM employees WHERE user_id = auth.uid()));
CREATE POLICY "Manage seniority payouts" ON public.seniority_payouts FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']))
  WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']));

DROP POLICY IF EXISTS "View fringe benefits" ON public.fringe_benefits;
DROP POLICY IF EXISTS "Manage fringe benefits" ON public.fringe_benefits;
CREATE POLICY "View fringe benefits" ON public.fringe_benefits FOR SELECT TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager'])
      OR employee_id IN (SELECT id FROM employees WHERE user_id = auth.uid()));
CREATE POLICY "Manage fringe benefits" ON public.fringe_benefits FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']))
  WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']));
