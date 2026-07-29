-- =====================================================================
-- LAB — quality control, turnaround, rejections, send-outs, consumption
-- and billing
--
-- QC IS THE HEADLINE. lab_qc_runs already stored an expected and a measured
-- value with a pass/warning/fail typed in by hand. That records THAT quality
-- control happened; it does not tell anybody the run is out of control, which
-- is the only thing quality control is for. A technician eyeballing "expected
-- 5.0, measured 5.4" has no way to know whether 0.4 is ordinary scatter or the
-- fourth consecutive drift that means the instrument needs recalibrating
-- before another patient result leaves the building.
--
-- So: a control lot carries a mean and a standard deviation, every run gets a
-- z-score against them, and the Westgard multirule set is evaluated against
-- the run history. Those rules exist because a single 2SD limit rejects one
-- run in twenty on a perfectly good instrument — too many false alarms and the
-- staff start ignoring the alarm, which is worse than having none.
--
-- Also here, because each is small on its own and they all hang off the same
-- worklist:
--   - turnaround measured against the target the catalogue already carried
--   - rejection reason codes, so "rejected" can be reported on
--   - send-outs, which any Cambodian lab does for specialised assays
--   - reagent consumption, linking a test to the stock module
--   - billing, so lab_tests.price finally charges something
--
-- Depends on: lab_tests, lab_samples, lab_orders, lab_instruments,
--             lab_qc_runs, employees, clients, invoices, invoice_items,
--             stock_items, stock_movements (base schema).
-- Safe to re-run.
-- =====================================================================

-- =====================================================================
-- 1. QUALITY CONTROL — control lots, z-scores, Westgard multirules
-- =====================================================================

/* A control material lot, with the statistics the rules are evaluated
 * against.
 *
 * Mean and SD are per LOT, not per test: a new lot of control material has its
 * own values, and carrying the old lot's statistics across a lot change is a
 * classic way to manufacture a shift that is not there. Peer values are the
 * manufacturer's insert; a laboratory is expected to replace them with its own
 * once it has enough runs, which is why source is recorded. */
CREATE TABLE IF NOT EXISTS public.lab_qc_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  test_id uuid NOT NULL REFERENCES public.lab_tests(id) ON DELETE CASCADE,
  instrument_id uuid REFERENCES public.lab_instruments(id) ON DELETE CASCADE,
  level text NOT NULL DEFAULT 'normal',      -- low | normal | high
  lot_no text,
  target_mean numeric NOT NULL,
  target_sd numeric NOT NULL,
  source text DEFAULT 'insert',              -- insert (manufacturer) | inhouse
  expires_on date,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_qc_lots_level_check CHECK (level = ANY (ARRAY['low','normal','high'])),
  -- An SD of zero makes every z-score infinite and every run a rejection.
  CONSTRAINT lab_qc_lots_sd_positive CHECK (target_sd > 0),
  CONSTRAINT lab_qc_lots_source_check CHECK (source = ANY (ARRAY['insert','inhouse'])),
  CONSTRAINT lab_qc_lots_unique UNIQUE (test_id, instrument_id, level, lot_no)
);

CREATE INDEX IF NOT EXISTS idx_lab_qc_lots_test ON public.lab_qc_lots (test_id, instrument_id, level);

ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS lot_id uuid
  REFERENCES public.lab_qc_lots(id) ON DELETE SET NULL;
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS z_score numeric;
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS rule_violated text;   -- 1-3s, 2-2s, R-4s, 4-1s, 10x
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS reviewed_by uuid
  REFERENCES public.employees(id) ON DELETE SET NULL;
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS corrective_action text;
-- run_date is a DATE, so several runs a day tie. A timestamp gives the rules a
-- real sequence — "two CONSECUTIVE runs" is meaningless without one.
ALTER TABLE public.lab_qc_runs ADD COLUMN IF NOT EXISTS run_at timestamptz DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_lab_qc_runs_seq ON public.lab_qc_runs (lot_id, run_at DESC);

