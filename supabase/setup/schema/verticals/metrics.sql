-- =====================================================================
-- KAREYA SILO — BUSINESS METRICS: DEFINITIONS, TARGETS, SNAPSHOTS
-- ---------------------------------------------------------------------
-- Kareya already had KPIs about PEOPLE. `kpi_definitions` in the
-- evaluation vertical assembles what the modules recorded about a member
-- of staff so a performance review has evidence behind it.
--
-- It had nothing about the BUSINESS. The dashboard carried a handful of
-- hard-coded tiles — cash, revenue this month, receivables — with no
-- target, no trend, no history and nothing anybody could add to. So the
-- questions an owner actually asks every month had no home:
--
--   Are we ahead of where we said we would be?
--   Is the margin holding, or are we busier and no better off?
--   How long is our money sitting in somebody else's bank?
--
-- FOUR DECISIONS, EACH OF WHICH THIS FILE EXISTS TO ENFORCE:
--
-- 1. A METRIC IS COMPUTED, NEVER TYPED. Every definition carries the
--    SELECT that works it out from the ledgers already there. A figure
--    somebody keys into a dashboard is a figure nobody checks, and it is
--    the same defect this codebase has now found five times: a single
--    typed number standing in for something that is a function of other
--    facts.
--
-- 2. "I CANNOT WORK THAT OUT" IS AN ANSWER, AND IT IS NOT ZERO. A metric
--    whose query fails, or whose period has nothing to divide by, comes
--    back as NOT COMPUTED with the reason attached. A dashboard that
--    shows 0% margin because there are no cost-of-sales accounts is
--    worse than one that shows nothing, because 0 looks like a fact.
--
-- 3. FLOW, BALANCE AND CURRENT ARE THREE DIFFERENT THINGS. Revenue is
--    summed OVER a period. Cash is read AS AT the end of one. Stock on
--    hand has no history in this schema at all, so it can only ever be
--    read as of NOW — and saying otherwise would let somebody snapshot
--    "March stock value" in June and get today's figure with March
--    written on it. So `current` metrics are shown and never snapshotted.
--
-- 4. KAREYA SHIPS NO TARGETS. Not one. A target is a commercial
--    decision, and a plausible default here would quietly become
--    somebody's plan. Definitions ship — they are statements about your
--    own books, not about your ambition. Targets are yours.
--
-- ON EXECUTING STORED SQL, STATED PLAINLY. `compute_metric` runs the
-- stored body with EXECUTE. It is SECURITY INVOKER, so RLS binds and the
-- caller can reach nothing they could not already reach. A trigger
-- rejects a body that is not a single SELECT. That is a guard against
-- mistakes and careless definitions — it is NOT a sandbox, and it is not
-- claimed to be one. Writing a definition is therefore a Manager /
-- Accountant privilege, for the same reason writing a discount rule is.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.has_any_role(text[]).
-- Reads, where present: journal_lines, journal_entries, chart_of_accounts,
--             invoices, quotes, clients, stock_items, employees.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHAT A METRIC IS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.metric_definitions (
  code          text NOT NULL,
  name          text NOT NULL,
  name_kh       text,
  category      text,                       -- money | sales | operations | people
  unit          text DEFAULT 'count',       -- amount | percent | count | days | ratio
  decimals      integer DEFAULT 0,
  higher_is_better boolean DEFAULT true,

  -- flow    — summed OVER the period; the body must reference {from}
  -- balance — read AS AT the period end; the body must reference {to}
  -- current — a figure with no history behind it, so it is always "now";
  --           shown on the board, never snapshotted, never trended
  basis         text DEFAULT 'flow' NOT NULL,

  -- A single SELECT returning one numeric. {from} and {to} are replaced
  -- with quoted date literals before it runs.
  sql_body      text NOT NULL,

  source_module text,                       -- so somebody can ask where it came from
  description   text,
  is_active     boolean DEFAULT true,
  -- Shipped definitions can be switched off or edited, but not deleted:
  -- a snapshot taken last year names its metric by code.
  is_system     boolean DEFAULT false,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT metric_definitions_pkey PRIMARY KEY (code),
  CONSTRAINT metric_definitions_basis_check
    CHECK (basis = ANY (ARRAY['flow', 'balance', 'current'])),
  CONSTRAINT metric_definitions_unit_check
    CHECK (unit = ANY (ARRAY['amount', 'percent', 'count', 'days', 'ratio'])),
  CONSTRAINT metric_definitions_decimals_check CHECK (decimals BETWEEN 0 AND 6)
);

