-- =====================================================================
-- KAREYA SILO — LENDING INTEGRITY (lending-integrity)
-- ---------------------------------------------------------------------
-- Money lent to somebody, and the interest they owe on it, were both
-- worked out in a browser.
--
--  1. THE AMORTISATION SCHEDULE WAS BUILT CLIENT-SIDE and inserted as
--     rows. That schedule IS the contract — it is what the borrower signs
--     and what they are held to — and a modified client could insert any
--     schedule it liked. Nothing on the server ever checked that the rows
--     were the rows the stated principal, rate, term and method produce.
--     build_loan_schedule() computes it here, disburse_loan() writes it in
--     one transaction, and the schedule cannot be edited afterwards.
--
--  2. A REPAYMENT WAS ALLOCATED FROM REACT STATE. recordRepayment read
--     each installment's paid_amount out of the browser, waterfalled the
--     money across them, and fired the updates off in parallel. Two clerks
--     taking payments on one loan at the same moment both read the same
--     figures and both wrote — so a borrower could pay twice and be
--     credited once. If some of those parallel updates failed, the
--     repayment was recorded and the schedule was not, with nothing
--     reconciling the two ever again.
--
--  3. PAWN INTEREST WAS COMPUTED IN THE BROWSER at the counter, so the
--     amount a customer handed over to get their gold back was a number
--     the client decided. It is computed here now, from the ticket.
--
--  4. LOAN NUMBERS CAME FROM A CLOCK — `L-` plus six digits of Date.now(),
--     with no unique index. Two loans could carry one number.
--
-- What is deliberately NOT here: any interest rate, fee or cap. Those are
-- the lender's, set by their own licence and contract, and this file does
-- not know what they are allowed to charge.
--
-- Idempotent and order-independent. Depends on: loans, loan_schedule,
-- loan_repayments, pawn_tickets, pawn_transactions.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE SCHEDULE IS THE CONTRACT
-- ---------------------------------------------------------------------
ALTER TABLE public.loan_schedule ADD COLUMN IF NOT EXISTS generated boolean DEFAULT false;

-- A loan cannot have two installment number 3s. Existing duplicates are
-- reported rather than resolved: choosing which of two rows a borrower
-- actually owes is a decision about their debt, not a migration's.
DO $$
DECLARE v_dupes integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_loan_schedule_installment') THEN
    SELECT count(*) INTO v_dupes FROM (
      SELECT loan_id, installment_no FROM public.loan_schedule
       GROUP BY loan_id, installment_no HAVING count(*) > 1) d;
    IF v_dupes > 0 THEN
      RAISE NOTICE '% loan installment(s) are duplicated; the uniqueness index was not added. Check those schedules before relying on them.', v_dupes;
    ELSE
      CREATE UNIQUE INDEX uq_loan_schedule_installment
        ON public.loan_schedule (loan_id, installment_no);
    END IF;
  END IF;
END $$;

-- Flat = interest on the original principal, spread evenly.
-- Declining = a level instalment on the reducing balance, with the last
-- row absorbing the rounding so the figures add back to the principal.
-- Both mirror what the browser did, which is the point: the same numbers,
-- decided somewhere a borrower's client cannot reach.
DROP FUNCTION IF EXISTS public.build_loan_schedule(numeric, numeric, integer, text, date);
CREATE OR REPLACE FUNCTION public.build_loan_schedule(
  p_principal numeric, p_annual_rate_pct numeric, p_term_months integer,
  p_method text, p_start date)
 RETURNS TABLE (
   out_installment_no integer,
   out_due_date       date,
   out_principal_due  numeric,
   out_interest_due   numeric,
   out_total_due      numeric
 )
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_n     integer;
  v_i     integer;
  v_r     numeric;
  v_emi   numeric;
  v_bal   numeric;
  v_int   numeric;
  v_prin  numeric;
  v_total numeric;
