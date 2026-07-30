-- =====================================================================
-- KAREYA SILO — PAYSLIP AND RECEIPT INTEGRITY (payroll-pos-integrity)
-- ---------------------------------------------------------------------
-- Two tables, one problem: both hold a document that has already been
-- handed to somebody — a payslip to an employee, a receipt to a customer —
-- and both let you change it afterwards.
--
--  1. A PAID PAYSLIP WAS EDITABLE. RLS granted Accountant FOR ALL, so the
--     gross, the tax or the net could be changed after the employee was
--     paid and after the month's return was filed, and deleted outright.
--     Nothing recorded who marked it paid or when. Paid is now terminal:
--     the figures freeze, the row cannot be deleted, and a mistake is
--     voided with a reason rather than quietly rewritten.
--
--     Nothing stopped a second payslip for the same person and the same
--     month either, so somebody could be paid twice for March with both
--     rows looking perfectly ordinary.
--
--  2. THE RECEIPT NUMBER CAME FROM A BROWSER CLOCK. `POS-` plus the last
--     six digits of Date.now(), with no unique index — two tills a
--     millisecond apart could print the same number on two customers'
--     receipts, and nothing would ever notice. Numbers are issued here,
--     gap-free, and a recorded sale is voided rather than deleted so the
--     number stays accounted for.
--
-- The period check reaches for accounting-integrity's period_is_closed()
-- at RUNTIME rather than at install time, so neither vertical depends on
-- the other's install order. Where it is absent the rule simply does not
-- apply yet.
--
-- Idempotent and order-independent. Depends on: payslips, pos_sales.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PAYSLIPS
-- ---------------------------------------------------------------------
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS paid_at     timestamp with time zone;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS paid_by     uuid;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS void_reason text;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS voided_at   timestamp with time zone;
ALTER TABLE public.payslips ADD COLUMN IF NOT EXISTS voided_by   uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payslips_paid_by_fkey') THEN
    ALTER TABLE public.payslips ADD CONSTRAINT payslips_paid_by_fkey
      FOREIGN KEY (paid_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
  -- 'void' joins draft|paid: a payslip that was wrong is withdrawn with a
  -- reason, the same way an invoice is, rather than edited into shape.
  ALTER TABLE public.payslips DROP CONSTRAINT IF EXISTS payslips_status_check;
  ALTER TABLE public.payslips ADD CONSTRAINT payslips_status_check
    CHECK (status = ANY (ARRAY['draft', 'paid', 'void']));
END $$;

-- One payslip per person per month. Existing duplicates are left alone and
-- reported: deciding which of two payslips was the real one is a judgement
-- about somebody's pay, not something a migration should make.
DO $$
DECLARE v_dupes integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_payslip_employee_period') THEN
    SELECT count(*) INTO v_dupes FROM (
      SELECT employee_id, period FROM public.payslips
       WHERE status <> 'void'
       GROUP BY employee_id, period HAVING count(*) > 1) d;
    IF v_dupes > 0 THEN
      RAISE NOTICE '% employee/period pair(s) already have more than one payslip; the uniqueness index was not added. Void the ones that are not the real payslip.', v_dupes;
    ELSE
      CREATE UNIQUE INDEX uq_payslip_employee_period
        ON public.payslips (employee_id, period) WHERE status <> 'void';
    END IF;
  END IF;
END $$;

-- A paid payslip is what somebody was actually given. Only the fields that
-- record the payment or the withdrawal may still move.
CREATE OR REPLACE FUNCTION public.payslip_paid_is_final()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'draft' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'A payslip that has been paid cannot be deleted. Void it, with a reason.';
  END IF;

  IF OLD.status = 'draft' THEN RETURN NEW; END IF;

  IF NEW.gross IS DISTINCT FROM OLD.gross
     OR NEW.net IS DISTINCT FROM OLD.net
     OR NEW.tax IS DISTINCT FROM OLD.tax
     OR NEW.base_salary IS DISTINCT FROM OLD.base_salary
     OR NEW.allowances IS DISTINCT FROM OLD.allowances
     OR NEW.other_deductions IS DISTINCT FROM OLD.other_deductions
     OR NEW.nssf_employee IS DISTINCT FROM OLD.nssf_employee
     OR NEW.nssf_employer IS DISTINCT FROM OLD.nssf_employer
     OR NEW.period IS DISTINCT FROM OLD.period
     OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
     OR NEW.pay_date IS DISTINCT FROM OLD.pay_date THEN
    RAISE EXCEPTION 'This payslip has been paid. Its figures are what the employee was given — void it and issue a corrected one.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_payslip_paid_is_final ON public.payslips;
CREATE TRIGGER trg_payslip_paid_is_final
  BEFORE UPDATE OR DELETE ON public.payslips
  FOR EACH ROW EXECUTE FUNCTION public.payslip_paid_is_final();

-- Reaches for the accounting vertical's period rule if it is installed,
-- and says nothing if it is not. to_regprocedure() is resolved when the
-- function RUNS, so this file can be applied in any order.
CREATE OR REPLACE FUNCTION public.period_closed_if_known(p_date date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE v_closed boolean;
BEGIN
  IF to_regprocedure('public.period_is_closed(date)') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT public.period_is_closed($1)' INTO v_closed USING p_date;
  RETURN coalesce(v_closed, false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_payslip_paid(p_payslip_id uuid, p_pay_date date DEFAULT NULL)
 RETURNS public.payslips
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_slip payslips; v_date date;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('accountant', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an accountant may mark a payslip paid';
  END IF;

  SELECT * INTO v_slip FROM payslips WHERE id = p_payslip_id FOR UPDATE;
  IF v_slip.id IS NULL THEN RAISE EXCEPTION 'Payslip not found'; END IF;
  IF v_slip.status = 'paid' THEN RAISE EXCEPTION 'This payslip was already marked paid'; END IF;
  IF v_slip.status = 'void' THEN RAISE EXCEPTION 'This payslip was voided'; END IF;

  -- Nobody may pay themselves. The person who runs payroll is usually the
  -- person who would notice, which is exactly why they should not be able
  -- to close the loop on their own pay unnoticed.
  IF v_slip.employee_id = v_emp.id
     AND NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder')) THEN
    RAISE EXCEPTION 'You cannot mark your own payslip paid';
  END IF;

  v_date := coalesce(p_pay_date, v_slip.pay_date, CURRENT_DATE);
  IF period_closed_if_known(v_date) THEN
    RAISE EXCEPTION 'The books for % are closed. Pay it with a date in an open period.', to_char(v_date, 'YYYY-MM');
  END IF;

  UPDATE payslips
     SET status = 'paid', pay_date = v_date, paid_at = now(), paid_by = v_emp.id
   WHERE id = p_payslip_id
  RETURNING * INTO v_slip;

  RETURN v_slip;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_payslip_paid(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.void_payslip(p_payslip_id uuid, p_reason text)
 RETURNS public.payslips
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_slip payslips;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an administrator may void a payslip';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a payslip requires a reason';
  END IF;

  SELECT * INTO v_slip FROM payslips WHERE id = p_payslip_id FOR UPDATE;
  IF v_slip.id IS NULL THEN RAISE EXCEPTION 'Payslip not found'; END IF;
  IF v_slip.status = 'void' THEN RAISE EXCEPTION 'This payslip is already void'; END IF;

  -- The pay it recorded is in the ledger. Leaving that entry standing while
  -- withdrawing the payslip would put the books and the payroll at odds.
  -- A reversal carries the same source as what it reverses, so it has to
  -- be excluded here or the correction would look like the problem.
  IF v_slip.status = 'paid' AND EXISTS (
    SELECT 1 FROM journal_entries j
     WHERE j.source_type = 'payroll' AND j.source_id = p_payslip_id
       AND j.reverses_entry_id IS NULL
       AND j.reversed_by_entry_id IS NULL
  ) THEN
    RAISE EXCEPTION 'The payroll entry for this payslip is still in the books. Reverse it first, then void the payslip.';
  END IF;

  UPDATE payslips
     SET status = 'void', void_reason = p_reason, voided_at = now(), voided_by = v_emp.id
   WHERE id = p_payslip_id
  RETURNING * INTO v_slip;

  RETURN v_slip;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.void_payslip(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. TILL RECEIPTS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pos_receipt_series (
  id           boolean DEFAULT true NOT NULL,
  prefix       text DEFAULT 'POS-',
  width        integer DEFAULT 6,
  reset_daily  boolean DEFAULT false,
  period       text,                       -- the day or year the counter is on
  last_no      bigint DEFAULT 0,
  CONSTRAINT pos_receipt_series_pkey PRIMARY KEY (id),
  CONSTRAINT pos_receipt_series_singleton CHECK (id = true)
);

INSERT INTO public.pos_receipt_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_pos_receipt_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_s pos_receipt_series; v_period text; v_no bigint;
BEGIN
  -- Two tills ringing up at the same moment must not be handed the same
  -- number. This is the lock the browser clock never had.
  PERFORM pg_advisory_xact_lock(hashtext('pos_receipt_series'));

  SELECT * INTO v_s FROM pos_receipt_series WHERE id;
  IF v_s.id IS NULL THEN
    INSERT INTO pos_receipt_series (id) VALUES (true) RETURNING * INTO v_s;
  END IF;

  v_period := CASE WHEN v_s.reset_daily THEN to_char(p_on, 'YYYYMMDD') ELSE to_char(p_on, 'YYYY') END;

  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE pos_receipt_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE pos_receipt_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;

  RETURN coalesce(v_s.prefix, 'POS-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 6), 1), '0');
END;
$function$;

-- Whatever the client sends is ignored. A receipt number a browser can
-- choose is a receipt number two browsers can choose the same.
CREATE OR REPLACE FUNCTION public.pos_sale_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.sale_number := allocate_pos_receipt_no(coalesce(NEW.created_at::date, CURRENT_DATE));
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pos_sale_number ON public.pos_sales;
CREATE TRIGGER trg_pos_sale_number
  BEFORE INSERT ON public.pos_sales
  FOR EACH ROW EXECUTE FUNCTION public.pos_sale_number();

ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS voided      boolean DEFAULT false;
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS void_reason text;
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS voided_at   timestamp with time zone;
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS voided_by   uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pos_sales_voided_by_fkey') THEN
    ALTER TABLE public.pos_sales ADD CONSTRAINT pos_sales_voided_by_fkey
      FOREIGN KEY (voided_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pos_sales_void_reason_check') THEN
    ALTER TABLE public.pos_sales ADD CONSTRAINT pos_sales_void_reason_check
      CHECK (voided = false OR coalesce(trim(void_reason), '') <> '');
  END IF;
END $$;

-- Old numbers came from a millisecond clock with nothing stopping two
-- being identical. Give any duplicate a distinguishing suffix before the
-- unique index goes on, rather than leaving the whole vertical unapplied.
DO $$
DECLARE r record; s record; n integer;
BEGIN
  FOR r IN
    SELECT sale_number FROM public.pos_sales
     WHERE sale_number IS NOT NULL
     GROUP BY sale_number HAVING count(*) > 1
  LOOP
    n := 0;
    FOR s IN SELECT id FROM public.pos_sales WHERE sale_number = r.sale_number ORDER BY created_at LOOP
      n := n + 1;
      IF n > 1 THEN
        UPDATE public.pos_sales SET sale_number = sale_number || '-' || n WHERE id = s.id;
      END IF;
    END LOOP;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pos_sales_number ON public.pos_sales (sale_number);

CREATE OR REPLACE FUNCTION public.pos_sale_is_final()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Receipt % has been given to a customer and cannot be deleted. Void it, so its number stays accounted for.', OLD.sale_number;
  END IF;
  IF NEW.sale_number IS DISTINCT FROM OLD.sale_number
     OR NEW.total IS DISTINCT FROM OLD.total
     OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
     OR NEW.tax_amount IS DISTINCT FROM OLD.tax_amount
     OR NEW.items IS DISTINCT FROM OLD.items THEN
    RAISE EXCEPTION 'Receipt % cannot be edited. Void it and ring the sale up again.', OLD.sale_number;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pos_sale_is_final ON public.pos_sales;
CREATE TRIGGER trg_pos_sale_is_final
  BEFORE UPDATE OR DELETE ON public.pos_sales
  FOR EACH ROW EXECUTE FUNCTION public.pos_sale_is_final();

CREATE OR REPLACE FUNCTION public.void_pos_sale(p_sale_id uuid, p_reason text)
 RETURNS public.pos_sales
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_sale pos_sales;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('manager', 'accountant', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'A cashier cannot void their own till. Ask a manager.';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a receipt requires a reason';
  END IF;

  SELECT * INTO v_sale FROM pos_sales WHERE id = p_sale_id FOR UPDATE;
  IF v_sale.id IS NULL THEN RAISE EXCEPTION 'Receipt not found'; END IF;
  IF coalesce(v_sale.voided, false) THEN RAISE EXCEPTION 'Receipt % is already void', v_sale.sale_number; END IF;

  UPDATE pos_sales
     SET voided = true, void_reason = p_reason, voided_at = now(), voided_by = v_emp.id
   WHERE id = p_sale_id
  RETURNING * INTO v_sale;

  RETURN v_sale;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.void_pos_sale(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- Ringing up a sale and drafting a payslip stay ordinary writes; the
-- triggers make them correct. What is closed is changing one afterwards.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Manage pos sales" ON public.pos_sales;
DROP POLICY IF EXISTS "Manage payslips" ON public.payslips;

DROP POLICY IF EXISTS payslips_draft ON public.payslips;
CREATE POLICY payslips_draft ON public.payslips
  FOR INSERT TO authenticated
  WITH CHECK (public.has_any_role(ARRAY['Accountant']));

-- Editing is allowed by policy and then narrowed by the trigger to drafts
-- only, so an accountant can still fix a payslip before anybody is paid.
DROP POLICY IF EXISTS payslips_edit_draft ON public.payslips;
CREATE POLICY payslips_edit_draft ON public.payslips
  FOR UPDATE TO authenticated
  USING (public.has_any_role(ARRAY['Accountant']))
  WITH CHECK (public.has_any_role(ARRAY['Accountant']));

DROP POLICY IF EXISTS payslips_delete_draft ON public.payslips;
CREATE POLICY payslips_delete_draft ON public.payslips
  FOR DELETE TO authenticated
  USING (public.has_any_role(ARRAY['Accountant']));

DROP POLICY IF EXISTS pos_receipt_series_read ON public.pos_receipt_series;
ALTER TABLE public.pos_receipt_series ENABLE ROW LEVEL SECURITY;
CREATE POLICY pos_receipt_series_read ON public.pos_receipt_series
  FOR SELECT TO authenticated USING (public.is_employee());
DROP POLICY IF EXISTS pos_receipt_series_write ON public.pos_receipt_series;
CREATE POLICY pos_receipt_series_write ON public.pos_receipt_series
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_founder()) WITH CHECK (public.is_admin_or_founder());