COMMENT ON TABLE public.metric_definitions IS
  'A business metric and the SELECT that works it out. Compare kpi_definitions, which is about a person.';

CREATE INDEX IF NOT EXISTS idx_metric_definitions_active
  ON public.metric_definitions (is_active, category);

-- ---- what a body is allowed to be ------------------------------------
/** A stored body is executed. This rejects everything that is not a
 *  single SELECT, and rejects a flow metric that ignores its own period —
 *  which would silently report all-time revenue under this month's
 *  heading, and look entirely believable while doing it. */
CREATE OR REPLACE FUNCTION public.metric_body_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_b text;
BEGIN
  v_b := lower(coalesce(NEW.sql_body, ''));

  IF v_b !~ '^\s*(select|with)\s' THEN
    RAISE EXCEPTION 'A metric is a single SELECT. This one starts with something else.';
  END IF;
  -- One statement. A trailing semicolon is a typo, not a second
  -- statement, so it is trimmed rather than refused.
  NEW.sql_body := regexp_replace(NEW.sql_body, ';\s*$', '');
  IF position(';' IN NEW.sql_body) > 0 THEN
    RAISE EXCEPTION 'A metric is one statement. Remove the semicolon.';
  END IF;
  -- The body must already begin with SELECT or WITH and carry no
  -- semicolon, so a second statement is impossible. What remains is a
  -- data-modifying CTE and a side-effecting function call, which is what
  -- this list is actually for. Words that are plausible column names
  -- (comment, call, notify) are deliberately NOT here — a check that
  -- cries wolf gets worked around.
  IF v_b ~ '\m(insert|update|delete|drop|alter|create|truncate|grant|revoke|copy|vacuum|reindex|lo_import|lo_export|dblink|pg_sleep|pg_read_file|pg_read_binary_file|pg_ls_dir|pg_terminate_backend)\M' THEN
    RAISE EXCEPTION 'A metric reads. It cannot change anything or reach outside the database.';
  END IF;

  IF NEW.basis = 'flow' AND position('{from}' IN NEW.sql_body) = 0 THEN
    RAISE EXCEPTION 'A flow metric is measured over a period, so it has to use {from}. Without it this would report every year under one month''s heading.';
  END IF;
  IF NEW.basis = 'balance' AND position('{to}' IN NEW.sql_body) = 0 THEN
    RAISE EXCEPTION 'A balance metric is read as at a date, so it has to use {to}.';
  END IF;
  IF NEW.basis = 'current'
     AND (position('{from}' IN NEW.sql_body) > 0 OR position('{to}' IN NEW.sql_body) > 0) THEN
    RAISE EXCEPTION 'A current metric has no history behind it, so it cannot honour a period. Use flow or balance instead.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_metric_body_check ON public.metric_definitions;
CREATE TRIGGER trg_metric_body_check
  BEFORE INSERT OR UPDATE ON public.metric_definitions
  FOR EACH ROW EXECUTE FUNCTION public.metric_body_check();

/** A shipped definition can be switched off. It cannot be deleted,
 *  because a snapshot from two years ago names it. */
CREATE OR REPLACE FUNCTION public.metric_guard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.is_system THEN
    RAISE EXCEPTION 'A metric Kareya ships cannot be deleted. Switch it off — old reports still name it.';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_metric_guard_delete ON public.metric_definitions;