BEGIN
  IF coalesce(p_principal, 0) <= 0 THEN RAISE EXCEPTION 'A loan needs a principal greater than zero'; END IF;
  IF coalesce(p_annual_rate_pct, 0) < 0 THEN RAISE EXCEPTION 'An interest rate cannot be negative'; END IF;
  IF p_method NOT IN ('flat', 'declining') THEN
    RAISE EXCEPTION 'Interest method must be flat or declining, not %', p_method;
  END IF;

  v_n := greatest(coalesce(p_term_months, 0), 1);

  IF p_method = 'flat' THEN
    v_total := round(p_principal * (p_annual_rate_pct / 100) * (v_n::numeric / 12), 2);
    FOR v_i IN 1 .. v_n LOOP
      v_prin := round(p_principal / v_n, 2);
      v_int  := round(v_total / v_n, 2);
      -- The last row carries whatever the rounding left over, so the
      -- schedule adds back to exactly the principal and interest agreed.
      IF v_i = v_n THEN
        v_prin := round(p_principal - (round(p_principal / v_n, 2) * (v_n - 1)), 2);
        v_int  := round(v_total     - (round(v_total     / v_n, 2) * (v_n - 1)), 2);
      END IF;
      out_installment_no := v_i;
      out_due_date       := (p_start + (v_i || ' months')::interval)::date;
      out_principal_due  := v_prin;
      out_interest_due   := v_int;
      out_total_due      := round(v_prin + v_int, 2);
      RETURN NEXT;
    END LOOP;
  ELSE
    v_r   := p_annual_rate_pct / 100 / 12;
    v_bal := p_principal;
    v_emi := CASE WHEN v_r = 0 THEN p_principal / v_n
                  ELSE (p_principal * v_r * power(1 + v_r, v_n)) / (power(1 + v_r, v_n) - 1) END;
    FOR v_i IN 1 .. v_n LOOP
      v_int  := round(v_bal * v_r, 2);
      v_prin := round(v_emi - v_int, 2);
      IF v_i = v_n THEN v_prin := round(v_bal, 2); END IF;
      v_bal  := round(v_bal - v_prin, 2);
      out_installment_no := v_i;
      out_due_date       := (p_start + (v_i || ' months')::interval)::date;
      out_principal_due  := v_prin;
      out_interest_due   := v_int;
      out_total_due      := round(v_prin + v_int, 2);
      RETURN NEXT;
    END LOOP;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.build_loan_schedule(numeric, numeric, integer, text, date) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. LOAN NUMBERS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.loan_number_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'L-',
  width   integer DEFAULT 6,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT loan_number_series_pkey PRIMARY KEY (id),
  CONSTRAINT loan_number_series_singleton CHECK (id = true)
);
INSERT INTO public.loan_number_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_loan_number(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_s loan_number_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('loan_number_series'));
  SELECT * INTO v_s FROM loan_number_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO loan_number_series (id) VALUES (true) RETURNING * INTO v_s; END IF;

  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE loan_number_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE loan_number_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;

  RETURN coalesce(v_s.prefix, 'L-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 6), 1), '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.loan_number_assign()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.loan_number := allocate_loan_number(CURRENT_DATE);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_loan_number_assign ON public.loans;
CREATE TRIGGER trg_loan_number_assign
  BEFORE INSERT ON public.loans
  FOR EACH ROW EXECUTE FUNCTION public.loan_number_assign();

DO $$
DECLARE r record; s record; n integer;
BEGIN
  FOR r IN SELECT loan_number FROM public.loans
            WHERE loan_number IS NOT NULL
            GROUP BY loan_number HAVING count(*) > 1 LOOP
    n := 0;
    FOR s IN SELECT id FROM public.loans WHERE loan_number = r.loan_number ORDER BY created_at LOOP
      n := n + 1;
      IF n > 1 THEN UPDATE public.loans SET loan_number = loan_number || '-' || n WHERE id = s.id; END IF;
    END LOOP;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_loans_number ON public.loans (loan_number) WHERE loan_number IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3. DISBURSEMENT
-- The schedule and the activation are one transaction. Before this they
-- were two round-trips, so a double-click could write the schedule twice
-- and a failure between them left a loan marked pending with a schedule
-- already against it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.disburse_loan(p_loan_id uuid, p_date date DEFAULT NULL)
 RETURNS public.loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_loan loans; v_start date;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('loan officer', 'accountant', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot disburse a loan';
  END IF;

  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status <> 'pending' THEN
    RAISE EXCEPTION 'Loan % is %, not pending', v_loan.loan_number, v_loan.status;
  END IF;
  IF EXISTS (SELECT 1 FROM loan_schedule WHERE loan_id = p_loan_id) THEN
    RAISE EXCEPTION 'Loan % already has a schedule', v_loan.loan_number;
  END IF;

  v_start := coalesce(p_date, CURRENT_DATE);

  INSERT INTO loan_schedule (loan_id, installment_no, due_date, principal_due, interest_due, total_due, status, generated)
  SELECT p_loan_id, out_installment_no, out_due_date, out_principal_due, out_interest_due, out_total_due, 'pending', true
    FROM build_loan_schedule(v_loan.principal, v_loan.interest_rate, v_loan.term_months,
                             coalesce(v_loan.method, 'declining'), v_start);

  UPDATE loans SET status = 'active', disbursed_date = v_start WHERE id = p_loan_id
  RETURNING * INTO v_loan;

  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.disburse_loan(uuid, date) TO authenticated;

-- The schedule a borrower signed is not something anybody edits later. The
-- only column that moves is what they have paid, and only the repayment
-- function moves it.
CREATE OR REPLACE FUNCTION public.loan_schedule_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'An installment cannot be deleted. It is part of the schedule the borrower agreed to.';
  END IF;
  IF NEW.principal_due IS DISTINCT FROM OLD.principal_due
     OR NEW.interest_due IS DISTINCT FROM OLD.interest_due
     OR NEW.total_due IS DISTINCT FROM OLD.total_due
     OR NEW.due_date IS DISTINCT FROM OLD.due_date
     OR NEW.installment_no IS DISTINCT FROM OLD.installment_no THEN
    RAISE EXCEPTION 'The amounts and dates on an installment are the contract and cannot be edited.';
  END IF;
  IF NEW.paid_amount IS DISTINCT FROM OLD.paid_amount
     AND coalesce(current_setting('kareya.loan_apply', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'What a borrower has paid is what the repayments add up to. Record a repayment.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_loan_schedule_guard ON public.loan_schedule;
CREATE TRIGGER trg_loan_schedule_guard
  BEFORE UPDATE OR DELETE ON public.loan_schedule
  FOR EACH ROW EXECUTE FUNCTION public.loan_schedule_guard();

-- ---------------------------------------------------------------------
-- 4. REPAYMENT
-- One transaction, under a lock on the loan, allocating from the
-- DATABASE's figures. Returns the principal/interest split so the caller
-- can post it — computed here rather than in the browser that asked.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.record_loan_repayment(uuid, numeric, text, date, text);
CREATE OR REPLACE FUNCTION public.record_loan_repayment(
  p_loan_id uuid, p_amount numeric, p_method text DEFAULT 'cash',
  p_date date DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS TABLE (
   out_repayment_id uuid,
   out_principal    numeric,
   out_interest     numeric,
   out_unallocated  numeric,
   out_loan_status  text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp   employees;
  v_loan  loans;
  v_row   loan_schedule;
  v_left  numeric;
  v_owed  numeric;
  v_pay   numeric;
  v_intol numeric;   -- interest still outstanding on this installment
  v_ip    numeric;
  v_prin  numeric := 0;
  v_int   numeric := 0;
  v_rep   uuid;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  IF coalesce(p_amount, 0) <= 0 THEN RAISE EXCEPTION 'A repayment must be more than zero'; END IF;

  -- The lock. Two clerks taking a payment on one loan at the same moment
  -- used to read the same installment figures and both write; a borrower
  -- could pay twice and be credited once.
  SELECT * INTO v_loan FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status NOT IN ('active', 'defaulted') THEN
    RAISE EXCEPTION 'Loan % is %, so it is not taking repayments', v_loan.loan_number, v_loan.status;
  END IF;

  v_left := round(p_amount, 2);

  PERFORM set_config('kareya.loan_apply', 'on', true);

  -- Oldest installment first; within one, interest before principal.
  FOR v_row IN
    SELECT * FROM loan_schedule WHERE loan_id = p_loan_id ORDER BY installment_no FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_owed := round(coalesce(v_row.total_due, 0) - coalesce(v_row.paid_amount, 0), 2);
    CONTINUE WHEN v_owed <= 0;

    v_pay   := least(v_owed, v_left);
    v_intol := greatest(round(coalesce(v_row.interest_due, 0) - least(coalesce(v_row.paid_amount, 0), coalesce(v_row.interest_due, 0)), 2), 0);
    v_ip    := least(v_pay, v_intol);

    v_int  := round(v_int + v_ip, 2);
    v_prin := round(v_prin + (v_pay - v_ip), 2);
    v_left := round(v_left - v_pay, 2);

    UPDATE loan_schedule
       SET paid_amount = round(coalesce(paid_amount, 0) + v_pay, 2),
           status = CASE WHEN round(coalesce(paid_amount, 0) + v_pay, 2)
                         >= round(coalesce(total_due, 0), 2) - 0.005 THEN 'paid' ELSE 'partial' END
     WHERE id = v_row.id;
  END LOOP;

  PERFORM set_config('kareya.loan_apply', 'off', true);

  -- Money beyond what the loan owes is reported back rather than absorbed.
  -- Quietly swallowing an overpayment is how a borrower ends up out of
  -- pocket with nothing on the record to point at.
  IF v_left > 0.005 THEN
    RAISE EXCEPTION 'That is % more than this loan still owes. Take the settlement amount, or record the extra separately.', v_left;
  END IF;

  INSERT INTO loan_repayments (loan_id, date, amount, method, received_by, note)
  VALUES (p_loan_id, coalesce(p_date, CURRENT_DATE), round(p_amount, 2),
          coalesce(p_method, 'cash'), v_emp.id, p_note)
  RETURNING id INTO v_rep;

  IF NOT EXISTS (SELECT 1 FROM loan_schedule WHERE loan_id = p_loan_id AND status <> 'paid') THEN
    UPDATE loans SET status = 'closed' WHERE id = p_loan_id;
  END IF;

  SELECT status INTO v_loan.status FROM loans WHERE id = p_loan_id;

  out_repayment_id := v_rep;
  out_principal    := v_prin;
  out_interest     := v_int;
  out_unallocated  := 0;
  out_loan_status  := v_loan.status;
  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.record_loan_repayment(uuid, numeric, text, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.loan_repayment_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'A repayment is a record of money a borrower handed over. It cannot be % — correct it with another entry.',
    CASE TG_OP WHEN 'DELETE' THEN 'deleted' ELSE 'edited' END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_loan_repayment_append_only ON public.loan_repayments;
CREATE TRIGGER trg_loan_repayment_append_only
  BEFORE UPDATE OR DELETE ON public.loan_repayments
  FOR EACH ROW EXECUTE FUNCTION public.loan_repayment_append_only();

-- ---------------------------------------------------------------------
-- 5. PAWN INTEREST
-- What a customer hands over to get their gold back is worked out here.
-- Flat monthly interest on the outstanding principal — the same rule the
-- browser applied, decided somewhere the counter cannot reach.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pawn_accrued_interest(p_ticket_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE v_t pawn_tickets; v_months integer; v_paid numeric;
BEGIN
  SELECT * INTO v_t FROM pawn_tickets WHERE id = p_ticket_id;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'Pawn ticket not found'; END IF;
  IF v_t.status <> 'active' THEN RETURN 0; END IF;

  -- Whole calendar months, minimum one: a pawn charges for the month it
  -- was written in even if it is redeemed the same week. That is the
  -- ordinary trade practice the module already followed.
  v_months := greatest(
    (date_part('year', age(coalesce(p_as_of, CURRENT_DATE), v_t.pawn_date)) * 12
     + date_part('month', age(coalesce(p_as_of, CURRENT_DATE), v_t.pawn_date)))::integer, 1);

  -- Interest already settled on this ticket reduces what is still owed.
  SELECT coalesce(sum(interest_portion), 0) INTO v_paid
    FROM pawn_transactions
   WHERE ticket_id = p_ticket_id AND type IN ('interest', 'renewal');

  RETURN greatest(round(coalesce(v_t.principal, 0) * (coalesce(v_t.interest_rate, 0) / 100) * v_months - v_paid, 2), 0);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.pawn_accrued_interest(uuid, date) TO authenticated;

DROP FUNCTION IF EXISTS public.redeem_pawn_ticket(uuid, date, text);
CREATE OR REPLACE FUNCTION public.redeem_pawn_ticket(
  p_ticket_id uuid, p_date date DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS TABLE (out_principal numeric, out_interest numeric, out_total numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_t pawn_tickets; v_int numeric; v_date date;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  SELECT * INTO v_t FROM pawn_tickets WHERE id = p_ticket_id FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'Pawn ticket not found'; END IF;
  IF v_t.status <> 'active' THEN
    RAISE EXCEPTION 'Ticket % is %, so there is nothing to redeem', coalesce(v_t.ticket_number, v_t.id::text), v_t.status;
  END IF;

  v_date := coalesce(p_date, CURRENT_DATE);
  v_int  := pawn_accrued_interest(p_ticket_id, v_date);

  INSERT INTO pawn_transactions (ticket_id, date, type, amount, principal_portion, interest_portion, received_by, note)
  VALUES (p_ticket_id, v_date, 'redemption', round(coalesce(v_t.principal, 0) + v_int, 2),
          round(coalesce(v_t.principal, 0), 2), v_int, v_emp.id, p_note);

  UPDATE pawn_tickets SET status = 'redeemed', redeemed_date = v_date WHERE id = p_ticket_id;
  UPDATE pawn_items   SET status = 'returned' WHERE ticket_id = p_ticket_id AND status = 'in_custody';

  out_principal := round(coalesce(v_t.principal, 0), 2);
  out_interest  := v_int;
  out_total     := round(coalesce(v_t.principal, 0) + v_int, 2);
  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.redeem_pawn_ticket(uuid, date, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. WHERE THE FIGURES DISAGREE
-- The triggers stop new drift; this names what a Silo accumulated while
-- repayments were allocated by a browser firing parallel updates.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.loan_reconciliation();
CREATE OR REPLACE FUNCTION public.loan_reconciliation()
 RETURNS TABLE (
   out_loan_id       uuid,
   out_loan_number   text,
   out_repaid        numeric,
   out_allocated     numeric,
   out_difference    numeric,
   out_problem       text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT l.id, l.loan_number,
         coalesce(r.total, 0), coalesce(s.total, 0),
         round(coalesce(r.total, 0) - coalesce(s.total, 0), 2),
         CASE WHEN coalesce(r.total, 0) > coalesce(s.total, 0)
              THEN 'The borrower has paid more than the schedule has been credited'
              ELSE 'The schedule has been credited more than the borrower has paid' END
    FROM loans l
    LEFT JOIN (SELECT loan_id, sum(amount) total FROM loan_repayments GROUP BY loan_id) r ON r.loan_id = l.id
    LEFT JOIN (SELECT loan_id, sum(paid_amount) total FROM loan_schedule GROUP BY loan_id) s ON s.loan_id = l.id
   WHERE l.status <> 'pending'
     AND round(coalesce(r.total, 0), 2) <> round(coalesce(s.total, 0), 2)
   ORDER BY abs(coalesce(r.total, 0) - coalesce(s.total, 0)) DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.loan_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- Writing a loan application and a pawn ticket stay ordinary; what is
-- closed is editing a schedule, a repayment or a ticket after the fact.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Manage loan schedule" ON public.loan_schedule;
DROP POLICY IF EXISTS "Manage loan repayments" ON public.loan_repayments;

DROP POLICY IF EXISTS loan_repayments_add ON public.loan_repayments;
CREATE POLICY loan_repayments_add ON public.loan_repayments
  FOR INSERT TO authenticated
  WITH CHECK (public.has_any_role(ARRAY['Loan Officer', 'Accountant', 'Manager']));

-- The schedule is written by disburse_loan() (SECURITY DEFINER) and moved
-- by record_loan_repayment(). No client policy grants either.
