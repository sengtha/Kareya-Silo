-- =====================================================================
-- KAREYA SILO — TAKE-OFF, VARIATIONS AND INTERIM VALUATION
-- ---------------------------------------------------------------------
-- construction-estimating.sql gave a bill a shape and gave its rates a
-- build-up. Three things are still typed numbers with nothing behind them.
--
--  1. QUANTITIES WERE TYPED. In reality a quantity is measured off a
--     drawing: so many of them, this long, this wide, this deep. Somebody
--     writes those dimensions on a take-off sheet and the quantity falls
--     out. Storing only the answer means that when a client asks where 240
--     cubic metres came from, nobody can say — and an argument about a
--     quantity is the argument a building job actually has.
--
--  2. THERE WAS NO WAY TO CHANGE AN ACCEPTED PRICE. Once a client accepts,
--     everything after is a variation: extra work, omitted work, a
--     different specification. Without them, a contractor either edits the
--     accepted bill — destroying what was agreed — or keeps the changes on
--     paper and argues about them at the end.
--
--  3. progress_claims.percent_complete WAS ONE NUMBER FOR A WHOLE PROJECT,
--     with a typed amount beside it. A real interim certificate is
--     measured item by item, cumulatively; the amount is worked out, not
--     entered; and it has to take off retention and everything already
--     certified. A single percentage cannot produce that, and getting it
--     wrong means either claiming twice for the same work or not being
--     paid for work that was done.
--
-- What is deliberately NOT here: a retention percentage, a retention cap,
-- or a release rule. Those are contract terms — they come out of whatever
-- the parties actually signed, and no two Cambodian building contracts
-- agree on them. They start at zero and the contractor sets them per job.
--
-- Idempotent. Depends on construction-estimating.sql (applied first —
-- 'construction-estimating' sorts before 'construction-valuation').
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TAKE-OFF
-- Dimensions, not answers. nr is signed so a deduction — the opening for
-- a door, a void in a slab — is a line on the sheet like any other, which
-- is how it is done on paper.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.boq_takeoff (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id     uuid NOT NULL,
  description text,                          -- 'Ground floor slab', 'Ddt door opening'
  nr          numeric DEFAULT 1 NOT NULL,    -- how many times; negative deducts
  length      numeric,
  width       numeric,
  height      numeric,
  factor      numeric,                       -- e.g. 0.5 for a triangle
  quantity    numeric DEFAULT 0 NOT NULL,    -- computed
  sort_order  integer DEFAULT 0 NOT NULL,
  notes       text,
  created_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT boq_takeoff_pkey PRIMARY KEY (id),
  CONSTRAINT boq_takeoff_item_fkey FOREIGN KEY (item_id)
    REFERENCES public.boq_items(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_boq_takeoff_item ON public.boq_takeoff (item_id, sort_order);

CREATE OR REPLACE FUNCTION public.boq_takeoff_compute()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- A dimension left blank is not zero, it is "this measurement does not
  -- have that dimension" — a linear item has a length and nothing else.
  NEW.quantity := round(
      NEW.nr
    * coalesce(NEW.length, 1)
    * coalesce(NEW.width, 1)
    * coalesce(NEW.height, 1)
    * coalesce(NEW.factor, 1), 4);
  RETURN NEW;
END;
$function$;

-- Measuring is part of preparing a bill, so it stops when the bill goes
-- out. Without this the roll-up hits the estimate's own freeze and reports
-- a confusing error about items instead of about the sheet being edited.
CREATE OR REPLACE FUNCTION public.boq_takeoff_frozen_once_issued()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_number text;
BEGIN
  SELECT e.status, e.estimate_number INTO v_status, v_number
    FROM boq_items i JOIN construction_estimates e ON e.id = i.estimate_id
   WHERE i.id = CASE TG_OP WHEN 'DELETE' THEN OLD.item_id ELSE NEW.item_id END;
  IF v_status IN ('issued', 'accepted', 'superseded') THEN
    RAISE EXCEPTION 'Estimate % has gone to the client. Measure on a new revision rather than changing the sheet behind it.', v_number;
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_takeoff_frozen ON public.boq_takeoff;
CREATE TRIGGER trg_boq_takeoff_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.boq_takeoff
  FOR EACH ROW EXECUTE FUNCTION public.boq_takeoff_frozen_once_issued();

DROP TRIGGER IF EXISTS trg_boq_takeoff_compute ON public.boq_takeoff;
CREATE TRIGGER trg_boq_takeoff_compute
  BEFORE INSERT OR UPDATE ON public.boq_takeoff
  FOR EACH ROW EXECUTE FUNCTION public.boq_takeoff_compute();

-- The item's quantity is the sheet's total. Once an item is measured, the
-- quantity stops being something anybody types.
CREATE OR REPLACE FUNCTION public.boq_takeoff_roll_up()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_item uuid; v_total numeric;
BEGIN
  v_item := CASE TG_OP WHEN 'DELETE' THEN OLD.item_id ELSE NEW.item_id END;
  SELECT coalesce(sum(quantity), 0) INTO v_total FROM boq_takeoff WHERE item_id = v_item;

  PERFORM set_config('kareya.takeoff_apply', 'on', true);
  UPDATE boq_items SET quantity = greatest(v_total, 0) WHERE id = v_item;
  PERFORM set_config('kareya.takeoff_apply', '', true);

  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_takeoff_roll_up ON public.boq_takeoff;
CREATE TRIGGER trg_boq_takeoff_roll_up
  AFTER INSERT OR UPDATE OR DELETE ON public.boq_takeoff
  FOR EACH ROW EXECUTE FUNCTION public.boq_takeoff_roll_up();

CREATE OR REPLACE FUNCTION public.boq_quantity_is_measured()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity THEN RETURN NEW; END IF;
  IF coalesce(current_setting('kareya.takeoff_apply', true), '') = 'on' THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM boq_takeoff WHERE item_id = NEW.id) THEN
    RAISE EXCEPTION 'This item is measured on a take-off sheet. Change the dimensions, not the total.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_quantity_is_measured ON public.boq_items;
CREATE TRIGGER trg_boq_quantity_is_measured
  BEFORE UPDATE OF quantity ON public.boq_items
  FOR EACH ROW EXECUTE FUNCTION public.boq_quantity_is_measured();

-- Where a quantity came from, in the form a client can be shown.
DROP FUNCTION IF EXISTS public.boq_takeoff_sheet(uuid);
CREATE OR REPLACE FUNCTION public.boq_takeoff_sheet(p_item_id uuid)
 RETURNS TABLE (
   out_line     text,
   out_dims     text,
   out_quantity numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(t.description, '—'),
         t.nr::text || ' nr'
           || coalesce(' x ' || t.length::text, '')
           || coalesce(' x ' || t.width::text, '')
           || coalesce(' x ' || t.height::text, '')
           || coalesce(' x ' || t.factor::text, ''),
         t.quantity
    FROM boq_takeoff t
   WHERE t.item_id = p_item_id
   ORDER BY t.sort_order, t.description;
$function$;

GRANT EXECUTE ON FUNCTION public.boq_takeoff_sheet(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. VARIATIONS
-- After a client accepts, the price is a contract. Everything that
-- changes it is a variation with its own number, its own instruction and
-- its own approval — never an edit to what was agreed.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.construction_variations (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  estimate_id    uuid NOT NULL,
  variation_no   text,
  title          text NOT NULL,
  instruction_ref text,                      -- the client's instruction, if there is one
  reason         text,
  status         text DEFAULT 'draft' NOT NULL,  -- draft | submitted | approved | rejected
  raised_on      date DEFAULT CURRENT_DATE,
  decided_on     date,
  decided_by     uuid,
  decision_note  text,
  notes          text,
  created_at     timestamp with time zone DEFAULT now(),
  CONSTRAINT construction_variations_pkey PRIMARY KEY (id),
  CONSTRAINT construction_variations_estimate_fkey FOREIGN KEY (estimate_id)
    REFERENCES public.construction_estimates(id) ON DELETE CASCADE,
  CONSTRAINT construction_variations_decided_by_fkey FOREIGN KEY (decided_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT construction_variations_status_check
    CHECK (status = ANY (ARRAY['draft', 'submitted', 'approved', 'rejected']))
);

CREATE INDEX IF NOT EXISTS idx_construction_variations_estimate
  ON public.construction_variations (estimate_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_construction_variations_no
  ON public.construction_variations (estimate_id, variation_no)
  WHERE variation_no IS NOT NULL;

CREATE OR REPLACE FUNCTION public.variation_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  IF NEW.variation_no IS NOT NULL AND trim(NEW.variation_no) <> '' THEN RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('variation:' || NEW.estimate_id::text));
  SELECT count(*) + 1 INTO v_n FROM construction_variations WHERE estimate_id = NEW.estimate_id;
  NEW.variation_no := 'VO' || lpad(v_n::text, 2, '0');
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_variation_number ON public.construction_variations;
CREATE TRIGGER trg_variation_number
  BEFORE INSERT ON public.construction_variations
  FOR EACH ROW EXECUTE FUNCTION public.variation_number();

-- A variation's items carry their own rates, built up the same way, and an
-- omission is a negative quantity — which is how a variation that takes
-- work out reduces the contract sum.
CREATE TABLE IF NOT EXISTS public.variation_items (
  id               uuid DEFAULT gen_random_uuid() NOT NULL,
  variation_id     uuid NOT NULL,
  code             text,
  description      text NOT NULL,
  item_type        text DEFAULT 'measured' NOT NULL,  -- measured | lump | note
  unit             text,
  quantity         numeric DEFAULT 0 NOT NULL,        -- negative omits work
  rate_template_id uuid,
  rate_cost        numeric DEFAULT 0 NOT NULL,
  rate_override    numeric,
  override_reason  text,
  rate_sell        numeric DEFAULT 0 NOT NULL,
  amount_cost      numeric DEFAULT 0 NOT NULL,
  amount_sell      numeric DEFAULT 0 NOT NULL,
  sort_order       integer DEFAULT 0 NOT NULL,
  notes            text,
  CONSTRAINT variation_items_pkey PRIMARY KEY (id),
  CONSTRAINT variation_items_variation_fkey FOREIGN KEY (variation_id)
    REFERENCES public.construction_variations(id) ON DELETE CASCADE,
  CONSTRAINT variation_items_template_fkey FOREIGN KEY (rate_template_id)
    REFERENCES public.rate_templates(id) ON DELETE SET NULL,
  CONSTRAINT variation_items_type_check
    CHECK (item_type = ANY (ARRAY['measured', 'lump', 'note']))
);

CREATE INDEX IF NOT EXISTS idx_variation_items_variation
  ON public.variation_items (variation_id, sort_order);

CREATE OR REPLACE FUNCTION public.variation_item_recalc()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_est construction_estimates; v_cost numeric;
BEGIN
  SELECT e.* INTO v_est
    FROM construction_estimates e
    JOIN construction_variations v ON v.estimate_id = e.id
   WHERE v.id = NEW.variation_id;
  IF v_est.id IS NULL THEN RAISE EXCEPTION 'That variation does not belong to an estimate'; END IF;

  IF NEW.item_type = 'note' THEN
    NEW.quantity := 0; NEW.rate_cost := 0; NEW.rate_sell := 0;
    NEW.amount_cost := 0; NEW.amount_sell := 0;
    RETURN NEW;
  END IF;

  IF NEW.rate_override IS NOT NULL THEN
    v_cost := NEW.rate_override;
  ELSIF NEW.rate_template_id IS NOT NULL THEN
    SELECT out_total INTO v_cost FROM rate_template_cost(NEW.rate_template_id);
    v_cost := coalesce(v_cost, 0);
  ELSE
    v_cost := coalesce(NEW.rate_cost, 0);
  END IF;

  IF NEW.item_type = 'lump' THEN NEW.quantity := sign(coalesce(NEW.quantity, 1)); END IF;

  NEW.rate_cost := round(v_cost, 4);
  NEW.rate_sell := round(v_cost
                         * (1 + coalesce(v_est.overhead_percent, 0) / 100.0)
                         * (1 + coalesce(v_est.margin_percent, 0) / 100.0), 4);
  NEW.amount_cost := round(NEW.quantity * NEW.rate_cost, 2);
  NEW.amount_sell := round(NEW.quantity * NEW.rate_sell, 2);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_variation_item_recalc ON public.variation_items;
CREATE TRIGGER trg_variation_item_recalc
  BEFORE INSERT OR UPDATE ON public.variation_items
  FOR EACH ROW EXECUTE FUNCTION public.variation_item_recalc();

-- An approved variation is part of the contract. It stops being editable
-- for the same reason an issued estimate does.
CREATE OR REPLACE FUNCTION public.variation_is_frozen_once_decided()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_no text;
BEGIN
  SELECT status, variation_no INTO v_status, v_no FROM construction_variations
   WHERE id = CASE TG_OP WHEN 'DELETE' THEN OLD.variation_id ELSE NEW.variation_id END;
  IF v_status IN ('approved', 'rejected')
     AND coalesce(current_setting('kareya.variation_apply', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Variation % has been %. Raise another one rather than changing it.', v_no, v_status;
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_variation_items_frozen ON public.variation_items;
CREATE TRIGGER trg_variation_items_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.variation_items
  FOR EACH ROW EXECUTE FUNCTION public.variation_is_frozen_once_decided();

CREATE OR REPLACE FUNCTION public.decide_variation(
  p_variation_id uuid, p_approve boolean, p_note text DEFAULT NULL)
 RETURNS public.construction_variations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_var construction_variations; v_n integer;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('site manager', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot decide a variation';
  END IF;

  SELECT * INTO v_var FROM construction_variations WHERE id = p_variation_id FOR UPDATE;
  IF v_var.id IS NULL THEN RAISE EXCEPTION 'That variation does not exist'; END IF;
  IF v_var.status IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Variation % is already %', v_var.variation_no, v_var.status;
  END IF;
  IF NOT p_approve AND coalesce(trim(p_note), '') = '' THEN
    RAISE EXCEPTION 'Turning down a variation needs a reason';
  END IF;

  SELECT count(*) INTO v_n FROM variation_items
   WHERE variation_id = p_variation_id AND item_type <> 'note';
  IF p_approve AND v_n = 0 THEN
    RAISE EXCEPTION 'There is nothing priced in variation %', v_var.variation_no;
  END IF;

  UPDATE construction_variations
     SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         decided_on = CURRENT_DATE, decided_by = v_emp.id, decision_note = p_note
   WHERE id = p_variation_id
  RETURNING * INTO v_var;
  RETURN v_var;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.decide_variation(uuid, boolean, text) TO authenticated;

-- What the job is now worth: what was accepted, plus every variation that
-- has been approved. Nothing pending counts.
DROP FUNCTION IF EXISTS public.contract_sum(uuid);
CREATE OR REPLACE FUNCTION public.contract_sum(p_estimate_id uuid)
 RETURNS TABLE (
   out_original    numeric,
   out_variations  numeric,
   out_pending     numeric,
   out_contract    numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    orig.total,
    coalesce(appr.total, 0),
    coalesce(pend.total, 0),
    orig.total + coalesce(appr.total, 0)
  FROM (SELECT round(coalesce(sum(amount_sell), 0), 2) AS total
          FROM boq_items WHERE estimate_id = p_estimate_id AND item_type <> 'note') orig
  LEFT JOIN LATERAL (
    SELECT round(coalesce(sum(vi.amount_sell), 0), 2) AS total
      FROM variation_items vi
      JOIN construction_variations v ON v.id = vi.variation_id
     WHERE v.estimate_id = p_estimate_id AND v.status = 'approved' AND vi.item_type <> 'note') appr ON true
  LEFT JOIN LATERAL (
    SELECT round(coalesce(sum(vi.amount_sell), 0), 2) AS total
      FROM variation_items vi
      JOIN construction_variations v ON v.id = vi.variation_id
     WHERE v.estimate_id = p_estimate_id AND v.status IN ('draft', 'submitted')
       AND vi.item_type <> 'note') pend ON true;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_sum(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. INTERIM VALUATION
-- Measured item by item, cumulatively. Quantities are what has been done
-- TO DATE, not this month — so the certificate pays the difference and the
-- same work cannot be claimed twice however the months are cut.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.interim_valuations (
  id                 uuid DEFAULT gen_random_uuid() NOT NULL,
  estimate_id        uuid NOT NULL,
  valuation_no       integer,
  period_to          date DEFAULT CURRENT_DATE NOT NULL,
  -- Contract terms. Zero because no two building contracts agree, and a
  -- default here would quietly become somebody's contract.
  retention_percent  numeric DEFAULT 0 NOT NULL,
  retention_cap_pct  numeric DEFAULT 0 NOT NULL,   -- 0 = no cap
  retention_released numeric DEFAULT 0 NOT NULL,
  status             text DEFAULT 'draft' NOT NULL, -- draft | submitted | certified | paid
  certified_on       date,
  certified_by       uuid,
  notes              text,
  created_at         timestamp with time zone DEFAULT now(),
  CONSTRAINT interim_valuations_pkey PRIMARY KEY (id),
  CONSTRAINT interim_valuations_estimate_fkey FOREIGN KEY (estimate_id)
    REFERENCES public.construction_estimates(id) ON DELETE CASCADE,
  CONSTRAINT interim_valuations_certified_by_fkey FOREIGN KEY (certified_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT interim_valuations_status_check
    CHECK (status = ANY (ARRAY['draft', 'submitted', 'certified', 'paid'])),
  CONSTRAINT interim_valuations_retention_check
    CHECK (retention_percent >= 0 AND retention_percent <= 100),
  CONSTRAINT interim_valuations_cap_check CHECK (retention_cap_pct >= 0),
  CONSTRAINT interim_valuations_released_check CHECK (retention_released >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_interim_valuations_no
  ON public.interim_valuations (estimate_id, valuation_no);

CREATE OR REPLACE FUNCTION public.interim_valuation_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_open integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('valuation:' || NEW.estimate_id::text));
  -- Only one valuation open at a time. Two drafts measuring the same job
  -- to date is how the same work gets certified twice.
  SELECT count(*) INTO v_open FROM interim_valuations
   WHERE estimate_id = NEW.estimate_id AND status IN ('draft', 'submitted');
  IF v_open > 0 THEN
    RAISE EXCEPTION 'There is already a valuation open on this job. Certify it before starting the next.';
  END IF;
  IF NEW.valuation_no IS NULL THEN
    SELECT coalesce(max(valuation_no), 0) + 1 INTO NEW.valuation_no
      FROM interim_valuations WHERE estimate_id = NEW.estimate_id;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_interim_valuation_number ON public.interim_valuations;
CREATE TRIGGER trg_interim_valuation_number
  BEFORE INSERT ON public.interim_valuations
  FOR EACH ROW EXECUTE FUNCTION public.interim_valuation_number();

CREATE TABLE IF NOT EXISTS public.valuation_items (
  id                uuid DEFAULT gen_random_uuid() NOT NULL,
  valuation_id      uuid NOT NULL,
  boq_item_id       uuid,
  variation_item_id uuid,
  quantity_to_date  numeric DEFAULT 0 NOT NULL,
  value_to_date     numeric DEFAULT 0 NOT NULL,
  notes             text,
  CONSTRAINT valuation_items_pkey PRIMARY KEY (id),
  CONSTRAINT valuation_items_valuation_fkey FOREIGN KEY (valuation_id)
    REFERENCES public.interim_valuations(id) ON DELETE CASCADE,
  CONSTRAINT valuation_items_boq_fkey FOREIGN KEY (boq_item_id)
    REFERENCES public.boq_items(id) ON DELETE CASCADE,
  CONSTRAINT valuation_items_variation_fkey FOREIGN KEY (variation_item_id)
    REFERENCES public.variation_items(id) ON DELETE CASCADE,
  CONSTRAINT valuation_items_one_target CHECK (
    (boq_item_id IS NOT NULL AND variation_item_id IS NULL) OR
    (boq_item_id IS NULL AND variation_item_id IS NOT NULL)),
  CONSTRAINT valuation_items_qty_check CHECK (quantity_to_date >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_valuation_items_boq
  ON public.valuation_items (valuation_id, boq_item_id) WHERE boq_item_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_valuation_items_variation
  ON public.valuation_items (valuation_id, variation_item_id) WHERE variation_item_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.valuation_item_compute()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rate numeric; v_max numeric; v_desc text; v_est uuid; v_status text;
BEGIN
  SELECT estimate_id, status INTO v_est, v_status
    FROM interim_valuations WHERE id = NEW.valuation_id;
  IF v_status IN ('certified', 'paid')
     AND coalesce(current_setting('kareya.valuation_apply', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This valuation has been certified. Measure the next one instead.';
  END IF;

  IF NEW.boq_item_id IS NOT NULL THEN
    SELECT rate_sell, quantity, description INTO v_rate, v_max, v_desc
      FROM boq_items WHERE id = NEW.boq_item_id;
    IF NOT EXISTS (SELECT 1 FROM boq_items WHERE id = NEW.boq_item_id AND estimate_id = v_est) THEN
      RAISE EXCEPTION 'That item is not in this job''s bill';
    END IF;
  ELSE
    SELECT vi.rate_sell, abs(vi.quantity), vi.description INTO v_rate, v_max, v_desc
      FROM variation_items vi
      JOIN construction_variations v ON v.id = vi.variation_id
     WHERE vi.id = NEW.variation_item_id AND v.estimate_id = v_est AND v.status = 'approved';
    IF v_rate IS NULL THEN
      RAISE EXCEPTION 'That variation item is not approved on this job, so it cannot be valued';
    END IF;
  END IF;

  -- Measuring more than the bill holds is not a valuation, it is a
  -- variation that nobody has raised.
  IF NEW.quantity_to_date > coalesce(v_max, 0) + 0.0001 THEN
    RAISE EXCEPTION 'Measured % of "%" but the bill only holds %. Raise a variation for the extra.',
      NEW.quantity_to_date, v_desc, v_max;
  END IF;

  NEW.value_to_date := round(NEW.quantity_to_date * coalesce(v_rate, 0), 2);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_valuation_item_compute ON public.valuation_items;
CREATE TRIGGER trg_valuation_item_compute
  BEFORE INSERT OR UPDATE ON public.valuation_items
  FOR EACH ROW EXECUTE FUNCTION public.valuation_item_compute();

-- Work already certified does not un-happen. A later valuation cannot
-- measure less of an item than a certified one already did.
CREATE OR REPLACE FUNCTION public.valuation_no_going_backwards()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_prev numeric; v_est uuid; v_no integer;
BEGIN
  SELECT estimate_id, valuation_no INTO v_est, v_no
    FROM interim_valuations WHERE id = NEW.valuation_id;

  SELECT max(vi.quantity_to_date) INTO v_prev
    FROM valuation_items vi
    JOIN interim_valuations v ON v.id = vi.valuation_id
   WHERE v.estimate_id = v_est
     AND v.valuation_no < v_no
     AND v.status IN ('certified', 'paid')
     AND vi.boq_item_id IS NOT DISTINCT FROM NEW.boq_item_id
     AND vi.variation_item_id IS NOT DISTINCT FROM NEW.variation_item_id;

  IF v_prev IS NOT NULL AND NEW.quantity_to_date < v_prev - 0.0001 THEN
    RAISE EXCEPTION 'A certified valuation already measured % of this item. Work that has been certified cannot be measured back down; correct it with a variation.',
      v_prev;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_valuation_no_going_backwards ON public.valuation_items;
CREATE TRIGGER trg_valuation_no_going_backwards
  BEFORE INSERT OR UPDATE ON public.valuation_items
  FOR EACH ROW EXECUTE FUNCTION public.valuation_no_going_backwards();

-- ---------------------------------------------------------------------
-- 4. THE CERTIFICATE
-- Gross to date, less retention, less what was certified before, equals
-- what is due now. Every figure worked out, none of them typed.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.valuation_certificate(uuid);
CREATE OR REPLACE FUNCTION public.valuation_certificate(p_valuation_id uuid)
 RETURNS TABLE (
   out_valuation_no      integer,
   out_period_to         date,
   out_contract_sum      numeric,
   out_gross_to_date     numeric,
   out_retention_pct     numeric,
   out_retention_held    numeric,
   out_retention_released numeric,
   out_net_to_date       numeric,
   out_previously_certified numeric,
   out_due_now           numeric,
   out_percent_complete  numeric
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_val interim_valuations;
  v_contract numeric; v_gross numeric; v_ret numeric; v_cap numeric;
  v_prev numeric;
BEGIN
  SELECT * INTO v_val FROM interim_valuations WHERE id = p_valuation_id;
  IF v_val.id IS NULL THEN RAISE EXCEPTION 'That valuation does not exist'; END IF;

  SELECT out_contract INTO v_contract FROM contract_sum(v_val.estimate_id);

  SELECT round(coalesce(sum(value_to_date), 0), 2) INTO v_gross
    FROM valuation_items WHERE valuation_id = p_valuation_id;

  v_ret := round(v_gross * v_val.retention_percent / 100.0, 2);
  -- Retention is commonly capped at a share of the contract sum. Zero here
  -- means the contract said nothing, so nothing is capped.
  IF v_val.retention_cap_pct > 0 THEN
    v_cap := round(coalesce(v_contract, 0) * v_val.retention_cap_pct / 100.0, 2);
    v_ret := least(v_ret, v_cap);
  END IF;
  v_ret := greatest(v_ret - coalesce(v_val.retention_released, 0), 0);

  -- What earlier certificates already paid. Only certified ones count.
  SELECT round(coalesce(sum(x.net), 0), 2) INTO v_prev
    FROM (
      SELECT greatest(
               round(coalesce((SELECT sum(vi.value_to_date) FROM valuation_items vi
                                WHERE vi.valuation_id = v.id), 0), 2)
               * (1 - v.retention_percent / 100.0), 0) AS net
        FROM interim_valuations v
       WHERE v.estimate_id = v_val.estimate_id
         AND v.valuation_no < v_val.valuation_no
         AND v.status IN ('certified', 'paid')
       ORDER BY v.valuation_no DESC
       LIMIT 1
    ) x;

  out_valuation_no := v_val.valuation_no;
  out_period_to := v_val.period_to;
  out_contract_sum := coalesce(v_contract, 0);
  out_gross_to_date := v_gross;
  out_retention_pct := v_val.retention_percent;
  out_retention_held := v_ret;
  out_retention_released := coalesce(v_val.retention_released, 0);
  out_net_to_date := round(v_gross - v_ret, 2);
  out_previously_certified := coalesce(v_prev, 0);
  out_due_now := round(v_gross - v_ret - coalesce(v_prev, 0), 2);
  out_percent_complete := CASE WHEN coalesce(v_contract, 0) = 0 THEN 0
                               ELSE round(100 * v_gross / v_contract, 2) END;
  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.valuation_certificate(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.certify_valuation(p_valuation_id uuid)
 RETURNS public.interim_valuations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_val interim_valuations; v_n integer;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('site manager', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot certify a valuation';
  END IF;

  SELECT * INTO v_val FROM interim_valuations WHERE id = p_valuation_id FOR UPDATE;
  IF v_val.id IS NULL THEN RAISE EXCEPTION 'That valuation does not exist'; END IF;
  IF v_val.status IN ('certified', 'paid') THEN
    RAISE EXCEPTION 'Valuation % is already %', v_val.valuation_no, v_val.status;
  END IF;

  SELECT count(*) INTO v_n FROM valuation_items WHERE valuation_id = p_valuation_id;
  IF v_n = 0 THEN RAISE EXCEPTION 'Nothing has been measured on this valuation'; END IF;

  UPDATE interim_valuations
     SET status = 'certified', certified_on = CURRENT_DATE, certified_by = v_emp.id
   WHERE id = p_valuation_id
  RETURNING * INTO v_val;
  RETURN v_val;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.certify_valuation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.valuation_is_frozen_once_certified()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('certified', 'paid') THEN
      RAISE EXCEPTION 'A certified valuation cannot be deleted. It is what was paid against.';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.status IN ('certified', 'paid')
     AND NEW.status NOT IN ('certified', 'paid')
     AND coalesce(current_setting('kareya.valuation_apply', true), '') <> 'on' THEN
    RAISE EXCEPTION 'A certified valuation cannot be reopened. Measure the next one.';
  END IF;
  IF OLD.status IN ('certified', 'paid')
     AND (NEW.retention_percent IS DISTINCT FROM OLD.retention_percent
       OR NEW.retention_released IS DISTINCT FROM OLD.retention_released
       OR NEW.period_to IS DISTINCT FROM OLD.period_to) THEN
    RAISE EXCEPTION 'The figures on a certified valuation cannot be changed.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_valuation_frozen ON public.interim_valuations;
CREATE TRIGGER trg_valuation_frozen
  BEFORE UPDATE OR DELETE ON public.interim_valuations
  FOR EACH ROW EXECUTE FUNCTION public.valuation_is_frozen_once_certified();

-- Where the job stands: what has been certified, what is still to come.
DROP FUNCTION IF EXISTS public.job_financial_position(uuid);
CREATE OR REPLACE FUNCTION public.job_financial_position(p_estimate_id uuid)
 RETURNS TABLE (
   out_contract_sum   numeric,
   out_certified      numeric,
   out_retention_held numeric,
   out_remaining      numeric,
   out_cost_to_date   numeric,
   out_margin_to_date numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- Before anything is certified there is a contract and nothing else.
  -- Calling the certificate with no valuation would be an error, not a zero.
  WITH latest AS (
    SELECT v.id FROM interim_valuations v
     WHERE v.estimate_id = p_estimate_id AND v.status IN ('certified', 'paid')
     ORDER BY v.valuation_no DESC LIMIT 1
  ),
  cert AS (
    SELECT coalesce(c.out_gross_to_date, 0) AS gross,
           coalesce(c.out_retention_held, 0) AS ret
      FROM (SELECT 1) z
      LEFT JOIN LATERAL (
        SELECT * FROM valuation_certificate((SELECT id FROM latest))
         WHERE EXISTS (SELECT 1 FROM latest)
      ) c ON true
  ),
  -- Cost of what has been certified, at the estimate's own cost rates.
  costs AS (
    SELECT round(coalesce(sum(vi.quantity_to_date * b.rate_cost), 0), 2) AS c
      FROM valuation_items vi
      JOIN boq_items b ON b.id = vi.boq_item_id
     WHERE vi.valuation_id = (SELECT id FROM latest)
  )
  SELECT cs.out_contract, cert.gross, cert.ret,
         round(cs.out_contract - cert.gross, 2),
         costs.c,
         round(cert.gross - costs.c, 2)
    FROM contract_sum(p_estimate_id) cs, cert, costs;
$function$;

GRANT EXECUTE ON FUNCTION public.job_financial_position(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['boq_takeoff', 'construction_variations', 'variation_items',
                           'interim_valuations', 'valuation_items']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Accountant', 'Manager']))$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
