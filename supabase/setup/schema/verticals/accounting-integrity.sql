-- =====================================================================
-- KAREYA SILO — ACCOUNTING INTEGRITY (accounting-integrity)
-- ---------------------------------------------------------------------
-- post_journal() refuses an unbalanced entry. That is a check at the DOOR,
-- and until now it was the only one. Four things followed from that, and
-- each of them is the kind of problem an auditor finds rather than a user:
--
--  1. THE BALANCE WAS NOT AN INVARIANT. RLS granted Accountant FOR ALL on
--     journal_entries AND journal_lines, so one line's debit could be
--     edited, or a line deleted, and the entry post_journal had just
--     balanced no longer balanced. Nothing would ever say so. Lines are
--     now immutable, and a DEFERRABLE constraint trigger re-checks the
--     balance at commit, so it holds no matter who inserted what.
--
--  2. THERE WAS NO WAY TO CORRECT AN ENTRY EXCEPT TO CHANGE IT. Correcting
--     the books by editing them destroys the record of what was originally
--     posted. reverse_journal() posts the mirror entry and links the two.
--
--  3. NOTHING STOPPED POSTING INTO A MONTH ALREADY REPORTED. The GDT
--     return generator produces a VAT/TOI return from this ledger; a
--     journal dated in March could be posted in June and the filed return
--     would silently no longer match the books. Periods can now be closed,
--     and post_journal refuses a date inside a closed one.
--
--  4. THE BOOKS COULD SILENTLY DIVERGE FROM THE BUSINESS. The frontend
--     saved the invoice/sale/payslip FIRST and then posted the journal,
--     ignoring the result — postJournal() even returned false without a
--     word when the chart of accounts was not seeded. So a shop could run
--     for a month with sales on screen and an empty ledger and nothing
--     anywhere would mention it. unposted_documents() names exactly what
--     exists operationally and is not in the books, and a period cannot be
--     closed while anything is on that list.
--
-- Periods are calendar months ('YYYY-MM'). The invoice series already
-- keys off a fiscal year for GDT numbering; that is a different thing and
-- is deliberately left alone.
--
-- Idempotent and order-independent. Depends on: journal_entries,
-- journal_lines, invoices, bills, payments, pos_sales, payslips.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PERIODS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.accounting_periods (
  period        text NOT NULL,                 -- 'YYYY-MM'
  status        text DEFAULT 'open',           -- open | closed
  closed_at     timestamp with time zone,
  closed_by     uuid,
  closed_note   text,
  -- What the books said at the moment it was closed. If the period is ever
  -- reopened, this is how anybody can tell whether the figures moved after
  -- a return was filed against them.
  closed_debit  numeric,
  closed_credit numeric,
  reopened_at   timestamp with time zone,
  reopened_by   uuid,
  reopen_reason text,
  CONSTRAINT accounting_periods_pkey PRIMARY KEY (period),
  CONSTRAINT accounting_periods_status_check CHECK (status = ANY (ARRAY['open', 'closed'])),
  CONSTRAINT accounting_periods_format_check CHECK (period ~ '^[0-9]{4}-[0-9]{2}$')
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'accounting_periods_closed_by_fkey') THEN
    ALTER TABLE public.accounting_periods
      ADD CONSTRAINT accounting_periods_closed_by_fkey
      FOREIGN KEY (closed_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'accounting_periods_reopened_by_fkey') THEN
    ALTER TABLE public.accounting_periods
      ADD CONSTRAINT accounting_periods_reopened_by_fkey
      FOREIGN KEY (reopened_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.period_of(p_date date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$ SELECT to_char(p_date, 'YYYY-MM'); $function$;

-- A period nobody has closed is open. Absence of a row means open, so a
-- fresh workspace does not have to seed twelve rows a year to post at all.
CREATE OR REPLACE FUNCTION public.period_is_closed(p_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM accounting_periods
                  WHERE period = period_of(p_date) AND status = 'closed');
$function$;

-- ---------------------------------------------------------------------
-- 2. THE LEDGER IS APPEND-ONLY
-- A posted entry is a record of what was posted. Changing it destroys the
-- only evidence of what the books said before, which is the one thing an
-- audit trail exists to keep.
-- ---------------------------------------------------------------------
ALTER TABLE public.journal_entries ADD COLUMN IF NOT EXISTS reverses_entry_id    uuid;
ALTER TABLE public.journal_entries ADD COLUMN IF NOT EXISTS reversed_by_entry_id uuid;
ALTER TABLE public.journal_entries ADD COLUMN IF NOT EXISTS reversal_reason      text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'journal_entries_reverses_fkey') THEN
    ALTER TABLE public.journal_entries
      ADD CONSTRAINT journal_entries_reverses_fkey
      FOREIGN KEY (reverses_entry_id) REFERENCES public.journal_entries(id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'journal_entries_reversed_by_fkey') THEN
    ALTER TABLE public.journal_entries
      ADD CONSTRAINT journal_entries_reversed_by_fkey
      FOREIGN KEY (reversed_by_entry_id) REFERENCES public.journal_entries(id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_journal_entries_source ON public.journal_entries (source_type, source_id);

CREATE OR REPLACE FUNCTION public.journal_is_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A posted journal entry cannot be deleted. Reverse it instead, so both the original and the correction stay on the record.';
  END IF;
  -- Linking a reversal, and nothing else, may touch a posted entry.
  IF TG_TABLE_NAME = 'journal_entries' THEN
    IF NEW.date IS DISTINCT FROM OLD.date
       OR NEW.memo IS DISTINCT FROM OLD.memo
       OR NEW.reference IS DISTINCT FROM OLD.reference
       OR NEW.source_type IS DISTINCT FROM OLD.source_type
       OR NEW.source_id IS DISTINCT FROM OLD.source_id THEN
      RAISE EXCEPTION 'A posted journal entry cannot be edited. Reverse it and post the correct entry.';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'A posted journal line cannot be edited. Reverse the entry and post the correct one.';
END;
$function$;

DROP TRIGGER IF EXISTS trg_journal_entries_append_only ON public.journal_entries;
CREATE TRIGGER trg_journal_entries_append_only
  BEFORE UPDATE OR DELETE ON public.journal_entries
  FOR EACH ROW EXECUTE FUNCTION public.journal_is_append_only();

DROP TRIGGER IF EXISTS trg_journal_lines_append_only ON public.journal_lines;
CREATE TRIGGER trg_journal_lines_append_only
  BEFORE UPDATE OR DELETE ON public.journal_lines
  FOR EACH ROW EXECUTE FUNCTION public.journal_is_append_only();

-- Balance as an invariant rather than a door check. DEFERRABLE because
-- post_journal inserts the lines one at a time — every intermediate state
-- is unbalanced, and only the state at COMMIT is the entry.
CREATE OR REPLACE FUNCTION public.journal_entry_must_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_d numeric; v_c numeric;
BEGIN
  -- The entry may itself have been removed in the same transaction (the
  -- ON DELETE CASCADE path); nothing to check then.
  IF NOT EXISTS (SELECT 1 FROM journal_entries WHERE id = NEW.entry_id) THEN RETURN NULL; END IF;

  SELECT coalesce(sum(debit), 0), coalesce(sum(credit), 0) INTO v_d, v_c
    FROM journal_lines WHERE entry_id = NEW.entry_id;

  IF round(v_d, 2) <> round(v_c, 2) THEN
    RAISE EXCEPTION 'Journal entry % does not balance: debits % against credits %',
      NEW.entry_id, round(v_d, 2), round(v_c, 2);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_journal_lines_balance ON public.journal_lines;
CREATE CONSTRAINT TRIGGER trg_journal_lines_balance
  AFTER INSERT ON public.journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.journal_entry_must_balance();

-- Read-only from every client. post_journal() and reverse_journal() are
-- SECURITY DEFINER and are the only way anything reaches these tables.
DROP POLICY IF EXISTS "Manage journal" ON public.journal_entries;
DROP POLICY IF EXISTS "Manage journal lines" ON public.journal_lines;

-- ---------------------------------------------------------------------
-- 3. POSTING
-- Same signature as before, so every existing seam keeps working. What it
-- now refuses: a closed period, and posting the same business document
-- twice.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_journal(
  p_date date,
  p_memo text,
  p_reference text,
  p_source_type text,
  p_source_id uuid,
  p_lines jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry_id uuid;
  v_debit numeric;
  v_credit numeric;
  v_line jsonb;
  v_date date;
  v_dup text;
BEGIN
  v_date := coalesce(p_date, CURRENT_DATE);

  IF period_is_closed(v_date) THEN
    RAISE EXCEPTION 'Period % is closed. Post the entry in an open period, or reopen % first — reopening is recorded.',
      period_of(v_date), period_of(v_date);
  END IF;

  SELECT COALESCE(SUM((l->>'debit')::numeric), 0), COALESCE(SUM((l->>'credit')::numeric), 0)
    INTO v_debit, v_credit
  FROM jsonb_array_elements(p_lines) AS l;

  IF round(v_debit, 2) <> round(v_credit, 2) THEN
    RAISE EXCEPTION 'Unbalanced journal: debits % <> credits %', v_debit, v_credit;
  END IF;
  IF v_debit = 0 THEN
    RAISE EXCEPTION 'Journal entry has no amounts';
  END IF;

  -- One business document, one entry. Clicking Save twice used to put the
  -- same invoice in the books twice, and nothing downstream could tell.
  IF p_source_id IS NOT NULL AND coalesce(p_source_type, 'manual') <> 'manual' THEN
    SELECT id::text INTO v_dup FROM journal_entries
     WHERE source_type = p_source_type AND source_id = p_source_id
       AND reverses_entry_id IS NULL
     LIMIT 1;
    IF v_dup IS NOT NULL THEN
      RAISE EXCEPTION 'This % is already in the books (entry %). Reverse that entry before posting it again.',
        p_source_type, v_dup;
    END IF;
  END IF;

  INSERT INTO public.journal_entries (date, memo, reference, source_type, source_id, created_by)
  VALUES (v_date, p_memo, p_reference, COALESCE(p_source_type, 'manual'), p_source_id, auth.uid())
  RETURNING id INTO v_entry_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    INSERT INTO public.journal_lines (entry_id, account_id, debit, credit, description)
    VALUES (
      v_entry_id,
      (v_line->>'account_id')::uuid,
      COALESCE((v_line->>'debit')::numeric, 0),
      COALESCE((v_line->>'credit')::numeric, 0),
      v_line->>'description'
    );
  END LOOP;

  RETURN v_entry_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.post_journal(date, text, text, text, uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. REVERSAL
-- The correction is dated in an OPEN period, never back inside a closed
-- one: that is what makes a closed month stay the month that was filed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_journal(p_entry_id uuid, p_date date DEFAULT NULL, p_reason text DEFAULT '')
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_orig   journal_entries;
  v_new    uuid;
  v_date   date;
  v_line   journal_lines;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('accountant', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an accountant may reverse a journal entry';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Reversing an entry requires a reason';
  END IF;

  SELECT * INTO v_orig FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
  IF v_orig.id IS NULL THEN RAISE EXCEPTION 'Journal entry not found'; END IF;
  IF v_orig.reversed_by_entry_id IS NOT NULL THEN
    RAISE EXCEPTION 'This entry was already reversed by entry %', v_orig.reversed_by_entry_id;
  END IF;
  IF v_orig.reverses_entry_id IS NOT NULL THEN
    RAISE EXCEPTION 'This entry is itself a reversal. Post a fresh entry instead of reversing a reversal.';
  END IF;

  v_date := coalesce(p_date, CURRENT_DATE);
  IF period_is_closed(v_date) THEN
    RAISE EXCEPTION 'Period % is closed — date the correction in an open period.', period_of(v_date);
  END IF;

  INSERT INTO journal_entries (date, memo, reference, source_type, source_id,
                               created_by, reverses_entry_id, reversal_reason)
  VALUES (v_date,
          'Reversal of ' || coalesce(v_orig.memo, v_orig.id::text),
          v_orig.reference, v_orig.source_type, v_orig.source_id,
          auth.uid(), v_orig.id, p_reason)
  RETURNING id INTO v_new;

  -- Debits become credits and credits become debits, line for line, so the
  -- two entries net to nothing on every account they touched.
  FOR v_line IN SELECT * FROM journal_lines WHERE entry_id = p_entry_id LOOP
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, description)
    VALUES (v_new, v_line.account_id, v_line.credit, v_line.debit,
            'Reversal: ' || coalesce(v_line.description, ''));
  END LOOP;

  UPDATE journal_entries SET reversed_by_entry_id = v_new WHERE id = p_entry_id;
  RETURN v_new;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reverse_journal(uuid, date, text) TO authenticated;

-- A voided invoice is not missing from the books, it was withdrawn. The
-- column belongs to the GDT invoice vertical, which sorts AFTER this file
-- alphabetically — so it is declared here too, minimally and idempotently.
-- Whichever vertical installs first wins and the other no-ops, which is
-- what keeps the two independent of install order.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS voided boolean DEFAULT false;

-- ---------------------------------------------------------------------
-- 5. WHAT IS NOT IN THE BOOKS
-- The frontend saves the business document first and posts the journal
-- afterwards. When the posting fails — no chart of accounts, a closed
-- period, a network drop — the document is already saved and, until now,
-- nothing anywhere said the ledger had missed it.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.unposted_documents(date, date);
CREATE OR REPLACE FUNCTION public.unposted_documents(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
 RETURNS TABLE (
   out_kind      text,
   out_id        uuid,
   out_reference text,
   out_date      date,
   out_amount    numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT 'invoice', i.id, coalesce(i.invoice_number, i.id::text), i.date, i.amount
    FROM invoices i
   WHERE coalesce(i.voided, false) = false
     AND (p_from IS NULL OR i.date >= p_from) AND (p_to IS NULL OR i.date <= p_to)
     AND NOT EXISTS (SELECT 1 FROM journal_entries j
                      WHERE j.source_type = 'invoice' AND j.source_id = i.id)
  UNION ALL
  SELECT 'bill', b.id, coalesce(b.bill_number, b.id::text), b.date, b.amount
    FROM bills b
   WHERE (p_from IS NULL OR b.date >= p_from) AND (p_to IS NULL OR b.date <= p_to)
     AND NOT EXISTS (SELECT 1 FROM journal_entries j
                      WHERE j.source_type = 'bill' AND j.source_id = b.id)
  UNION ALL
  SELECT 'payment', p.id, p.id::text, p.date, p.amount
    FROM payments p
   WHERE (p_from IS NULL OR p.date >= p_from) AND (p_to IS NULL OR p.date <= p_to)
     AND NOT EXISTS (SELECT 1 FROM journal_entries j
                      WHERE j.source_type = 'payment' AND j.source_id = p.id)
  UNION ALL
  -- POS sales post under 'invoice', which is why the source id is what is
  -- matched here rather than the source type.
  SELECT 'pos_sale', s.id, coalesce(s.sale_number, s.id::text), s.created_at::date, s.total
    FROM pos_sales s
   WHERE (p_from IS NULL OR s.created_at::date >= p_from) AND (p_to IS NULL OR s.created_at::date <= p_to)
     AND NOT EXISTS (SELECT 1 FROM journal_entries j WHERE j.source_id = s.id)
  UNION ALL
  SELECT 'payslip', ps.id, ps.id::text, coalesce(ps.pay_date, ps.created_at::date), ps.net
    FROM payslips ps
   WHERE ps.status = 'paid'
     AND (p_from IS NULL OR coalesce(ps.pay_date, ps.created_at::date) >= p_from)
     AND (p_to   IS NULL OR coalesce(ps.pay_date, ps.created_at::date) <= p_to)
     AND NOT EXISTS (SELECT 1 FROM journal_entries j WHERE j.source_id = ps.id)
  ORDER BY 4 DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.unposted_documents(date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. CLOSING AND REOPENING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_accounting_period(p_period text, p_note text DEFAULT '')
 RETURNS public.accounting_periods
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_from   date;
  v_to     date;
  v_d      numeric;
  v_c      numeric;
  v_missing integer;
  v_row    accounting_periods;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('accountant', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an accountant may close a period';
  END IF;

  IF p_period !~ '^[0-9]{4}-[0-9]{2}$' THEN
    RAISE EXCEPTION 'A period is written YYYY-MM, for example 2026-03';
  END IF;

  v_from := to_date(p_period || '-01', 'YYYY-MM-DD');
  v_to   := (v_from + interval '1 month - 1 day')::date;

  IF v_from > CURRENT_DATE THEN
    RAISE EXCEPTION 'Period % has not happened yet', p_period;
  END IF;

  IF EXISTS (SELECT 1 FROM accounting_periods WHERE period = p_period AND status = 'closed') THEN
    RAISE EXCEPTION 'Period % is already closed', p_period;
  END IF;

  -- An earlier period left open would let somebody post into it after this
  -- one is filed, which defeats the point of closing anything.
  IF EXISTS (
    SELECT 1 FROM journal_entries j
     WHERE j.date < v_from AND NOT period_is_closed(j.date)
  ) THEN
    RAISE EXCEPTION 'An earlier period is still open. Close periods in order, oldest first.';
  END IF;

  -- Nothing may be sitting on a screen and missing from the books.
  SELECT count(*) INTO v_missing FROM unposted_documents(v_from, v_to);
  IF v_missing > 0 THEN
    RAISE EXCEPTION '% document(s) dated in % are not in the books. Post or void them before closing.',
      v_missing, p_period;
  END IF;

  SELECT coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0) INTO v_d, v_c
    FROM journal_lines l JOIN journal_entries j ON j.id = l.entry_id
   WHERE j.date BETWEEN v_from AND v_to;

  IF round(v_d, 2) <> round(v_c, 2) THEN
    RAISE EXCEPTION 'The books for % do not balance (% against %). Do not close a period that does not add up.',
      p_period, round(v_d, 2), round(v_c, 2);
  END IF;

  INSERT INTO accounting_periods (period, status, closed_at, closed_by, closed_note, closed_debit, closed_credit)
  VALUES (p_period, 'closed', now(), v_emp.id, nullif(p_note, ''), v_d, v_c)
  ON CONFLICT (period) DO UPDATE SET
    status = 'closed', closed_at = now(), closed_by = v_emp.id,
    closed_note = nullif(p_note, ''), closed_debit = v_d, closed_credit = v_c
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.close_accounting_period(text, text) TO authenticated;

-- Reopening is allowed, because sometimes it genuinely has to be. It is
-- never quiet: it takes an administrator, it takes a reason, and the
-- totals as at closing stay on the row so anybody can see whether the
-- figures moved after a return was filed against them.
CREATE OR REPLACE FUNCTION public.reopen_accounting_period(p_period text, p_reason text)
 RETURNS public.accounting_periods
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_row accounting_periods;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an administrator may reopen a closed period';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Reopening a closed period requires a reason';
  END IF;

  SELECT * INTO v_row FROM accounting_periods WHERE period = p_period FOR UPDATE;
  IF v_row.period IS NULL OR v_row.status <> 'closed' THEN
    RAISE EXCEPTION 'Period % is not closed', p_period;
  END IF;

  -- Reopening the middle of a closed run would let an entry land before a
  -- period that is still closed, which is not a state anybody can explain.
  IF EXISTS (SELECT 1 FROM accounting_periods WHERE status = 'closed' AND period > p_period) THEN
    RAISE EXCEPTION 'A later period is closed. Reopen periods newest first.';
  END IF;

  UPDATE accounting_periods
     SET status = 'open', reopened_at = now(), reopened_by = v_emp.id, reopen_reason = p_reason
   WHERE period = p_period
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reopen_accounting_period(text, text) TO authenticated;

-- What each month looks like, ready to close or not. This is the screen an
-- accountant works from at month end.
DROP FUNCTION IF EXISTS public.period_status(integer);
CREATE OR REPLACE FUNCTION public.period_status(p_months integer DEFAULT 12)
 RETURNS TABLE (
   out_period    text,
   out_status    text,
   out_entries   bigint,
   out_debit     numeric,
   out_credit    numeric,
   out_unposted  bigint,
   out_closed_at timestamp with time zone,
   out_reopened  boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH months AS (
    SELECT to_char(d, 'YYYY-MM') AS period,
           d::date AS from_date,
           (d + interval '1 month - 1 day')::date AS to_date
      FROM generate_series(
             date_trunc('month', CURRENT_DATE) - ((greatest(coalesce(p_months, 12), 1) - 1) || ' months')::interval,
             date_trunc('month', CURRENT_DATE),
             interval '1 month') d
  )
  SELECT m.period,
         coalesce(ap.status, 'open'),
         (SELECT count(*) FROM journal_entries j WHERE j.date BETWEEN m.from_date AND m.to_date),
         (SELECT coalesce(sum(l.debit), 0) FROM journal_lines l
            JOIN journal_entries j ON j.id = l.entry_id
           WHERE j.date BETWEEN m.from_date AND m.to_date),
         (SELECT coalesce(sum(l.credit), 0) FROM journal_lines l
            JOIN journal_entries j ON j.id = l.entry_id
           WHERE j.date BETWEEN m.from_date AND m.to_date),
         (SELECT count(*) FROM unposted_documents(m.from_date, m.to_date)),
         ap.closed_at,
         (ap.reopened_at IS NOT NULL)
    FROM months m
    LEFT JOIN accounting_periods ap ON ap.period = m.period
   ORDER BY m.period DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.period_status(integer) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS accounting_periods_read ON public.accounting_periods;
CREATE POLICY accounting_periods_read ON public.accounting_periods
  FOR SELECT TO authenticated USING (public.is_employee());
-- No write policy at all: close_accounting_period() and
-- reopen_accounting_period() are the only ways a period changes state.