CREATE TRIGGER trg_metric_guard_delete
  BEFORE DELETE ON public.metric_definitions
  FOR EACH ROW EXECUTE FUNCTION public.metric_guard_delete();

-- ---------------------------------------------------------------------
-- 2. WHAT SOMEBODY SAID THEY WOULD DO
-- Empty on purpose, and it stays empty until a human types a figure.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.metric_targets (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  metric_code   text NOT NULL,
  period_start  date NOT NULL,
  period_end    date NOT NULL,
  target_value  numeric NOT NULL,
  note          text,                        -- why this number, which is the useful part
  set_by        uuid,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT metric_targets_pkey PRIMARY KEY (id),
  CONSTRAINT metric_targets_metric_fkey FOREIGN KEY (metric_code)
    REFERENCES public.metric_definitions(code) ON DELETE CASCADE,
  CONSTRAINT metric_targets_set_by_fkey FOREIGN KEY (set_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT metric_targets_period_check CHECK (period_end >= period_start),
  CONSTRAINT uq_metric_target UNIQUE (metric_code, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS idx_metric_targets_period
  ON public.metric_targets (period_start, period_end);

-- ---------------------------------------------------------------------
-- 3. WHAT THE BOOKS SAID WHEN SOMEBODY LOOKED
-- The definition is copied onto the snapshot. Renaming a metric, or
-- rewriting how it is worked out, must not silently rewrite what last
-- quarter reported — the same reason a discount application copies its
-- rule and a quote freezes its lines.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.metric_snapshots (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  -- Deliberately NOT a foreign key: the snapshot outlives the definition.
  metric_code   text NOT NULL,
  name          text NOT NULL,               -- frozen
  unit          text,                        -- frozen
  decimals      integer,                     -- frozen
  higher_is_better boolean,                  -- frozen
  basis         text,                        -- frozen
  period_start  date NOT NULL,
  period_end    date NOT NULL,
  value         numeric,                     -- NULL when it could not be worked out
  computed      boolean DEFAULT true NOT NULL,
  problem       text,                        -- and why not
  target_value  numeric,                     -- frozen too: the target as it stood
  taken_at      timestamp with time zone DEFAULT now(),
  taken_by      uuid,
  CONSTRAINT metric_snapshots_pkey PRIMARY KEY (id),
  CONSTRAINT metric_snapshots_taken_by_fkey FOREIGN KEY (taken_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT metric_snapshots_period_check CHECK (period_end >= period_start),
  -- A value that could not be computed must say so rather than sit as a
  -- silent NULL somebody reads as zero.
  CONSTRAINT metric_snapshots_problem_check
    CHECK (computed OR problem IS NOT NULL),
  CONSTRAINT uq_metric_snapshot UNIQUE (metric_code, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS idx_metric_snapshots_metric
  ON public.metric_snapshots (metric_code, period_start);

-- ---------------------------------------------------------------------
-- 4. WORKING ONE OUT
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.compute_metric(text, date, date);
/** Runs the metric's own SELECT and hands back the number, or hands back
 *  the reason there isn't one.
 *
 *  SECURITY INVOKER on purpose: the body runs as the caller, so RLS
 *  binds and no privilege is gained by storing SQL here. */
CREATE OR REPLACE FUNCTION public.compute_metric(
  p_code text, p_from date, p_to date)
 RETURNS TABLE (out_value numeric, out_computed boolean, out_problem text)
 LANGUAGE plpgsql
 STABLE
 SECURITY INVOKER
 SET search_path TO 'public'
AS $$
DECLARE v_d metric_definitions; v_sql text; v_val numeric;
BEGIN
  SELECT * INTO v_d FROM metric_definitions WHERE code = p_code;
  IF v_d.code IS NULL THEN
    out_value := NULL; out_computed := false;
    out_problem := format('There is no metric called %s.', p_code);
    RETURN NEXT; RETURN;
  END IF;
  IF NOT v_d.is_active THEN
    out_value := NULL; out_computed := false;
    out_problem := format('%s is switched off.', v_d.name);
    RETURN NEXT; RETURN;
  END IF;
  IF p_to < p_from THEN
    RAISE EXCEPTION 'A period has to end after it begins';
  END IF;

  -- p_from and p_to are dates, so quoting them cannot carry anything
  -- through. The body is the only untrusted text here, and it was
  -- checked when it was written.
  -- Typed, not bare. A bare '2026-06-30' is `unknown` to the planner, so
  -- a body doing date arithmetic between the two tokens ({to} - {from})
  -- fails with an ambiguous operator instead of returning a number.
  v_sql := replace(replace(v_d.sql_body, '{from}', quote_literal(p_from) || '::date'),
                   '{to}', quote_literal(p_to) || '::date');

  BEGIN
    EXECUTE v_sql INTO v_val;
  EXCEPTION WHEN others THEN
    -- A vertical that was never installed, a renamed column, a typo in a
    -- body somebody wrote. Naming it beats a board full of zeroes.
    out_value := NULL; out_computed := false;
    out_problem := left(SQLERRM, 160);
    RETURN NEXT; RETURN;
  END;

  IF v_val IS NULL THEN
    out_value := NULL; out_computed := false;
    out_problem := 'Nothing in this period to work it out from.';
    RETURN NEXT; RETURN;
  END IF;

  out_value := round(v_val, coalesce(v_d.decimals, 0));
  out_computed := true; out_problem := NULL;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. THE BOARD
-- Every switched-on metric for a period, against its target.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.metric_board(date, date, text);
CREATE OR REPLACE FUNCTION public.metric_board(
  p_from date, p_to date, p_category text DEFAULT NULL)
 RETURNS TABLE (
   out_code        text,
   out_name        text,
   out_name_kh     text,
   out_category    text,
   out_unit        text,
   out_decimals    integer,
   out_basis       text,
   out_higher_is_better boolean,
   out_value       numeric,
   out_computed    boolean,
   out_problem     text,
   out_target      numeric,
   out_variance    numeric,
   out_variance_pct numeric,
   out_on_track    boolean,
   out_source      text,
   out_description text
 )
 LANGUAGE plpgsql
 STABLE
 SECURITY INVOKER
 SET search_path TO 'public'
AS $$
DECLARE v_d metric_definitions; v_c record; v_t numeric;
BEGIN
  FOR v_d IN
    SELECT * FROM metric_definitions
     WHERE is_active
       AND (p_category IS NULL OR category = p_category)
     ORDER BY category, name
  LOOP
    SELECT * INTO v_c FROM compute_metric(v_d.code, p_from, p_to);

    SELECT target_value INTO v_t FROM metric_targets
     WHERE metric_code = v_d.code
       AND period_start = p_from AND period_end = p_to;

    out_code := v_d.code; out_name := v_d.name; out_name_kh := v_d.name_kh;
    out_category := v_d.category; out_unit := v_d.unit;
    out_decimals := v_d.decimals; out_basis := v_d.basis;
    out_higher_is_better := v_d.higher_is_better;
    out_value := v_c.out_value; out_computed := v_c.out_computed;
    out_problem := v_c.out_problem;
    out_target := v_t;
    out_source := v_d.source_module; out_description := v_d.description;

    IF v_t IS NULL OR NOT v_c.out_computed THEN
      -- No target, or no number. Either way there is nothing to judge,
      -- and guessing "on track" from a missing figure is how a red month
      -- reads as green.
      out_variance := NULL; out_variance_pct := NULL; out_on_track := NULL;
    ELSE
      out_variance := v_c.out_value - v_t;
      out_variance_pct := CASE WHEN v_t = 0 THEN NULL
                               ELSE round((v_c.out_value - v_t) / abs(v_t) * 100, 1) END;
      out_on_track := CASE WHEN v_d.higher_is_better THEN v_c.out_value >= v_t
                           ELSE v_c.out_value <= v_t END;
    END IF;

    RETURN NEXT;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. FREEZING A PERIOD
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.snapshot_metrics(date, date);
/** Records what the books say for a period, with the definition and the
 *  target copied alongside.
 *
 *  `current` metrics are SKIPPED. They have no history behind them, so
 *  filing today's stock value under March would be a lie with a date on
 *  it. The count of what was skipped comes back so nobody assumes the
 *  board and the snapshot hold the same rows. */
CREATE OR REPLACE FUNCTION public.snapshot_metrics(p_from date, p_to date)
 RETURNS TABLE (out_taken integer, out_failed integer, out_skipped integer)
 LANGUAGE plpgsql
 -- INVOKER, and this matters. Inside a SECURITY DEFINER function the
 -- "invoker" becomes the definer, so calling compute_metric from one
 -- would run every stored body with the owner's rights and quietly undo
 -- the reason compute_metric is INVOKER at all. Closing a period is a
 -- Manager or Accountant action; the RLS write policy is what says so.
 SECURITY INVOKER
 SET search_path TO 'public'
AS $$
DECLARE
  v_d metric_definitions; v_c record; v_t numeric; v_me uuid;
  v_taken integer := 0; v_failed integer := 0; v_skipped integer := 0;
BEGIN
  IF p_to < p_from THEN RAISE EXCEPTION 'A period has to end after it begins'; END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  FOR v_d IN SELECT * FROM metric_definitions WHERE is_active ORDER BY code
  LOOP
    IF v_d.basis = 'current' THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT * INTO v_c FROM compute_metric(v_d.code, p_from, p_to);
    SELECT target_value INTO v_t FROM metric_targets
     WHERE metric_code = v_d.code AND period_start = p_from AND period_end = p_to;

    INSERT INTO metric_snapshots (
      metric_code, name, unit, decimals, higher_is_better, basis,
      period_start, period_end, value, computed, problem, target_value, taken_by)
    VALUES (
      v_d.code, v_d.name, v_d.unit, v_d.decimals, v_d.higher_is_better, v_d.basis,
      p_from, p_to, v_c.out_value, v_c.out_computed, v_c.out_problem, v_t, v_me)
    ON CONFLICT (metric_code, period_start, period_end) DO UPDATE
      SET name = EXCLUDED.name, unit = EXCLUDED.unit, decimals = EXCLUDED.decimals,
          higher_is_better = EXCLUDED.higher_is_better, basis = EXCLUDED.basis,
          value = EXCLUDED.value, computed = EXCLUDED.computed,
          problem = EXCLUDED.problem, target_value = EXCLUDED.target_value,
          taken_at = now(), taken_by = EXCLUDED.taken_by;

    IF v_c.out_computed THEN v_taken := v_taken + 1; ELSE v_failed := v_failed + 1; END IF;
  END LOOP;

  out_taken := v_taken; out_failed := v_failed; out_skipped := v_skipped;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. THE TREND
-- Read from snapshots, not recomputed. A trend that recomputes history
-- through today's definition is a trend that changes when somebody edits
-- a formula, which is the one thing a trend must never do.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.metric_trend(text, integer);
CREATE OR REPLACE FUNCTION public.metric_trend(p_code text, p_periods integer DEFAULT 12)
 RETURNS TABLE (
   out_period_start date,
   out_period_end   date,
   out_value        numeric,
   out_computed     boolean,
   out_target       numeric,
   out_on_track     boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT s.period_start, s.period_end, s.value, s.computed, s.target_value,
         CASE WHEN s.target_value IS NULL OR NOT s.computed THEN NULL
              WHEN s.higher_is_better THEN s.value >= s.target_value
              ELSE s.value <= s.target_value END
    FROM metric_snapshots s
   WHERE s.metric_code = p_code
   ORDER BY s.period_start DESC
   LIMIT greatest(coalesce(p_periods, 12), 1);
$$;

-- ---------------------------------------------------------------------
-- 8. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.metric_reconciliation()
 RETURNS TABLE (out_kind text, out_ref text, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- A metric on the board that cannot be worked out. The commonest cause
  -- is a definition pointing at a module this business does not run.
  SELECT 'metric', s.metric_code, s.name,
         'Could not be worked out for ' || to_char(s.period_start, 'Mon YYYY')
         || ': ' || coalesce(s.problem, 'no reason recorded')
    FROM metric_snapshots s
   WHERE NOT s.computed
     AND s.period_start > CURRENT_DATE - interval '1 year'

  UNION ALL
  -- Somebody set a target for a period that has finished, and nobody
  -- ever recorded how it went. A target nobody looks back at is a wish.
  SELECT 'target', t.metric_code, d.name,
         'Target of ' || t.target_value::text || ' for '
         || to_char(t.period_start, 'DD Mon') || '–' || to_char(t.period_end, 'DD Mon YYYY')
         || ' — the period has ended and no result was recorded.'
    FROM metric_targets t
    JOIN metric_definitions d ON d.code = t.metric_code
   WHERE t.period_end < CURRENT_DATE
     AND NOT EXISTS (SELECT 1 FROM metric_snapshots s
                      WHERE s.metric_code = t.metric_code
                        AND s.period_start = t.period_start
                        AND s.period_end = t.period_end)

  UNION ALL
  -- Missed, in the most recent period that ACTUALLY HAD A TARGET. Not
  -- simply the most recent period: closing a later month with no target
  -- set would otherwise bury the last month somebody did aim at, which
  -- is the one month they wanted to hear about.
  SELECT 'metric', s.metric_code, s.name,
         'Missed its target in ' || to_char(s.period_start, 'Mon YYYY')
         || ': ' || s.value::text || ' against ' || s.target_value::text
    FROM metric_snapshots s
   WHERE s.computed AND s.target_value IS NOT NULL
     AND s.period_start = (SELECT max(period_start) FROM metric_snapshots x
                            WHERE x.metric_code = s.metric_code
                              AND x.target_value IS NOT NULL)
     AND ((s.higher_is_better AND s.value < s.target_value)
       OR (NOT s.higher_is_better AND s.value > s.target_value))

  UNION ALL
  -- A target on a metric nobody shows any more.
  SELECT 'target', t.metric_code, d.name,
         'Has a target for a metric that is switched off.'
    FROM metric_targets t
    JOIN metric_definitions d ON d.code = t.metric_code
   WHERE NOT d.is_active AND t.period_end >= CURRENT_DATE

  UNION ALL
  -- Nothing has ever been frozen. The board is live, so it always looks
  -- fine; without snapshots there is no history and no trend.
  SELECT 'setup', 'snapshots', 'Nothing has been recorded yet',
         'The board is worked out live, so closing a period is what gives you a trend. Nothing has been recorded.'
   WHERE NOT EXISTS (SELECT 1 FROM metric_snapshots)

  UNION ALL
  -- Every metric is running with nothing to hit.
  SELECT 'setup', 'targets', 'No targets have been set',
         'Kareya ships none, on purpose. Until you set some, this reports what happened and never says whether it was good.'
   WHERE NOT EXISTS (SELECT 1 FROM metric_targets);
$$;

-- ---------------------------------------------------------------------
-- 9. THE DEFINITIONS KAREYA SHIPS
-- ---------------------------------------------------------------------
-- These are statements about YOUR OWN BOOKS, not about your ambition,
-- which is why they ship where targets do not. Every one reads the
-- general ledger or a base table, so they work on the day the schema is
-- applied. Anything that could not be computed honestly was left out —
-- payroll cost and till takings both mix KHR and USD rows with no
-- reliable rate on them, and a silently wrong total is worse than a
-- missing one.
-- ---------------------------------------------------------------------
INSERT INTO public.metric_definitions
  (code, name, name_kh, category, unit, decimals, higher_is_better, basis,
   source_module, description, is_system, sql_body)
SELECT v.* FROM (VALUES

-- ---- money, over the period ----
('revenue', 'Revenue', 'ចំណូល', 'money', 'amount', 2, true, 'flow',
 'Accounting', 'Everything credited to an income account in the period, from the general ledger rather than from invoices — so a cash sale posted straight to the ledger counts too.', true,
 'select coalesce(sum(l.credit - l.debit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type = ''income'' and e.date between {from} and {to}'),

('expenses', 'Expenses', 'ចំណាយ', 'money', 'amount', 2, false, 'flow',
 'Accounting', 'Everything charged to an expense account in the period, cost of sales included.', true,
 'select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type = ''expense'' and e.date between {from} and {to}'),

('net_profit', 'Net profit', 'ចំណេញសុទ្ធ', 'money', 'amount', 2, true, 'flow',
 'Accounting', 'Income less expenses for the period. Busier and no better off shows up here and nowhere else.', true,
 'select coalesce(sum(case when a.type = ''income'' then l.credit - l.debit else l.credit - l.debit end), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type in (''income'', ''expense'') and e.date between {from} and {to}'),

('gross_margin_pct', 'Gross margin', 'រឹមចំណេញដុល', 'money', 'percent', 1, true, 'flow',
 'Accounting', 'Revenue less cost of sales, as a share of revenue. Needs accounts marked with the cost-of-sales subtype; without any, this reports nothing rather than a flattering 100%.', true,
 'select case when not exists (select 1 from chart_of_accounts where subtype = ''cogs'') then null when r.rev = 0 then null else (r.rev - r.cogs) / r.rev * 100 end from (select coalesce(sum(l.credit - l.debit) filter (where a.type = ''income''), 0) as rev, coalesce(sum(l.debit - l.credit) filter (where a.subtype = ''cogs''), 0) as cogs from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where e.date between {from} and {to}) r'),

('dso', 'Days sales outstanding', 'ចំនួនថ្ងៃប្រមូលប្រាក់', 'money', 'days', 1, false, 'flow',
 'Accounting', 'How long your money sits in somebody else''s bank: receivables at the period end against revenue earned in it. Reports nothing in a period with no revenue, because dividing by nothing is not a large number.', true,
 'select case when rev.v <= 0 then null else ar.v / rev.v * (({to} - {from}) + 1) end from (select coalesce(sum(l.debit - l.credit), 0) v from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.subtype = ''receivable'' and e.date <= {to}) ar, (select coalesce(sum(l.credit - l.debit), 0) v from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type = ''income'' and e.date between {from} and {to}) rev'),

-- ---- money, as at the period end ----
('cash_balance', 'Cash and bank', 'សាច់ប្រាក់និងធនាគារ', 'money', 'amount', 2, true, 'balance',
 'Accounting', 'What is in the cash and bank accounts at the end of the period. A balance, not a flow — this is a position on a date.', true,
 'select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type = ''asset'' and a.subtype in (''bank'', ''cash'') and e.date <= {to}'),

('receivables', 'Owed to you', 'ប្រាក់គេជំពាក់', 'money', 'amount', 2, false, 'balance',
 'Accounting', 'The receivables balance at the end of the period.', true,
 'select coalesce(sum(l.debit - l.credit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.subtype = ''receivable'' and e.date <= {to}'),

('payables', 'You owe', 'ប្រាក់អ្នកជំពាក់គេ', 'money', 'amount', 2, false, 'balance',
 'Accounting', 'The payables balance at the end of the period.', true,
 'select coalesce(sum(l.credit - l.debit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.subtype = ''payable'' and e.date <= {to}'),

('overdue_receivables', 'Overdue invoices', 'វិក្កយបត្រហួសកំណត់', 'money', 'amount', 2, false, 'balance',
 'Accounting', 'Invoices past their due date and not settled, as at the period end. Voided invoices are left out.', true,
 'select coalesce(sum(i.amount), 0) from invoices i where coalesce(i.voided, false) = false and coalesce(i.status, '''') <> ''paid'' and i.due_date is not null and i.due_date < {to}'),

-- ---- selling ----
('invoices_issued', 'Invoices issued', 'វិក្កយបត្របានចេញ', 'sales', 'count', 0, true, 'flow',
 'Accounting', 'How many invoices were raised in the period, voided ones excluded.', true,
 'select count(*) from invoices i where coalesce(i.voided, false) = false and i.date between {from} and {to}'),

('average_invoice', 'Average invoice', 'វិក្កយបត្រជាមធ្យម', 'sales', 'amount', 2, true, 'flow',
 'Accounting', 'What a typical invoice was worth in the period. Rising while revenue is flat means fewer, larger customers.', true,
 'select avg(i.amount) from invoices i where coalesce(i.voided, false) = false and i.date between {from} and {to}'),

('quote_win_rate', 'Quotes won', 'សម្រង់តម្លៃដែលឈ្នះ', 'sales', 'percent', 1, true, 'flow',
 'Sales', 'Of the quotes sent out in the period, the share that were accepted or turned into an invoice. Drafts are not counted — an unsent quote was never lost.', true,
 'select case when count(*) = 0 then null else count(*) filter (where q.status in (''accepted'', ''invoiced''))::numeric / count(*) * 100 end from quotes q where q.date between {from} and {to} and coalesce(q.status, ''draft'') <> ''draft'''),

('new_customers', 'New customers', 'អតិថិជនថ្មី', 'sales', 'count', 0, true, 'flow',
 'Sales', 'Customers added in the period.', true,
 'select count(*) from clients c where c.created_at::date between {from} and {to}'),

-- ---- things with no history behind them ----
('stock_value', 'Stock on hand', 'តម្លៃស្តុក', 'operations', 'amount', 2, true, 'current',
 'Inventory', 'What the stock on the shelf is worth at cost. Stock levels carry no history in this schema, so this is TODAY''s figure whatever period you ask for — which is why it is never recorded into a closed period.', true,
 'select coalesce(sum(s.quantity * s.cost_price), 0) from stock_items s'),

('low_stock_items', 'Items below reorder level', 'ទំនិញក្រោមកម្រិតបញ្ជាទិញ', 'operations', 'count', 0, false, 'current',
 'Inventory', 'How many stock lines are at or under their reorder level right now.', true,
 'select count(*) from stock_items s where s.reorder_level > 0 and s.quantity <= s.reorder_level'),

('headcount', 'Staff', 'បុគ្គលិក', 'people', 'count', 0, true, 'current',
 'HR', 'Employees currently marked active. The employee record carries no history of joining and leaving, so this is today''s count.', true,
 'select count(*) from employees e where e.status = ''active''')

) AS v(code, name, name_kh, category, unit, decimals, higher_is_better, basis,
       source_module, description, is_system, sql_body)
WHERE NOT EXISTS (SELECT 1 FROM public.metric_definitions d WHERE d.code = v.code);

GRANT EXECUTE ON FUNCTION public.compute_metric(text, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.metric_board(date, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.snapshot_metrics(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.metric_trend(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.metric_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY
-- Reading the board is open to signed-in staff — a team that cannot see
-- how the business is doing cannot be asked to improve it. Writing a
-- DEFINITION is a Manager or Accountant privilege, because a definition
-- is executable SQL and because a metric everybody can rewrite measures
-- nothing.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['metric_definitions', 'metric_targets', 'metric_snapshots']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Manager','Accountant']))
                      WITH CHECK (public.has_any_role(ARRAY['Manager','Accountant']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