/* Evaluate the Westgard multirules for one run against those before it.
 *
 * Rules, in the order a laboratory applies them:
 *   1-2s   one run beyond 2SD          -> WARNING only, never a rejection.
 *                                         On a controlled instrument this
 *                                         fires about once in twenty runs by
 *                                         chance; treating it as a rejection
 *                                         is what teaches staff to ignore QC.
 *   1-3s   one run beyond 3SD          -> reject (random error)
 *   2-2s   two consecutive beyond 2SD, same side       -> reject (systematic)
 *   R-4s   two consecutive spanning more than 4SD      -> reject (random)
 *   4-1s   four consecutive beyond 1SD, same side      -> reject (systematic)
 *   10x    ten consecutive on the same side of the mean-> reject (shift)
 *
 * Evaluated newest-first over the same lot, because the rules are about a
 * sequence on one control material — comparing across lots compares different
 * distributions.
 *
 * Returns the rule that fired, or NULL. 'warn:1-2s' is distinguished from a
 * rejection so the caller can show it without stopping work. */
CREATE OR REPLACE FUNCTION public.lab_qc_westgard(p_run_id uuid)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  z numeric[];          -- z-scores, index 1 = this run, 2 = the one before...
  n integer;
BEGIN
  SELECT array_agg(zz ORDER BY rn)
    INTO z
  FROM (
    SELECT r.z_score AS zz, row_number() OVER (ORDER BY r.run_at DESC, r.id DESC) AS rn
    FROM public.lab_qc_runs r
    WHERE r.lot_id = (SELECT lot_id FROM public.lab_qc_runs WHERE id = p_run_id)
      AND r.z_score IS NOT NULL
      AND (r.run_at, r.id) <= (SELECT run_at, id FROM public.lab_qc_runs WHERE id = p_run_id)
    ORDER BY r.run_at DESC, r.id DESC
    LIMIT 10
  ) s;

  IF z IS NULL OR array_length(z, 1) IS NULL THEN RETURN NULL; END IF;
  n := array_length(z, 1);

  -- 1-3s: random error, on this run alone.
  IF abs(z[1]) > 3 THEN RETURN '1-3s'; END IF;

  -- 2-2s: two consecutive beyond 2SD on the SAME side. Opposite sides is
  -- scatter, not a shift, and is caught by R-4s instead.
  IF n >= 2 AND abs(z[1]) > 2 AND abs(z[2]) > 2 AND sign(z[1]) = sign(z[2]) THEN
    RETURN '2-2s';
  END IF;

  -- R-4s: the SPREAD between two consecutive runs exceeds 4SD.
  IF n >= 2 AND abs(z[1] - z[2]) > 4 THEN RETURN 'R-4s'; END IF;

  -- 4-1s: four consecutive beyond 1SD, same side.
  IF n >= 4
     AND abs(z[1]) > 1 AND abs(z[2]) > 1 AND abs(z[3]) > 1 AND abs(z[4]) > 1
     AND sign(z[1]) = sign(z[2]) AND sign(z[2]) = sign(z[3]) AND sign(z[3]) = sign(z[4]) THEN
    RETURN '4-1s';
  END IF;

  -- 10x: ten consecutive on one side of the mean, however small the offset.
  IF n >= 10 THEN
    IF (SELECT count(*) FROM unnest(z[1:10]) v WHERE sign(v) = sign(z[1])) = 10
       AND z[1] <> 0 THEN
      RETURN '10x';
    END IF;
  END IF;

  -- Warning last: only reached when nothing above rejected the run.
  IF abs(z[1]) > 2 THEN RETURN 'warn:1-2s'; END IF;

  RETURN NULL;
END $$;

/* Score a QC run and apply the rules on write.
 *
 * status is derived, not typed: 'fail' when a rejection rule fires, 'warning'
 * on 1-2s, otherwise 'pass'. A hand-typed status was the previous behaviour
 * and it is exactly what a QC record must not be. */
