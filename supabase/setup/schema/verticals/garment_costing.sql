-- =====================================================================
-- KAREYA SILO — GARMENT COST SHEET (garment_costing)
-- ---------------------------------------------------------------------
-- garment_styles.cmt_price is one typed number per piece, and
-- garment_orders.cmt_price is another one typed on the purchase order.
-- That is the same defect construction_boq.unit_rate had, in the industry
-- that employs more Cambodians than any other.
--
--  1. THE PRICE HAD NOTHING BEHIND IT. A CMT price is built up: fabric
--     consumption per piece with its wastage, every trim (buttons, zip,
--     thread, labels, poly bag, carton), the sewing cost, factory overhead,
--     commercial costs and margin. With only the answer stored, nobody can
--     say what an 8% rise in cotton does to a quoted price — and on an FOB
--     quote fabric is most of the cost, so that question is the whole job.
--
--  2. THE SEWING COST IGNORED EFFICIENCY, WHICH IS THE WHOLE OF IT. The
--     style already carries SMV — the standard minutes of work in one
--     piece. But a line does not deliver a standard minute in a minute. At
--     50% efficiency a 20-SMV garment consumes 40 real minutes of a line
--     that costs money every one of them. Quote at 75% and run at 50% and
--     the sewing cost is half what was charged for. Nothing here connected
--     the two.
--
--  3. AND THE FACTORY ALREADY KNOWS ITS REAL EFFICIENCY. garment_outputs
--     records efficiency_pct on every daily output row. The number needed
--     to price honestly was already in the database and the quote never
--     looked at it. This file makes that comparison a reported fact:
--     styles quoted at an efficiency the lines have never achieved.
--
--  4. ONE-OFF COSTS WERE NOT AMORTISED. Sampling, marker making, lab
--     testing and an inspection visit cost the same whether the order is
--     5,000 pieces or 50,000. Per piece that is 10x different, which is
--     why buyers ask for a price at each quantity and why a factory that
--     quotes one number for all of them loses on the small orders.
--
-- What is deliberately NOT here: an SMV, an efficiency, a fabric
-- consumption, a wastage percentage, a cost per minute, or any price.
-- Those are the factory's own industrial engineering and its own costs.
-- A shipped default would be quoted to a buyer.
--
-- Idempotent. Depends on garment.sql for the styles and the daily output
-- rows, and on construction-estimating.sql for the shared price book.
--
-- The underscore in the filename is not a typo, and it is the second time
-- this has bitten: verticals apply in alphabetical order and
-- 'garment-costing.sql' sorts BEFORE 'garment.sql', because a hyphen sorts
-- before a dot. library_integrity.sql carries the same note for the same
-- reason. Any file that extends another vertical needs a name that sorts
-- after it.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHAT A MINUTE OF SEWING COSTS
-- The cost of running a line for a month, over the minutes that line can
-- actually offer. Everything about garment costing hangs off this figure
-- and off efficiency.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.garment_line_costs (
  id              uuid DEFAULT gen_random_uuid() NOT NULL,
  line_id         uuid,                          -- NULL = a factory-wide default
  name            text NOT NULL,
  monthly_cost    numeric DEFAULT 0 NOT NULL,    -- wages, supervision, power, rent, depreciation
  workers         integer DEFAULT 0 NOT NULL,
  hours_per_day   numeric DEFAULT 8 NOT NULL,
  days_per_month  numeric DEFAULT 26 NOT NULL,
  cost_source     text,                          -- where the monthly figure came from
  effective_from  date DEFAULT CURRENT_DATE,
  is_active       boolean DEFAULT true,
  notes           text,
  created_at      timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_line_costs_pkey PRIMARY KEY (id),
  CONSTRAINT garment_line_costs_line_fkey FOREIGN KEY (line_id)
    REFERENCES public.garment_lines(id) ON DELETE CASCADE,
  CONSTRAINT garment_line_costs_amount_check CHECK (monthly_cost >= 0),
  CONSTRAINT garment_line_costs_workers_check CHECK (workers >= 0),
  CONSTRAINT garment_line_costs_hours_check CHECK (hours_per_day > 0 AND days_per_month > 0)
);