CREATE OR REPLACE FUNCTION public.lab_qc_score() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_mean numeric; v_sd numeric; v_rule text;
BEGIN
  IF NEW.run_at IS NULL THEN NEW.run_at := now(); END IF;

  -- Resolve the lot when the caller gave only test/instrument/level.
  IF NEW.lot_id IS NULL AND NEW.test_id IS NOT NULL THEN
    SELECT l.id INTO NEW.lot_id
    FROM public.lab_qc_lots l
    WHERE l.test_id = NEW.test_id
      AND (l.instrument_id IS NOT DISTINCT FROM NEW.instrument_id OR l.instrument_id IS NULL)
      AND l.level = COALESCE(NEW.level, 'normal')
      AND l.is_active
    ORDER BY (l.instrument_id IS NOT NULL) DESC, l.created_at DESC
    LIMIT 1;
  END IF;

  IF NEW.lot_id IS NOT NULL THEN
    SELECT l.target_mean, l.target_sd INTO v_mean, v_sd
    FROM public.lab_qc_lots l WHERE l.id = NEW.lot_id;
    -- Keep `expected` meaningful: it is the lot mean once a lot is known.
    NEW.expected := COALESCE(v_mean, NEW.expected);
  ELSE
    v_mean := NEW.expected;
  END IF;

  IF NEW.measured IS NOT NULL AND v_mean IS NOT NULL AND COALESCE(v_sd, 0) > 0 THEN
    NEW.z_score := ROUND((NEW.measured - v_mean) / v_sd, 2);
  ELSE
    NEW.z_score := NULL;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_lab_qc_score ON public.lab_qc_runs;
CREATE TRIGGER trg_lab_qc_score
  BEFORE INSERT OR UPDATE OF measured, lot_id, test_id, instrument_id, level, run_at
  ON public.lab_qc_runs
  FOR EACH ROW EXECUTE FUNCTION public.lab_qc_score();

/* The rules need the row to exist before they can look at the sequence that
 * includes it, so they run AFTER insert and write back. A BEFORE trigger
 * cannot see itself in the history. */
CREATE OR REPLACE FUNCTION public.lab_qc_apply_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_rule text; v_status text;
BEGIN
  v_rule := public.lab_qc_westgard(NEW.id);
  v_status := CASE
                WHEN v_rule IS NULL THEN 'pass'
                WHEN v_rule LIKE 'warn:%' THEN 'warning'
                ELSE 'fail'
              END;
  IF NEW.rule_violated IS DISTINCT FROM v_rule OR NEW.status IS DISTINCT FROM v_status THEN
    UPDATE public.lab_qc_runs
       SET rule_violated = v_rule, status = v_status
     WHERE id = NEW.id;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_lab_qc_apply_rules ON public.lab_qc_runs;
CREATE TRIGGER trg_lab_qc_apply_rules
  AFTER INSERT OR UPDATE OF measured, z_score ON public.lab_qc_runs
  FOR EACH ROW EXECUTE FUNCTION public.lab_qc_apply_rules();

/* Levey-Jennings series for a chart: the runs plus the lines to draw. */
DROP FUNCTION IF EXISTS public.lab_qc_series(uuid, integer);
CREATE OR REPLACE FUNCTION public.lab_qc_series(p_lot_id uuid, p_limit integer DEFAULT 40)
RETURNS TABLE (
  out_id uuid, out_run_at timestamptz, out_measured numeric,
  out_z numeric, out_status text, out_rule text,
  out_mean numeric, out_sd numeric
) LANGUAGE sql STABLE AS $$
  SELECT r.id, r.run_at, r.measured, r.z_score, r.status, r.rule_violated,
         l.target_mean, l.target_sd
  FROM public.lab_qc_runs r
  JOIN public.lab_qc_lots l ON l.id = r.lot_id
  WHERE r.lot_id = p_lot_id
  ORDER BY r.run_at DESC, r.id DESC
  LIMIT p_limit;
$$;

/* Whether a test may be resulted right now: has its most recent QC run on an
 * active lot rejected? Advisory rather than enforced — a laboratory sometimes
 * has to release with a documented deviation, and a hard block would only
 * teach people to delete QC rows. */
CREATE OR REPLACE FUNCTION public.lab_qc_blocked(p_test_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((
    SELECT r.status = 'fail' AND r.reviewed_at IS NULL
    FROM public.lab_qc_runs r
    JOIN public.lab_qc_lots l ON l.id = r.lot_id AND l.is_active
    WHERE l.test_id = p_test_id
    ORDER BY r.run_at DESC, r.id DESC
    LIMIT 1
  ), false);
$$;

-- =====================================================================
-- 2. TURNAROUND — measured against the target already in the catalogue
-- =====================================================================

/* lab_tests.tat_hours has always been stored as a target and never compared to
 * anything. Both timestamps were already there, so this is nearly free — and
 * turnaround is the number a laboratory manager is actually asked about. */
DROP FUNCTION IF EXISTS public.lab_tat_stats(date, date);
CREATE OR REPLACE FUNCTION public.lab_tat_stats(
  p_from date DEFAULT (CURRENT_DATE - 30), p_to date DEFAULT CURRENT_DATE
) RETURNS TABLE (
  out_test_id uuid, out_test text, out_target_hours integer,
  out_completed integer, out_median_hours numeric, out_p90_hours numeric,
  out_within_target integer, out_breached integer
) LANGUAGE sql STABLE AS $$
  WITH done AS (
    SELECT o.test_id,
           EXTRACT(epoch FROM (o.verified_at - COALESCE(s.received_at, s.collected_at))) / 3600.0 AS hours
    FROM public.lab_orders o
    JOIN public.lab_samples s ON s.id = o.sample_id
    WHERE o.status = 'verified'
      AND o.verified_at IS NOT NULL
      AND COALESCE(s.received_at, s.collected_at) IS NOT NULL
      AND o.verified_at::date BETWEEN p_from AND p_to
      -- A negative interval means the timestamps are wrong, not that the lab
      -- worked backwards; excluded rather than allowed to drag the median.
      AND o.verified_at >= COALESCE(s.received_at, s.collected_at)
  )
  SELECT t.id, t.name, t.tat_hours,
         count(d.hours)::integer,
         ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY d.hours)::numeric, 1),
         ROUND(percentile_cont(0.9) WITHIN GROUP (ORDER BY d.hours)::numeric, 1),
         count(*) FILTER (WHERE d.hours <= t.tat_hours)::integer,
         count(*) FILTER (WHERE d.hours > t.tat_hours)::integer
  FROM done d
  JOIN public.lab_tests t ON t.id = d.test_id
  GROUP BY t.id, t.name, t.tat_hours
  ORDER BY count(*) FILTER (WHERE d.hours > t.tat_hours) DESC, t.name;
$$;

-- =====================================================================
-- 3. REJECTION REASONS
-- =====================================================================

/* lab_samples.status could already be 'rejected' with no reason recorded, so
 * the one question quality reporting asks — WHY are we rejecting samples —
 * had no answer. Codes rather than free text, because "haemolysed", "hemolyzed"
 * and "broken sample" do not aggregate. */
CREATE TABLE IF NOT EXISTS public.lab_rejection_reasons (
  code text PRIMARY KEY,
  name text NOT NULL,
  name_kh text,
  domain text,                              -- NULL = applies to any domain
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0
);

INSERT INTO public.lab_rejection_reasons (code, name, name_kh, domain, sort_order) VALUES
  ('haemolysed',   'Haemolysed',                  'ឈាមបែក',                    'clinical', 10),
  ('clotted',      'Clotted',                     'ឈាមកកជាដុំ',                 'clinical', 20),
  ('insufficient', 'Insufficient volume',         'បរិមាណមិនគ្រប់គ្រាន់',        NULL,       30),
  ('mislabelled',  'Mislabelled or unlabelled',   'ស្លាកខុសឬគ្មានស្លាក',        NULL,       40),
  ('wrong_tube',   'Wrong container or preservative', 'ធុងឬសារធាតុរក្សាទុកខុស',  NULL,       50),
  ('leaked',       'Leaked or damaged in transit','លេចធ្លាយឬខូចពេលដឹកជញ្ជូន',    NULL,       60),
  ('too_old',      'Exceeded stability time',     'ហួសរយៈពេលរក្សាគុណភាព',        NULL,       70),
  ('temperature',  'Temperature out of range',    'សីតុណ្ហភាពហួសកម្រិត',         NULL,       80),
  ('contaminated', 'Contaminated',                'មានការចម្លងរោគ',              NULL,       90),
  ('no_request',   'No request form',             'គ្មានទម្រង់ស្នើសុំ',           NULL,      100)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS rejection_code text
  REFERENCES public.lab_rejection_reasons(code) ON DELETE SET NULL;
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS rejection_note text;
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS rejected_at timestamptz;

/* A rejection without a reason is the state this table exists to prevent. */
CREATE OR REPLACE FUNCTION public.lab_guard_rejection() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'rejected' AND COALESCE(OLD.status, '') <> 'rejected' THEN
    IF NEW.rejection_code IS NULL THEN
      RAISE EXCEPTION 'A rejected sample needs a rejection reason';
    END IF;
    NEW.rejected_at := COALESCE(NEW.rejected_at, now());
  ELSIF NEW.status <> 'rejected' THEN
    NEW.rejected_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_lab_guard_rejection ON public.lab_samples;