CREATE INDEX IF NOT EXISTS idx_garment_line_costs_line ON public.garment_line_costs (line_id);

-- Minutes a line can offer in a month, before any allowance for how much
-- of that time turns into garments.
CREATE OR REPLACE FUNCTION public.garment_available_minutes(p_cost_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT round(c.workers * c.hours_per_day * c.days_per_month * 60, 2)
    FROM garment_line_costs c WHERE c.id = p_cost_id;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_available_minutes(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.garment_cost_per_minute(p_cost_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN garment_available_minutes(p_cost_id) > 0
              THEN round(c.monthly_cost / garment_available_minutes(p_cost_id), 6)
              ELSE 0 END
    FROM garment_line_costs c WHERE c.id = p_cost_id;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_cost_per_minute(uuid) TO authenticated;

-- What the lines have ACTUALLY achieved, from the daily output rows the
-- factory already books. This is the number a quote should be checked
-- against, and it was sitting here unused.
DROP FUNCTION IF EXISTS public.garment_achieved_efficiency(uuid, date, date);
CREATE OR REPLACE FUNCTION public.garment_achieved_efficiency(
  p_line_id uuid DEFAULT NULL, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
 RETURNS TABLE (
   out_line      text,
   out_days      integer,
   out_avg_pct   numeric,
   out_best_pct  numeric,
   out_worst_pct numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(l.name, '—'),
         count(*)::integer,
         round(avg(o.efficiency_pct), 2),
         round(max(o.efficiency_pct), 2),
         round(min(o.efficiency_pct), 2)
    FROM garment_outputs o
    LEFT JOIN garment_lines l ON l.id = o.line_id
   WHERE (p_line_id IS NULL OR o.line_id = p_line_id)
     AND (p_from IS NULL OR o.date >= p_from)
     AND (p_to IS NULL OR o.date <= p_to)
     AND coalesce(o.efficiency_pct, 0) > 0
   GROUP BY l.name;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_achieved_efficiency(uuid, date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. THE COST SHEET
-- One per style per quantity. A buyer asking for a price at 5,000 and at
-- 20,000 is asking two different questions, because the one-off costs
-- divide differently.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.garment_cost_sheets (
  id               uuid DEFAULT gen_random_uuid() NOT NULL,
  style_id         uuid NOT NULL,
  revision         text DEFAULT 'A' NOT NULL,
  buyer            text,
  -- cmt: the buyer supplies fabric and trims, so the factory charges for
  --      cutting, making and trimming only.
  -- fob: the factory buys everything and the price includes it.
  basis            text DEFAULT 'cmt' NOT NULL,
  order_quantity   numeric DEFAULT 0 NOT NULL,     -- what the one-off costs divide by
  line_cost_id     uuid,                           -- whose minute this is priced on
  -- The efficiency the price ASSUMES. Kept beside what the lines achieved,
  -- because the gap between them is where a garment factory loses money.
  assumed_efficiency_pct numeric DEFAULT 0 NOT NULL,
  overhead_percent numeric DEFAULT 0 NOT NULL,     -- on top of direct cost
  margin_percent   numeric DEFAULT 0 NOT NULL,
  currency         text DEFAULT 'USD',
  status           text DEFAULT 'draft' NOT NULL,  -- draft | quoted | agreed | lost | superseded
  quoted_on        date,
  agreed_on        date,
  agreed_price     numeric,                        -- what the buyer actually agreed to
  prepared_by      uuid,
  notes            text,
  created_at       timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_cost_sheets_pkey PRIMARY KEY (id),
  CONSTRAINT garment_cost_sheets_style_fkey FOREIGN KEY (style_id)
    REFERENCES public.garment_styles(id) ON DELETE CASCADE,
  CONSTRAINT garment_cost_sheets_line_cost_fkey FOREIGN KEY (line_cost_id)
    REFERENCES public.garment_line_costs(id) ON DELETE SET NULL,
  CONSTRAINT garment_cost_sheets_prepared_by_fkey FOREIGN KEY (prepared_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT garment_cost_sheets_basis_check CHECK (basis = ANY (ARRAY['cmt', 'fob'])),
  CONSTRAINT garment_cost_sheets_status_check
    CHECK (status = ANY (ARRAY['draft', 'quoted', 'agreed', 'lost', 'superseded'])),
  CONSTRAINT garment_cost_sheets_qty_check CHECK (order_quantity >= 0),
  CONSTRAINT garment_cost_sheets_eff_check
    CHECK (assumed_efficiency_pct >= 0 AND assumed_efficiency_pct <= 100),
  CONSTRAINT garment_cost_sheets_pct_check CHECK (overhead_percent >= 0 AND margin_percent >= 0)
);

CREATE INDEX IF NOT EXISTS idx_garment_cost_sheets_style ON public.garment_cost_sheets (style_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_garment_cost_sheets_rev
  ON public.garment_cost_sheets (style_id, order_quantity, revision);

CREATE TABLE IF NOT EXISTS public.garment_cost_lines (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  sheet_id      uuid NOT NULL,
  -- fabric     : the shell and lining, measured per piece
  -- trim       : buttons, zip, thread, labels, poly bag, carton
  -- cm         : the sewing itself, from SMV x cost per minute
  -- overhead   : anything charged per piece rather than as a percentage
  -- commercial : testing, inspection, bank charges, sampling
  -- freight    : to the port, on an FOB quote
  category      text DEFAULT 'trim' NOT NULL,
  description   text NOT NULL,
  resource_id   uuid,                            -- from the shared price book
  unit          text,
  -- Per piece for an ordinary line. For a one-off it is the TOTAL, and it
  -- is divided by the order quantity.
  consumption   numeric DEFAULT 0 NOT NULL,
  unit_cost     numeric DEFAULT 0 NOT NULL,
  wastage_percent numeric DEFAULT 0 NOT NULL,
  is_one_off    boolean DEFAULT false NOT NULL,
  amount        numeric DEFAULT 0 NOT NULL,      -- computed, per piece
  sort_order    integer DEFAULT 0 NOT NULL,
  notes         text,
  CONSTRAINT garment_cost_lines_pkey PRIMARY KEY (id),
  CONSTRAINT garment_cost_lines_sheet_fkey FOREIGN KEY (sheet_id)
    REFERENCES public.garment_cost_sheets(id) ON DELETE CASCADE,
  CONSTRAINT garment_cost_lines_resource_fkey FOREIGN KEY (resource_id)
    REFERENCES public.estimate_resources(id) ON DELETE RESTRICT,
  CONSTRAINT garment_cost_lines_category_check
    CHECK (category = ANY (ARRAY['fabric', 'trim', 'cm', 'overhead', 'commercial', 'freight'])),
  CONSTRAINT garment_cost_lines_consumption_check CHECK (consumption >= 0),
  CONSTRAINT garment_cost_lines_cost_check CHECK (unit_cost >= 0),
  CONSTRAINT garment_cost_lines_wastage_check CHECK (wastage_percent >= 0 AND wastage_percent < 100)
);

CREATE INDEX IF NOT EXISTS idx_garment_cost_lines_sheet ON public.garment_cost_lines (sheet_id, sort_order);

-- ---------------------------------------------------------------------
-- 3. THE ARITHMETIC
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.garment_cost_line_compute()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_sheet garment_cost_sheets; v_cost numeric; v_qty numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = NEW.sheet_id;
  IF v_sheet.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;

  -- A line tied to the price book takes its price from there, so a fabric
  -- price change reaches every sheet built on it.
  IF NEW.resource_id IS NOT NULL THEN
    SELECT unit_cost INTO v_cost FROM estimate_resources WHERE id = NEW.resource_id;
    NEW.unit_cost := coalesce(v_cost, 0);
  END IF;

  IF NEW.is_one_off THEN
    -- Sampling and testing cost the same whatever the order size. Per piece
    -- they are ten times different between 5,000 and 50,000, which is the
    -- whole reason a buyer asks for a price at each quantity.
    v_qty := coalesce(v_sheet.order_quantity, 0);
    NEW.amount := CASE WHEN v_qty > 0
                       THEN round(NEW.consumption * NEW.unit_cost / v_qty, 6)
                       ELSE 0 END;
  ELSE
    NEW.amount := round(NEW.consumption * (1 + NEW.wastage_percent / 100.0) * NEW.unit_cost, 6);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_garment_cost_line_compute ON public.garment_cost_lines;
CREATE TRIGGER trg_garment_cost_line_compute
  BEFORE INSERT OR UPDATE ON public.garment_cost_lines
  FOR EACH ROW EXECUTE FUNCTION public.garment_cost_line_compute();

-- The sewing cost, which the old single price hid completely.
--
--   real minutes per piece = SMV / (efficiency / 100)
--   CM per piece           = real minutes x cost per available minute
--
-- At 50% efficiency a 20-SMV garment occupies 40 minutes of a line that is
-- being paid for all 40.
CREATE OR REPLACE FUNCTION public.garment_cm_cost(p_sheet_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE v_sheet garment_cost_sheets; v_smv numeric; v_cpm numeric; v_minutes numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = p_sheet_id;
  IF v_sheet.id IS NULL THEN RETURN 0; END IF;
  IF v_sheet.line_cost_id IS NULL OR coalesce(v_sheet.assumed_efficiency_pct, 0) <= 0 THEN
    RETURN 0;
  END IF;

  SELECT smv INTO v_smv FROM garment_styles WHERE id = v_sheet.style_id;
  IF coalesce(v_smv, 0) <= 0 THEN RETURN 0; END IF;

  v_cpm := garment_cost_per_minute(v_sheet.line_cost_id);
  v_minutes := v_smv / (v_sheet.assumed_efficiency_pct / 100.0);
  RETURN round(v_minutes * v_cpm, 6);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_cm_cost(uuid) TO authenticated;

-- The sheet, category by category, the way a merchandiser reads one. The
-- sewing cost is derived rather than stored, so it joins the stored lines
-- here instead of being a row somebody typed.
DROP FUNCTION IF EXISTS public.garment_cost_breakdown(uuid);
CREATE OR REPLACE FUNCTION public.garment_cost_breakdown(p_sheet_id uuid)
 RETURNS TABLE (
   out_category  text,
   out_amount    numeric,
   out_share_pct numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH parts AS (
    SELECT l.category AS c, sum(l.amount) AS a
      FROM garment_cost_lines l
      JOIN garment_cost_sheets s ON s.id = l.sheet_id
     WHERE l.sheet_id = p_sheet_id
       -- On a CMT quote the buyer supplies fabric and trims, so they are
       -- not the factory's to charge for.
       AND NOT (s.basis = 'cmt' AND l.category IN ('fabric', 'trim'))
     GROUP BY l.category
    UNION ALL
    SELECT 'cm', garment_cm_cost(p_sheet_id)
  ),
  rolled AS (SELECT c, sum(a) AS a FROM parts GROUP BY c),
  tot AS (SELECT sum(a) AS t FROM rolled)
  SELECT r.c, round(r.a, 4),
         CASE WHEN coalesce(tot.t, 0) = 0 THEN 0 ELSE round(100 * r.a / tot.t, 2) END
    FROM rolled r, tot
   WHERE r.a <> 0
   ORDER BY array_position(ARRAY['fabric', 'trim', 'cm', 'overhead', 'commercial', 'freight'], r.c);
$function$;

GRANT EXECUTE ON FUNCTION public.garment_cost_breakdown(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.garment_sheet_summary(uuid);
CREATE OR REPLACE FUNCTION public.garment_sheet_summary(p_sheet_id uuid)
 RETURNS TABLE (
   out_fabric      numeric,
   out_trim        numeric,
   out_cm          numeric,
   out_overhead    numeric,
   out_commercial  numeric,
   out_freight     numeric,
   out_direct_cost numeric,
   out_with_overhead numeric,
   out_price       numeric,
   out_margin      numeric,
   out_margin_pct  numeric,
   out_order_value numeric
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sheet garment_cost_sheets;
  v_f numeric; v_t numeric; v_o numeric; v_c numeric; v_fr numeric;
  v_cm numeric; v_direct numeric; v_oh numeric; v_price numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = p_sheet_id;
  IF v_sheet.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;

  SELECT
    coalesce(sum(amount) FILTER (WHERE category = 'fabric'), 0),
    coalesce(sum(amount) FILTER (WHERE category = 'trim'), 0),
    coalesce(sum(amount) FILTER (WHERE category = 'overhead'), 0),
    coalesce(sum(amount) FILTER (WHERE category = 'commercial'), 0),
    coalesce(sum(amount) FILTER (WHERE category = 'freight'), 0)
  INTO v_f, v_t, v_o, v_c, v_fr
  FROM garment_cost_lines WHERE sheet_id = p_sheet_id;

  -- A CMT quote is for the making only: the buyer supplies fabric and trims,
  -- so charging for them would be charging twice.
  IF v_sheet.basis = 'cmt' THEN v_f := 0; v_t := 0; END IF;

  v_cm := garment_cm_cost(p_sheet_id)
        + coalesce((SELECT sum(amount) FROM garment_cost_lines
                     WHERE sheet_id = p_sheet_id AND category = 'cm'), 0);

  v_direct := v_f + v_t + v_cm + v_o + v_c + v_fr;
  v_oh := round(v_direct * (1 + coalesce(v_sheet.overhead_percent, 0) / 100.0), 6);
  v_price := round(v_oh * (1 + coalesce(v_sheet.margin_percent, 0) / 100.0), 4);

  out_fabric := round(v_f, 4); out_trim := round(v_t, 4); out_cm := round(v_cm, 4);
  out_overhead := round(v_o, 4); out_commercial := round(v_c, 4); out_freight := round(v_fr, 4);
  out_direct_cost := round(v_direct, 4);
  out_with_overhead := round(v_oh, 4);
  out_price := v_price;
  out_margin := round(v_price - v_direct, 4);
  out_margin_pct := CASE WHEN v_price = 0 THEN 0 ELSE round(100 * (v_price - v_direct) / v_price, 2) END;
  out_order_value := round(v_price * coalesce(v_sheet.order_quantity, 0), 2);
  RETURN NEXT;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_sheet_summary(uuid) TO authenticated;

-- What a different efficiency would do to the price. The question a
-- merchandiser and a production manager should be arguing about before a
-- price goes to a buyer, not after the order is running.
DROP FUNCTION IF EXISTS public.garment_efficiency_sensitivity(uuid, numeric[]);
CREATE OR REPLACE FUNCTION public.garment_efficiency_sensitivity(
  p_sheet_id uuid, p_efficiencies numeric[] DEFAULT ARRAY[40, 50, 60, 70, 80])
 RETURNS TABLE (out_efficiency numeric, out_cm numeric, out_price numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sheet garment_cost_sheets; v_smv numeric; v_cpm numeric;
  v_base numeric; e numeric; v_cm numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = p_sheet_id;
  IF v_sheet.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;
  SELECT smv INTO v_smv FROM garment_styles WHERE id = v_sheet.style_id;
  v_cpm := CASE WHEN v_sheet.line_cost_id IS NULL THEN 0
                ELSE garment_cost_per_minute(v_sheet.line_cost_id) END;

  -- Everything except the sewing, which is the only part efficiency moves.
  -- Both sides are aliased: this function's own OUT parameter is also called
  -- out_cm, and an unqualified reference means the wrong one.
  SELECT sum.out_direct_cost - sum.out_cm INTO v_base
    FROM garment_sheet_summary(p_sheet_id) sum;

  FOREACH e IN ARRAY p_efficiencies LOOP
    CONTINUE WHEN e <= 0;
    v_cm := round(coalesce(v_smv, 0) / (e / 100.0) * v_cpm, 6);
    out_efficiency := e;
    out_cm := round(v_cm, 4);
    out_price := round((v_base + v_cm)
                       * (1 + coalesce(v_sheet.overhead_percent, 0) / 100.0)
                       * (1 + coalesce(v_sheet.margin_percent, 0) / 100.0), 4);
    RETURN NEXT;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_efficiency_sensitivity(uuid, numeric[]) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. QUOTING, AGREEING, AND WHAT HAPPENS AFTER
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.garment_staff_id()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('merchandiser', 'production manager', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot price a style';
  END IF;
  RETURN v_emp.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.quote_cost_sheet(p_sheet_id uuid)
 RETURNS public.garment_cost_sheets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := garment_staff_id(); v_sheet garment_cost_sheets; v_n integer; v_smv numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = p_sheet_id FOR UPDATE;
  IF v_sheet.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;
  IF v_sheet.status <> 'draft' THEN RAISE EXCEPTION 'This sheet is already %', v_sheet.status; END IF;

  SELECT count(*) INTO v_n FROM garment_cost_lines WHERE sheet_id = p_sheet_id;
  SELECT smv INTO v_smv FROM garment_styles WHERE id = v_sheet.style_id;

  -- A price with no sewing cost in it is not a price for making anything.
  IF coalesce(v_smv, 0) <= 0 THEN
    RAISE EXCEPTION 'This style has no SMV, so the sewing cost cannot be worked out. Set it on the style first.';
  END IF;
  IF v_sheet.line_cost_id IS NULL THEN
    RAISE EXCEPTION 'Pick which line cost this is priced on, otherwise a minute of sewing costs nothing.';
  END IF;
  IF coalesce(v_sheet.assumed_efficiency_pct, 0) <= 0 THEN
    RAISE EXCEPTION 'Set the efficiency this price assumes. At no efficiency the sewing is free, which it is not.';
  END IF;
  IF v_n = 0 AND v_sheet.basis = 'fob' THEN
    RAISE EXCEPTION 'An FOB price with no fabric or trims on it is only a CMT price.';
  END IF;

  UPDATE garment_cost_sheets
     SET status = 'quoted', quoted_on = CURRENT_DATE, prepared_by = coalesce(prepared_by, v_staff)
   WHERE id = p_sheet_id
  RETURNING * INTO v_sheet;
  RETURN v_sheet;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.quote_cost_sheet(uuid) TO authenticated;

-- A buyer negotiates. Agreeing at a number below the sheet is allowed —
-- factories do it to hold a customer — but the gap is recorded rather than
-- lost, because it is the difference between a decision and an accident.
CREATE OR REPLACE FUNCTION public.agree_cost_sheet(p_sheet_id uuid, p_agreed_price numeric)
 RETURNS public.garment_cost_sheets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := garment_staff_id(); v_sheet garment_cost_sheets; v_calc numeric;
BEGIN
  SELECT * INTO v_sheet FROM garment_cost_sheets WHERE id = p_sheet_id FOR UPDATE;
  IF v_sheet.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;
  IF v_sheet.status NOT IN ('draft', 'quoted') THEN
    RAISE EXCEPTION 'This sheet is already %', v_sheet.status;
  END IF;
  IF p_agreed_price IS NULL OR p_agreed_price <= 0 THEN
    RAISE EXCEPTION 'An agreed price has to be a price';
  END IF;

  SELECT out_direct_cost INTO v_calc FROM garment_sheet_summary(p_sheet_id);
  IF p_agreed_price < v_calc THEN
    RAISE EXCEPTION 'That is below what the garment costs to make (%). Change the sheet, or price it above cost.', round(v_calc, 4);
  END IF;

  UPDATE garment_cost_sheets
     SET status = 'agreed', agreed_on = CURRENT_DATE, agreed_price = p_agreed_price,
         prepared_by = coalesce(prepared_by, v_staff)
   WHERE id = p_sheet_id
  RETURNING * INTO v_sheet;

  -- The style's headline price follows the agreement, so the number on the
  -- style is one somebody arrived at rather than one somebody remembered.
  UPDATE garment_styles SET cmt_price = p_agreed_price WHERE id = v_sheet.style_id;
  RETURN v_sheet;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.agree_cost_sheet(uuid, numeric) TO authenticated;

-- What was quoted to a buyer does not change afterwards.
CREATE OR REPLACE FUNCTION public.garment_sheet_is_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM garment_cost_sheets
   WHERE id = CASE TG_OP WHEN 'DELETE' THEN OLD.sheet_id ELSE NEW.sheet_id END;
  IF v_status IN ('quoted', 'agreed', 'superseded')
     AND coalesce(current_setting('kareya.garment_apply', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This cost sheet has gone to the buyer. Take a new revision rather than changing what they were quoted.';
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_garment_cost_lines_frozen ON public.garment_cost_lines;
CREATE TRIGGER trg_garment_cost_lines_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.garment_cost_lines
  FOR EACH ROW EXECUTE FUNCTION public.garment_sheet_is_frozen();

CREATE OR REPLACE FUNCTION public.revise_cost_sheet(p_sheet_id uuid, p_quantity numeric DEFAULT NULL)
 RETURNS public.garment_cost_sheets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_old garment_cost_sheets; v_new garment_cost_sheets; v_rev text; v_qty numeric;
BEGIN
  SELECT * INTO v_old FROM garment_cost_sheets WHERE id = p_sheet_id FOR UPDATE;
  IF v_old.id IS NULL THEN RAISE EXCEPTION 'That cost sheet does not exist'; END IF;

  v_qty := coalesce(p_quantity, v_old.order_quantity);
  -- A price at a different quantity is a new sheet at revision A, not a
  -- revision of the old one: the buyer asked a different question.
  IF v_qty <> v_old.order_quantity THEN
    v_rev := 'A';
  ELSE
    v_rev := CASE WHEN v_old.revision ~ '^[A-Y]$' THEN chr(ascii(v_old.revision) + 1)
                  ELSE v_old.revision || '1' END;
  END IF;

  INSERT INTO garment_cost_sheets (
    style_id, revision, buyer, basis, order_quantity, line_cost_id,
    assumed_efficiency_pct, overhead_percent, margin_percent, currency,
    status, prepared_by, notes)
  VALUES (v_old.style_id, v_rev, v_old.buyer, v_old.basis, v_qty, v_old.line_cost_id,
          v_old.assumed_efficiency_pct, v_old.overhead_percent, v_old.margin_percent,
          v_old.currency, 'draft', v_old.prepared_by, v_old.notes)
  RETURNING * INTO v_new;

  PERFORM set_config('kareya.garment_apply', 'on', true);
  INSERT INTO garment_cost_lines (sheet_id, category, description, resource_id, unit,
                                  consumption, unit_cost, wastage_percent, is_one_off, sort_order, notes)
  SELECT v_new.id, category, description, resource_id, unit,
         consumption, unit_cost, wastage_percent, is_one_off, sort_order, notes
    FROM garment_cost_lines WHERE sheet_id = p_sheet_id ORDER BY sort_order;
  PERFORM set_config('kareya.garment_apply', '', true);

  IF v_qty = v_old.order_quantity AND v_old.status <> 'agreed' THEN
    UPDATE garment_cost_sheets SET status = 'superseded' WHERE id = p_sheet_id;
  END IF;

  SELECT * INTO v_new FROM garment_cost_sheets WHERE id = v_new.id;
  RETURN v_new;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.revise_cost_sheet(uuid, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. WHAT NEEDS LOOKING AT
-- The one that matters: styles quoted at an efficiency the factory has
-- never actually reached.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.garment_costing_reconciliation();
CREATE OR REPLACE FUNCTION public.garment_costing_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- Priced on an efficiency the lines have not achieved. This is the whole
  -- reason a CMT factory quotes a job and then loses money on it.
  SELECT 'sheet', s.id, st.style_no || ' ' || coalesce(st.name, ''),
         'Priced at ' || s.assumed_efficiency_pct::text
         || '% efficiency; the best any line has averaged is '
         || round(best.avg_pct, 1)::text || '%.'
    FROM garment_cost_sheets s
    JOIN garment_styles st ON st.id = s.style_id
    CROSS JOIN LATERAL (
      SELECT coalesce(max(e.out_avg_pct), 0) AS avg_pct FROM garment_achieved_efficiency() e
    ) best
   WHERE s.status IN ('quoted', 'agreed')
     AND best.avg_pct > 0
     AND s.assumed_efficiency_pct > best.avg_pct

  UNION ALL
  -- Agreed below what the sheet said it should be.
  SELECT 'sheet', s.id, st.style_no || ' ' || coalesce(st.name, ''),
         'Agreed at ' || s.agreed_price::text || ' against a sheet price of '
         || round(sum.out_price, 4)::text || '.'
    FROM garment_cost_sheets s
    JOIN garment_styles st ON st.id = s.style_id
    CROSS JOIN LATERAL garment_sheet_summary(s.id) sum
   WHERE s.status = 'agreed' AND s.agreed_price IS NOT NULL
     AND s.agreed_price < sum.out_price

  UNION ALL
  -- A style being made with no sheet behind its price.
  SELECT 'style', st.id, st.style_no || ' ' || coalesce(st.name, ''),
         'Has a CMT price but no cost sheet, so nothing says where the number came from.'
    FROM garment_styles st
   WHERE coalesce(st.cmt_price, 0) > 0
     AND NOT EXISTS (SELECT 1 FROM garment_cost_sheets s WHERE s.style_id = st.id)

  UNION ALL
  -- A style with no SMV cannot be costed at all.
  SELECT 'style', st.id, st.style_no || ' ' || coalesce(st.name, ''),
         'Has no SMV, so the sewing cost of this style cannot be worked out.'
    FROM garment_styles st
   WHERE coalesce(st.smv, 0) = 0

  UNION ALL
  -- A purchase order priced differently from what was agreed.
  SELECT 'order', o.id, coalesce(o.po_no, '—'),
         'PO is at ' || o.cmt_price::text || ' but the agreed sheet price is '
         || s.agreed_price::text || '.'
    FROM garment_orders o
    JOIN garment_cost_sheets s ON s.style_id = o.style_id AND s.status = 'agreed'
   WHERE coalesce(o.cmt_price, 0) > 0 AND s.agreed_price IS NOT NULL
     AND abs(o.cmt_price - s.agreed_price) > 0.0001;
$function$;

GRANT EXECUTE ON FUNCTION public.garment_costing_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- A cost sheet is the most commercially sensitive document a CMT factory
-- has: it is exactly what a buyer must not see.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['garment_line_costs', 'garment_cost_sheets', 'garment_cost_lines']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Merchandiser', 'Production Manager', 'Accountant', 'Manager']))$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Merchandiser', 'Production Manager', 'Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Merchandiser', 'Production Manager', 'Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