CREATE TRIGGER trg_lab_guard_rejection
  BEFORE UPDATE ON public.lab_samples
  FOR EACH ROW EXECUTE FUNCTION public.lab_guard_rejection();

-- =====================================================================
-- 4. SEND-OUTS (referrals)
-- =====================================================================

/* Cambodian laboratories routinely refer specialised assays to a larger
 * Phnom Penh laboratory or to Bangkok. Without this the order simply sits
 * pending and nobody can say where the sample went or what it cost. */
CREATE TABLE IF NOT EXISTS public.lab_referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.lab_orders(id) ON DELETE CASCADE,
  referred_to text NOT NULL,                -- the receiving laboratory
  their_reference text,                     -- their accession, for chasing
  sent_at timestamptz DEFAULT now(),
  expected_at date,
  received_at timestamptz,
  cost numeric DEFAULT 0,                   -- what THEY charge us
  courier text,
  notes text,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_referrals_order_unique UNIQUE (order_id)
);

CREATE INDEX IF NOT EXISTS idx_lab_referrals_open
  ON public.lab_referrals (expected_at) WHERE received_at IS NULL;

/* Referrals still outstanding, worst overdue first — the chase list. */
CREATE OR REPLACE FUNCTION public.lab_referrals_outstanding()
RETURNS TABLE (
  out_id uuid, out_accession text, out_test text, out_referred_to text,
  out_sent_at timestamptz, out_expected_at date, out_days_overdue integer
) LANGUAGE sql STABLE AS $$
  SELECT r.id, s.accession_number, t.name, r.referred_to, r.sent_at, r.expected_at,
         GREATEST(0, (CURRENT_DATE - r.expected_at))::integer
  FROM public.lab_referrals r
  JOIN public.lab_orders o ON o.id = r.order_id
  JOIN public.lab_samples s ON s.id = o.sample_id
  LEFT JOIN public.lab_tests t ON t.id = o.test_id
  WHERE r.received_at IS NULL
  ORDER BY (r.expected_at IS NULL), r.expected_at ASC;
$$;

-- =====================================================================
-- 5. REAGENT CONSUMPTION
-- =====================================================================

/* What one run of a test consumes, pointing at the stock module that already
 * exists rather than inventing a second one. */
CREATE TABLE IF NOT EXISTS public.lab_test_reagents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  test_id uuid NOT NULL REFERENCES public.lab_tests(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.stock_items(id) ON DELETE CASCADE,
  quantity numeric NOT NULL DEFAULT 1,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_test_reagents_unique UNIQUE (test_id, item_id),
  CONSTRAINT lab_test_reagents_qty_positive CHECK (quantity > 0)
);

/* Issue reagent when a result is entered.
 *
 * Fires once, on the transition INTO 'resulted', not on every subsequent edit
 * — correcting a typed result does not consume a second aliquot. Repeating a
 * test genuinely does, but that is a new order, which is its own transition.
 *
 * Deliberately does NOT fail the result when stock is short. A laboratory that
 * cannot save a patient result because the reagent count is wrong will stop
 * recording reagents, and the count that blocked them was the wrong one
 * anyway. Stock goes negative and the inventory module shows it. */
CREATE OR REPLACE FUNCTION public.lab_consume_reagents() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record; v_acc text;
BEGIN
  IF NEW.status <> 'resulted' OR COALESCE(OLD.status, '') = 'resulted' THEN
    RETURN NULL;
  END IF;

  SELECT s.accession_number INTO v_acc FROM public.lab_samples s WHERE s.id = NEW.sample_id;

  FOR r IN SELECT tr.item_id, tr.quantity, si.cost_price
           FROM public.lab_test_reagents tr
           JOIN public.stock_items si ON si.id = tr.item_id
           WHERE tr.test_id = NEW.test_id
  LOOP
    INSERT INTO public.stock_movements (item_id, type, quantity, unit_cost, reason, reference)
    VALUES (r.item_id, 'out', r.quantity, COALESCE(r.cost_price, 0), 'lab test',
            COALESCE(v_acc, '') || ' / ' || NEW.id::text);

    UPDATE public.stock_items
       SET quantity = COALESCE(quantity, 0) - r.quantity
     WHERE id = r.item_id;
  END LOOP;

  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_lab_consume_reagents ON public.lab_orders;
CREATE TRIGGER trg_lab_consume_reagents
  AFTER UPDATE OF status ON public.lab_orders
  FOR EACH ROW EXECUTE FUNCTION public.lab_consume_reagents();

-- =====================================================================
-- 6. BILLING — lab_tests.price finally charges something
-- =====================================================================

ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS invoice_id uuid
  REFERENCES public.invoices(id) ON DELETE SET NULL;

/* Invoice a sample: one line per test, priced from the catalogue.
 *
 * A panel price, where one is set, replaces the sum of its parts rather than
 * being added to it — that is what a panel price MEANS, and adding both is the
 * overcharge a customer notices.
 *
 * Refuses to bill twice. Re-billing is a credit note and a new invoice, not a
 * second charge quietly appended, and the sample already carries which invoice
 * it went on. */
DROP FUNCTION IF EXISTS public.lab_invoice_sample(uuid, uuid, text);
CREATE OR REPLACE FUNCTION public.lab_invoice_sample(
  p_sample_id uuid, p_client_id uuid DEFAULT NULL, p_invoice_number text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_existing uuid; v_invoice uuid; v_client uuid; v_num text; v_total numeric := 0;
  v_panel record; v_billed uuid[] := '{}';
BEGIN
  SELECT invoice_id, client_id INTO v_existing, v_client
  FROM public.lab_samples WHERE id = p_sample_id;
  IF v_existing IS NOT NULL THEN
    RAISE EXCEPTION 'This sample is already on an invoice';
  END IF;

  v_client := COALESCE(p_client_id, v_client);
  v_num := COALESCE(p_invoice_number,
                    'LAB-' || to_char(now(), 'YYYYMM') || '-' ||
                    lpad((SELECT count(*) + 1 FROM public.invoices
                          WHERE invoice_number LIKE 'LAB-' || to_char(now(), 'YYYYMM') || '-%')::text, 4, '0'));

  INSERT INTO public.invoices (client_id, invoice_number, date, status, amount)
  VALUES (v_client, v_num, CURRENT_DATE, 'pending', 0)
  RETURNING id INTO v_invoice;

  -- Panels first, so their member tests can be excluded from the per-test
  -- pass below. Only a panel whose tests are ALL present is billed as a panel;
  -- a partially ordered panel is billed test by test.
  FOR v_panel IN
    SELECT p.id, p.name, p.price
    FROM public.lab_panels p
    WHERE p.price IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.lab_panel_tests pt
        WHERE pt.panel_id = p.id
          AND NOT EXISTS (SELECT 1 FROM public.lab_orders o
                          WHERE o.sample_id = p_sample_id AND o.test_id = pt.test_id))
      AND EXISTS (SELECT 1 FROM public.lab_panel_tests pt WHERE pt.panel_id = p.id)
  LOOP
    INSERT INTO public.invoice_items (invoice_id, description, quantity, price)
    VALUES (v_invoice, v_panel.name, 1, v_panel.price);
    v_total := v_total + v_panel.price;
    SELECT v_billed || array_agg(pt.test_id) INTO v_billed
    FROM public.lab_panel_tests pt WHERE pt.panel_id = v_panel.id;
  END LOOP;

  INSERT INTO public.invoice_items (invoice_id, description, quantity, price)
  SELECT v_invoice, t.name, 1, COALESCE(t.price, 0)
  FROM public.lab_orders o
  JOIN public.lab_tests t ON t.id = o.test_id
  WHERE o.sample_id = p_sample_id
    AND NOT (o.test_id = ANY (v_billed));

  SELECT COALESCE(sum(quantity * price), 0) INTO v_total
  FROM public.invoice_items WHERE invoice_id = v_invoice;

  UPDATE public.invoices SET amount = v_total WHERE id = v_invoice;
  UPDATE public.lab_samples SET invoice_id = v_invoice WHERE id = p_sample_id;

  RETURN v_invoice;
END $$;

-- =====================================================================
-- RLS
-- =====================================================================
ALTER TABLE public.lab_qc_lots           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_rejection_reasons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_referrals         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_test_reagents     ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'lab_qc_lots','lab_rejection_reasons','lab_referrals','lab_test_reagents']) AS t
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.t || '_rw', r.t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)',
      r.t || '_rw', r.t);
  END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.lab_qc_lots, public.lab_rejection_reasons,
  public.lab_referrals, public.lab_test_reagents
  TO authenticated;
