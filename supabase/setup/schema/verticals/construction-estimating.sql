-- =====================================================================
-- KAREYA SILO — CONSTRUCTION ESTIMATING (construction-estimating)
-- ---------------------------------------------------------------------
-- construction_boq was a flat list: item_no, description, unit, quantity,
-- unit_rate, amount. That is a spreadsheet with a border round it, and it
-- leaves out everything that makes building work hard to price.
--
--  1. NO HIERARCHY. A bill of quantities is Bill 2 Substructure, 2.1
--     Excavation, 2.1.3 Excavate trenches. item_no was free text — a
--     naming convention, not a structure. Nothing could total a section,
--     and reordering meant retyping every number by hand.
--
--  2. unit_rate WAS A NUMBER SOMEBODY TYPED. This is the heart of it. A
--     rate for reinforced concrete per m3 is BUILT UP from cement, sand,
--     aggregate, reinforcement and formwork — each with its own wastage —
--     plus mason and labourer hours at the contractor's own outputs, plus
--     mixer and vibrator. With only the answer stored, nobody can say what
--     a 12% rise in cement does to the price, or which items are being
--     sold too thin. Both questions decide whether a job makes money.
--
--  3. NOTHING SEPARATED COST FROM PRICE. One number was both, so margin
--     was invisible per item, per section and in total.
--
--  4. NO PROVISIONAL OR PRIME COST SUMS. Every building quote carries
--     money that is included but not yet designed or chosen. Recording
--     those as ordinary measured items claims a firmness the estimate does
--     not have.
--
-- What is deliberately NOT here: any method of measurement, wastage
-- percentage, labour output, material price, or overhead and profit
-- figure. Those are the contractor's own price book and their own
-- judgement of a job. Cambodia has no mandated standard method of
-- measurement, and inventing one — or shipping rates that look
-- authoritative — would be worse than shipping nothing, because somebody
-- would price a building with it. Every table here starts empty, and
-- price_source records where each figure actually came from.
--
-- Idempotent and order-independent. Depends on core-schema tables:
-- construction_projects, construction_boq, clients, employees.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE PRICE BOOK
-- What things cost. One row per material, trade, machine or subcontract
-- package, with the price the contractor actually pays and a note saying
-- where that figure came from.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.estimate_resources (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  code          text,
  name          text NOT NULL,
  resource_type text DEFAULT 'material' NOT NULL,  -- material | labour | plant | subcontract
  unit          text NOT NULL,                     -- bag | m3 | m2 | kg | hour | day | item
  unit_cost     numeric DEFAULT 0 NOT NULL,
  currency      text DEFAULT 'USD',
  supplier      text,
  price_source  text,                              -- where this figure came from
  priced_on     date DEFAULT CURRENT_DATE,
  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT estimate_resources_pkey PRIMARY KEY (id),
  CONSTRAINT estimate_resources_type_check
    CHECK (resource_type = ANY (ARRAY['material', 'labour', 'plant', 'subcontract'])),
  CONSTRAINT estimate_resources_cost_check CHECK (unit_cost >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_estimate_resources_code
  ON public.estimate_resources (code) WHERE code IS NOT NULL AND code <> '';
CREATE INDEX IF NOT EXISTS idx_estimate_resources_type ON public.estimate_resources (resource_type);

-- Every price change is kept. A quote sent in March was priced on March's
-- cement, and when somebody asks in August why the number was what it was,
-- this is the answer.
CREATE TABLE IF NOT EXISTS public.resource_price_history (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  resource_id uuid NOT NULL,
  old_cost    numeric,
  new_cost    numeric NOT NULL,
  source      text,
  changed_by  uuid,
  changed_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT resource_price_history_pkey PRIMARY KEY (id),
  CONSTRAINT resource_price_history_resource_fkey FOREIGN KEY (resource_id)
    REFERENCES public.estimate_resources(id) ON DELETE CASCADE,
  CONSTRAINT resource_price_history_changed_by_fkey FOREIGN KEY (changed_by)
    REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_resource_price_history_resource
  ON public.resource_price_history (resource_id, changed_at DESC);

CREATE OR REPLACE FUNCTION public.resource_price_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.unit_cost IS NOT DISTINCT FROM OLD.unit_cost THEN RETURN NEW; END IF;
  BEGIN
    SELECT id INTO v_emp FROM employees
      WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
      ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  EXCEPTION WHEN OTHERS THEN v_emp := NULL;
  END;
  INSERT INTO resource_price_history (resource_id, old_cost, new_cost, source, changed_by)
  VALUES (NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.unit_cost ELSE NULL END,
          NEW.unit_cost, NEW.price_source, v_emp);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_resource_price_log ON public.estimate_resources;
CREATE TRIGGER trg_resource_price_log
  AFTER INSERT OR UPDATE OF unit_cost ON public.estimate_resources
  FOR EACH ROW EXECUTE FUNCTION public.resource_price_log();

CREATE OR REPLACE FUNCTION public.price_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'A price change is a record of something that happened. It cannot be edited or removed.';
END;
$function$;

DROP TRIGGER IF EXISTS trg_price_history_append_only ON public.resource_price_history;
CREATE TRIGGER trg_price_history_append_only
  BEFORE UPDATE OR DELETE ON public.resource_price_history
  FOR EACH ROW EXECUTE FUNCTION public.price_history_append_only();

-- ---------------------------------------------------------------------
-- 2. RATE BUILD-UP
-- A composite rate: what one unit of work costs, expressed as the
-- resources it consumes rather than as a number somebody remembered.
--
-- quantity_per_unit is read against the rate's own unit. For a rate priced
-- per m3, a component of 7 bags of cement means seven bags go into every
-- cubic metre. For labour it is the contractor's own constant — hours per
-- unit — which is the figure a builder actually keeps, and it is theirs to
-- enter because it describes their gang, not anybody else's.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rate_templates (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  code        text,
  description text NOT NULL,
  unit        text NOT NULL,                  -- m | m2 | m3 | kg | nr | item
  trade       text,                           -- Concrete | Masonry | Finishes | MEP ...
  notes       text,
  is_active   boolean DEFAULT true,
  created_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT rate_templates_pkey PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_rate_templates_code
  ON public.rate_templates (code) WHERE code IS NOT NULL AND code <> '';

CREATE TABLE IF NOT EXISTS public.rate_components (
  id                uuid DEFAULT gen_random_uuid() NOT NULL,
  template_id       uuid NOT NULL,
  resource_id       uuid NOT NULL,
  quantity_per_unit numeric DEFAULT 0 NOT NULL,
  wastage_percent   numeric DEFAULT 0 NOT NULL,
  notes             text,
  sort_order        integer DEFAULT 0,
  CONSTRAINT rate_components_pkey PRIMARY KEY (id),
  CONSTRAINT rate_components_template_fkey FOREIGN KEY (template_id)
    REFERENCES public.rate_templates(id) ON DELETE CASCADE,
  CONSTRAINT rate_components_resource_fkey FOREIGN KEY (resource_id)
    REFERENCES public.estimate_resources(id) ON DELETE RESTRICT,
  CONSTRAINT rate_components_qty_check CHECK (quantity_per_unit >= 0),
  CONSTRAINT rate_components_wastage_check CHECK (wastage_percent >= 0 AND wastage_percent < 100)
);

CREATE INDEX IF NOT EXISTS idx_rate_components_template ON public.rate_components (template_id);

-- What one unit of this work costs to do, split by kind, so a contractor
-- can see at a glance whether a rate is material-heavy or labour-heavy —
-- which is what decides how exposed it is to a price rise.
DROP FUNCTION IF EXISTS public.rate_template_cost(uuid);
CREATE OR REPLACE FUNCTION public.rate_template_cost(p_template_id uuid)
 RETURNS TABLE (
   out_material    numeric,
   out_labour      numeric,
   out_plant       numeric,
   out_subcontract numeric,
   out_total       numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    round(coalesce(sum(line) FILTER (WHERE t = 'material'), 0), 4),
    round(coalesce(sum(line) FILTER (WHERE t = 'labour'), 0), 4),
    round(coalesce(sum(line) FILTER (WHERE t = 'plant'), 0), 4),
    round(coalesce(sum(line) FILTER (WHERE t = 'subcontract'), 0), 4),
    round(coalesce(sum(line), 0), 4)
  FROM (
    SELECT r.resource_type AS t,
           c.quantity_per_unit * (1 + c.wastage_percent / 100.0) * r.unit_cost AS line
      FROM rate_components c
      JOIN estimate_resources r ON r.id = c.resource_id
     WHERE c.template_id = p_template_id
  ) x;
$function$;

GRANT EXECUTE ON FUNCTION public.rate_template_cost(uuid) TO authenticated;

-- The build-up, line by line, for the sheet a quantity surveyor checks.
DROP FUNCTION IF EXISTS public.rate_build_up(uuid);
CREATE OR REPLACE FUNCTION public.rate_build_up(p_template_id uuid)
 RETURNS TABLE (
   out_resource   text,
   out_type       text,
   out_unit       text,
   out_quantity   numeric,
   out_wastage    numeric,
   out_gross_qty  numeric,
   out_unit_cost  numeric,
   out_line_cost  numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT r.name, r.resource_type, r.unit,
         c.quantity_per_unit, c.wastage_percent,
         round(c.quantity_per_unit * (1 + c.wastage_percent / 100.0), 4),
         r.unit_cost,
         round(c.quantity_per_unit * (1 + c.wastage_percent / 100.0) * r.unit_cost, 4)
    FROM rate_components c
    JOIN estimate_resources r ON r.id = c.resource_id
   WHERE c.template_id = p_template_id
   ORDER BY c.sort_order,
            array_position(ARRAY['material', 'labour', 'plant', 'subcontract'], r.resource_type),
            r.name;
$function$;

GRANT EXECUTE ON FUNCTION public.rate_build_up(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. THE ESTIMATE
-- A quote exists before there is a project to attach it to, so this stands
-- on its own and is linked to a construction project only if it is won.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.construction_estimates (
  id               uuid DEFAULT gen_random_uuid() NOT NULL,
  estimate_number  text,
  revision         text DEFAULT 'A',
  title            text NOT NULL,
  client_id        uuid,
  client_name      text,                       -- for an enquiry with no client record yet
  project_id       uuid,                       -- set when the job is won
  site_address     text,
  estimate_date    date DEFAULT CURRENT_DATE,
  valid_until      date,
  currency         text DEFAULT 'USD',
  -- Both start at zero. A contractor's overhead and margin are their own
  -- business and nothing here should suggest a number.
  overhead_percent numeric DEFAULT 0 NOT NULL,
  margin_percent   numeric DEFAULT 0 NOT NULL,
  status           text DEFAULT 'draft' NOT NULL,   -- draft | issued | accepted | declined | superseded
  issued_at        timestamp with time zone,
  accepted_at      timestamp with time zone,
  prepared_by      uuid,
  notes            text,
  created_at       timestamp with time zone DEFAULT now(),
  CONSTRAINT construction_estimates_pkey PRIMARY KEY (id),
  CONSTRAINT construction_estimates_client_fkey FOREIGN KEY (client_id)
    REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT construction_estimates_project_fkey FOREIGN KEY (project_id)
    REFERENCES public.construction_projects(id) ON DELETE SET NULL,
  CONSTRAINT construction_estimates_prepared_by_fkey FOREIGN KEY (prepared_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT construction_estimates_status_check
    CHECK (status = ANY (ARRAY['draft', 'issued', 'accepted', 'declined', 'superseded'])),
  CONSTRAINT construction_estimates_overhead_check CHECK (overhead_percent >= 0),
  CONSTRAINT construction_estimates_margin_check CHECK (margin_percent >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_construction_estimates_number
  ON public.construction_estimates (estimate_number, revision)
  WHERE estimate_number IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.estimate_number_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'EST-',
  width   integer DEFAULT 4,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT estimate_number_series_pkey PRIMARY KEY (id),
  CONSTRAINT estimate_number_series_singleton CHECK (id = true)
);
INSERT INTO public.estimate_number_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_estimate_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_s estimate_number_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('estimate_number_series'));
  SELECT * INTO v_s FROM estimate_number_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO estimate_number_series (id) VALUES (true) RETURNING * INTO v_s; END IF;
  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE estimate_number_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE estimate_number_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;
  RETURN coalesce(v_s.prefix, 'EST-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 4), 1), '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.estimate_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- A revision keeps the number it was given; only a new estimate takes one.
  IF NEW.estimate_number IS NULL OR trim(NEW.estimate_number) = '' THEN
    NEW.estimate_number := allocate_estimate_no(coalesce(NEW.estimate_date, CURRENT_DATE));
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_estimate_number ON public.construction_estimates;
CREATE TRIGGER trg_estimate_number
  BEFORE INSERT ON public.construction_estimates
  FOR EACH ROW EXECUTE FUNCTION public.estimate_number();

-- ---------------------------------------------------------------------
-- 4. THE BILL: SECTIONS AND ITEMS
-- The hierarchy is the point. A bill that cannot be totalled by section
-- cannot be read by the person paying for it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.boq_sections (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  estimate_id uuid NOT NULL,
  parent_id   uuid,
  code        text,                            -- assigned by renumber_boq()
  title       text NOT NULL,
  notes       text,
  sort_order  integer DEFAULT 0 NOT NULL,
  created_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT boq_sections_pkey PRIMARY KEY (id),
  CONSTRAINT boq_sections_estimate_fkey FOREIGN KEY (estimate_id)
    REFERENCES public.construction_estimates(id) ON DELETE CASCADE,
  CONSTRAINT boq_sections_parent_fkey FOREIGN KEY (parent_id)
    REFERENCES public.boq_sections(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_boq_sections_estimate ON public.boq_sections (estimate_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_boq_sections_parent ON public.boq_sections (parent_id);

-- A section cannot be its own ancestor. Without this a mis-drag makes the
-- totals recurse for ever.
CREATE OR REPLACE FUNCTION public.boq_section_no_cycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_depth integer := 0;
BEGIN
  IF NEW.parent_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.parent_id = NEW.id THEN
    RAISE EXCEPTION 'A section cannot sit inside itself';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM boq_sections
                  WHERE id = NEW.parent_id AND estimate_id = NEW.estimate_id) THEN
    RAISE EXCEPTION 'A section can only sit inside another section of the same estimate';
  END IF;

  v_id := NEW.parent_id;
  WHILE v_id IS NOT NULL LOOP
    v_depth := v_depth + 1;
    IF v_depth > 20 THEN RAISE EXCEPTION 'A bill cannot be nested more than 20 deep'; END IF;
    IF v_id = NEW.id THEN
      RAISE EXCEPTION 'That would put a section inside one of its own sub-sections';
    END IF;
    SELECT parent_id INTO v_id FROM boq_sections WHERE id = v_id;
  END LOOP;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_section_no_cycle ON public.boq_sections;
CREATE TRIGGER trg_boq_section_no_cycle
  BEFORE INSERT OR UPDATE OF parent_id ON public.boq_sections
  FOR EACH ROW EXECUTE FUNCTION public.boq_section_no_cycle();

CREATE TABLE IF NOT EXISTS public.boq_items (
  id                uuid DEFAULT gen_random_uuid() NOT NULL,
  estimate_id       uuid NOT NULL,
  section_id        uuid,
  code              text,                      -- assigned by renumber_boq()
  description       text NOT NULL,
  -- measured     : quantity x rate, the ordinary case
  -- provisional  : money included for work not yet designed
  -- pc_sum       : money included for something not yet selected
  -- lump         : a single price, not measured
  -- note         : text only, carries no money
  item_type         text DEFAULT 'measured' NOT NULL,
  unit              text,
  quantity          numeric DEFAULT 0 NOT NULL,
  rate_template_id  uuid,                      -- when the rate is built up
  rate_cost         numeric DEFAULT 0 NOT NULL,-- direct cost per unit
  rate_override     numeric,                   -- a cost the estimator sets by hand
  override_reason   text,
  overhead_percent  numeric,                   -- NULL = use the estimate's
  margin_percent    numeric,
  rate_sell         numeric DEFAULT 0 NOT NULL,-- what the client is charged per unit
  amount_cost       numeric DEFAULT 0 NOT NULL,
  amount_sell       numeric DEFAULT 0 NOT NULL,
  sort_order        integer DEFAULT 0 NOT NULL,
  notes             text,
  created_at        timestamp with time zone DEFAULT now(),
  CONSTRAINT boq_items_pkey PRIMARY KEY (id),
  CONSTRAINT boq_items_estimate_fkey FOREIGN KEY (estimate_id)
    REFERENCES public.construction_estimates(id) ON DELETE CASCADE,
  CONSTRAINT boq_items_section_fkey FOREIGN KEY (section_id)
    REFERENCES public.boq_sections(id) ON DELETE CASCADE,
  CONSTRAINT boq_items_template_fkey FOREIGN KEY (rate_template_id)
    REFERENCES public.rate_templates(id) ON DELETE SET NULL,
  CONSTRAINT boq_items_type_check
    CHECK (item_type = ANY (ARRAY['measured', 'provisional', 'pc_sum', 'lump', 'note'])),
  CONSTRAINT boq_items_quantity_check CHECK (quantity >= 0),
  CONSTRAINT boq_items_override_check
    CHECK (rate_override IS NULL OR rate_override >= 0)
);

CREATE INDEX IF NOT EXISTS idx_boq_items_estimate ON public.boq_items (estimate_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_boq_items_section ON public.boq_items (section_id, sort_order);

-- ---------------------------------------------------------------------
-- 5. WHERE COST BECOMES PRICE
-- Kept apart on purpose. One number for both is how a contractor finds out
-- at the end of a job which items were being sold below what they cost.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.boq_item_recalc()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_est construction_estimates; v_oh numeric; v_mg numeric; v_cost numeric;
BEGIN
  SELECT * INTO v_est FROM construction_estimates WHERE id = NEW.estimate_id;
  IF v_est.id IS NULL THEN RAISE EXCEPTION 'That estimate does not exist'; END IF;

  -- A section, if given, has to belong to the same estimate. Otherwise an
  -- item shows up under somebody else's bill and both totals are wrong.
  IF NEW.section_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM boq_sections
                      WHERE id = NEW.section_id AND estimate_id = NEW.estimate_id) THEN
    RAISE EXCEPTION 'That section belongs to a different estimate';
  END IF;

  IF NEW.item_type = 'note' THEN
    NEW.quantity := 0; NEW.rate_cost := 0; NEW.rate_sell := 0;
    NEW.amount_cost := 0; NEW.amount_sell := 0;
    RETURN NEW;
  END IF;

  v_oh := coalesce(NEW.overhead_percent, v_est.overhead_percent, 0);
  v_mg := coalesce(NEW.margin_percent, v_est.margin_percent, 0);

  IF NEW.rate_override IS NOT NULL THEN
    v_cost := NEW.rate_override;
  ELSIF NEW.rate_template_id IS NOT NULL THEN
    SELECT out_total INTO v_cost FROM rate_template_cost(NEW.rate_template_id);
    v_cost := coalesce(v_cost, 0);
  ELSE
    v_cost := coalesce(NEW.rate_cost, 0);
  END IF;

  NEW.rate_cost := round(v_cost, 4);

  -- A provisional or prime cost sum is a figure agreed with the client. It
  -- carries no build-up and no margin is added to it here: whatever the
  -- contractor takes on it is a matter for when the work is actually
  -- designed, and pretending otherwise inflates the quoted sum.
  IF NEW.item_type IN ('provisional', 'pc_sum') THEN
    NEW.quantity := 1;
    NEW.rate_sell := NEW.rate_cost;
  ELSE
    NEW.rate_sell := round(NEW.rate_cost * (1 + v_oh / 100.0) * (1 + v_mg / 100.0), 4);
  END IF;

  IF NEW.item_type = 'lump' THEN NEW.quantity := 1; END IF;

  NEW.amount_cost := round(NEW.quantity * NEW.rate_cost, 2);
  NEW.amount_sell := round(NEW.quantity * NEW.rate_sell, 2);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_item_recalc ON public.boq_items;
CREATE TRIGGER trg_boq_item_recalc
  BEFORE INSERT OR UPDATE ON public.boq_items
  FOR EACH ROW EXECUTE FUNCTION public.boq_item_recalc();

-- Overriding a built-up rate is allowed — an estimator often knows
-- something the price book does not — but not silently.
CREATE OR REPLACE FUNCTION public.boq_item_override_needs_reason()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.rate_override IS NOT NULL
     AND NEW.rate_template_id IS NOT NULL
     AND coalesce(trim(NEW.override_reason), '') = '' THEN
    RAISE EXCEPTION 'This item has a built-up rate. Overriding it needs a reason, so the next person knows why the build-up was not used.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_item_override_reason ON public.boq_items;
CREATE TRIGGER trg_boq_item_override_reason
  BEFORE INSERT OR UPDATE ON public.boq_items
  FOR EACH ROW EXECUTE FUNCTION public.boq_item_override_needs_reason();

-- ---------------------------------------------------------------------
-- 6. NUMBERING
-- Codes come from the tree, so reordering a bill is dragging a row rather
-- than retyping forty item numbers and getting one of them wrong.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.renumber_boq(p_estimate_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count integer := 0;
  r record;
BEGIN
  FOR r IN
    WITH RECURSIVE tree AS (
      SELECT s.id, s.parent_id, s.sort_order,
             row_number() OVER (ORDER BY s.sort_order, s.title)::text AS code,
             1 AS depth
        FROM boq_sections s
       WHERE s.estimate_id = p_estimate_id AND s.parent_id IS NULL
      UNION ALL
      SELECT c.id, c.parent_id, c.sort_order,
             t.code || '.' || row_number() OVER (PARTITION BY c.parent_id ORDER BY c.sort_order, c.title)::text,
             t.depth + 1
        FROM boq_sections c
        JOIN tree t ON t.id = c.parent_id
       WHERE c.estimate_id = p_estimate_id
    )
    SELECT id, code FROM tree
  LOOP
    UPDATE boq_sections SET code = r.code WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  -- Items take their section's code and their position within it. Items
  -- with no section are numbered from the top of the bill.
  UPDATE boq_items i
     SET code = numbered.new_code
    FROM (
      SELECT it.id,
             coalesce(s.code || '.', '')
               || row_number() OVER (PARTITION BY it.section_id ORDER BY it.sort_order, it.description)::text
               AS new_code
        FROM boq_items it
        LEFT JOIN boq_sections s ON s.id = it.section_id
       WHERE it.estimate_id = p_estimate_id
    ) numbered
   WHERE i.id = numbered.id;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.renumber_boq(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. TOTALS
-- A section total includes everything beneath it, however deep.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.boq_section_totals(uuid);
CREATE OR REPLACE FUNCTION public.boq_section_totals(p_estimate_id uuid)
 RETURNS TABLE (
   out_section_id uuid,
   out_code       text,
   out_title      text,
   out_depth      integer,
   out_cost       numeric,
   out_sell       numeric,
   out_margin     numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH RECURSIVE tree AS (
    SELECT s.id, s.parent_id, s.code, s.title, s.sort_order, 1 AS depth,
           lpad(s.sort_order::text, 6, '0') AS path
      FROM boq_sections s
     WHERE s.estimate_id = p_estimate_id AND s.parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, c.code, c.title, c.sort_order, t.depth + 1,
           t.path || '/' || lpad(c.sort_order::text, 6, '0')
      FROM boq_sections c JOIN tree t ON t.id = c.parent_id
     WHERE c.estimate_id = p_estimate_id
  ),
  -- Everything under each section, itself included.
  descend AS (
    SELECT a.id AS root_id, b.id AS node_id
      FROM tree a
      JOIN LATERAL (
        WITH RECURSIVE d AS (
          SELECT a.id
          UNION ALL
          SELECT s.id FROM boq_sections s JOIN d ON s.parent_id = d.id
           WHERE s.estimate_id = p_estimate_id
        ) SELECT id FROM d
      ) b ON true
  )
  SELECT t.id, t.code, t.title, t.depth,
         round(coalesce(sum(i.amount_cost), 0), 2),
         round(coalesce(sum(i.amount_sell), 0), 2),
         round(coalesce(sum(i.amount_sell), 0) - coalesce(sum(i.amount_cost), 0), 2)
    FROM tree t
    LEFT JOIN descend d ON d.root_id = t.id
    LEFT JOIN boq_items i ON i.section_id = d.node_id AND i.item_type <> 'note'
   GROUP BY t.id, t.code, t.title, t.depth, t.path
   ORDER BY t.path;
$function$;

GRANT EXECUTE ON FUNCTION public.boq_section_totals(uuid) TO authenticated;

DROP FUNCTION IF EXISTS public.estimate_summary(uuid);
CREATE OR REPLACE FUNCTION public.estimate_summary(p_estimate_id uuid)
 RETURNS TABLE (
   out_measured_cost numeric,
   out_measured_sell numeric,
   out_provisional   numeric,
   out_pc_sums       numeric,
   out_total_cost    numeric,
   out_total_sell    numeric,
   out_margin        numeric,
   out_margin_pct    numeric,
   out_item_count    integer
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    round(coalesce(sum(amount_cost) FILTER (WHERE item_type IN ('measured', 'lump')), 0), 2),
    round(coalesce(sum(amount_sell) FILTER (WHERE item_type IN ('measured', 'lump')), 0), 2),
    round(coalesce(sum(amount_sell) FILTER (WHERE item_type = 'provisional'), 0), 2),
    round(coalesce(sum(amount_sell) FILTER (WHERE item_type = 'pc_sum'), 0), 2),
    round(coalesce(sum(amount_cost) FILTER (WHERE item_type <> 'note'), 0), 2),
    round(coalesce(sum(amount_sell) FILTER (WHERE item_type <> 'note'), 0), 2),
    round(coalesce(sum(amount_sell) FILTER (WHERE item_type <> 'note'), 0)
          - coalesce(sum(amount_cost) FILTER (WHERE item_type <> 'note'), 0), 2),
    CASE WHEN coalesce(sum(amount_sell) FILTER (WHERE item_type <> 'note'), 0) = 0 THEN 0
         ELSE round(100 * (coalesce(sum(amount_sell) FILTER (WHERE item_type <> 'note'), 0)
                           - coalesce(sum(amount_cost) FILTER (WHERE item_type <> 'note'), 0))
                    / sum(amount_sell) FILTER (WHERE item_type <> 'note'), 2) END,
    count(*) FILTER (WHERE item_type <> 'note')::integer
  FROM boq_items WHERE estimate_id = p_estimate_id;
$function$;

GRANT EXECUTE ON FUNCTION public.estimate_summary(uuid) TO authenticated;

-- Which items are being sold at or below what they cost. This is the
-- question a single unit_rate column could never answer.
DROP FUNCTION IF EXISTS public.estimate_thin_items(uuid, numeric);
CREATE OR REPLACE FUNCTION public.estimate_thin_items(p_estimate_id uuid, p_below_pct numeric DEFAULT 0)
 RETURNS TABLE (
   out_item_id   uuid,
   out_code      text,
   out_description text,
   out_cost      numeric,
   out_sell      numeric,
   out_margin_pct numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT i.id, i.code, i.description, i.amount_cost, i.amount_sell,
         CASE WHEN i.amount_sell = 0 THEN 0
              ELSE round(100 * (i.amount_sell - i.amount_cost) / i.amount_sell, 2) END
    FROM boq_items i
   WHERE i.estimate_id = p_estimate_id
     AND i.item_type IN ('measured', 'lump')
     AND i.amount_sell > 0
     AND (100 * (i.amount_sell - i.amount_cost) / i.amount_sell) <= coalesce(p_below_pct, 0)
   ORDER BY (i.amount_sell - i.amount_cost) / nullif(i.amount_sell, 0);
$function$;

GRANT EXECUTE ON FUNCTION public.estimate_thin_items(uuid, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. RE-PRICING
-- Cement moves. This is the question the old table could not answer at
-- all: what does that do to a bill already priced?
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.reprice_estimate(uuid, boolean);
CREATE OR REPLACE FUNCTION public.reprice_estimate(p_estimate_id uuid, p_apply boolean DEFAULT false)
 RETURNS TABLE (
   out_item_id  uuid,
   out_code     text,
   out_description text,
   out_old_rate numeric,
   out_new_rate numeric,
   out_change   numeric
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_new numeric; v_est construction_estimates;
BEGIN
  SELECT * INTO v_est FROM construction_estimates WHERE id = p_estimate_id;
  IF v_est.id IS NULL THEN RAISE EXCEPTION 'That estimate does not exist'; END IF;
  IF p_apply AND v_est.status <> 'draft' THEN
    RAISE EXCEPTION 'Estimate % has been %. Re-price a new revision rather than the one that was sent out.',
      v_est.estimate_number, v_est.status;
  END IF;

  FOR r IN
    SELECT i.id, i.code, i.description, i.rate_cost, i.rate_template_id
      FROM boq_items i
     WHERE i.estimate_id = p_estimate_id
       AND i.rate_template_id IS NOT NULL
       AND i.rate_override IS NULL
  LOOP
    SELECT out_total INTO v_new FROM rate_template_cost(r.rate_template_id);
    v_new := coalesce(v_new, 0);
    IF round(v_new, 4) <> round(r.rate_cost, 4) THEN
      IF p_apply THEN
        -- The trigger recomputes sell and amounts from this.
        UPDATE boq_items SET rate_cost = v_new WHERE id = r.id;
      END IF;
      out_item_id := r.id; out_code := r.code; out_description := r.description;
      out_old_rate := round(r.rate_cost, 4); out_new_rate := round(v_new, 4);
      out_change := round(v_new - r.rate_cost, 4);
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reprice_estimate(uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------
-- 9. WHAT WAS SENT OUT DOES NOT CHANGE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.estimate_is_frozen_once_issued()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_number text;
BEGIN
  SELECT status, estimate_number INTO v_status, v_number
    FROM construction_estimates
   WHERE id = coalesce(
     CASE TG_OP WHEN 'DELETE' THEN OLD.estimate_id ELSE NEW.estimate_id END);

  IF v_status IN ('issued', 'accepted', 'superseded')
     AND coalesce(current_setting('kareya.estimate_apply', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Estimate % has been sent to the client. Take a new revision rather than editing what they were given.', v_number;
  END IF;
  RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_boq_items_frozen ON public.boq_items;
CREATE TRIGGER trg_boq_items_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.boq_items
  FOR EACH ROW EXECUTE FUNCTION public.estimate_is_frozen_once_issued();

DROP TRIGGER IF EXISTS trg_boq_sections_frozen ON public.boq_sections;
CREATE TRIGGER trg_boq_sections_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.boq_sections
  FOR EACH ROW EXECUTE FUNCTION public.estimate_is_frozen_once_issued();

CREATE OR REPLACE FUNCTION public.issue_estimate(p_estimate_id uuid)
 RETURNS public.construction_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_est construction_estimates; v_n integer;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('site manager', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot send an estimate to a client';
  END IF;

  SELECT * INTO v_est FROM construction_estimates WHERE id = p_estimate_id FOR UPDATE;
  IF v_est.id IS NULL THEN RAISE EXCEPTION 'That estimate does not exist'; END IF;
  IF v_est.status <> 'draft' THEN RAISE EXCEPTION 'This estimate is already %', v_est.status; END IF;

  SELECT count(*) INTO v_n FROM boq_items WHERE estimate_id = p_estimate_id AND item_type <> 'note';
  IF v_n = 0 THEN RAISE EXCEPTION 'There is nothing priced in this estimate'; END IF;

  PERFORM renumber_boq(p_estimate_id);
  UPDATE construction_estimates
     SET status = 'issued', issued_at = now(), prepared_by = coalesce(prepared_by, v_emp.id)
   WHERE id = p_estimate_id
  RETURNING * INTO v_est;
  RETURN v_est;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.issue_estimate(uuid) TO authenticated;

-- A revision is a copy, so what the client was given last week is still
-- readable next year. The old one becomes superseded; it is not deleted.
CREATE OR REPLACE FUNCTION public.revise_estimate(p_estimate_id uuid, p_note text DEFAULT NULL)
 RETURNS public.construction_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old construction_estimates; v_new construction_estimates;
  v_rev text; r record; v_map jsonb := '{}'::jsonb;
  v_new_id uuid; v_sec_id uuid;
BEGIN
  SELECT * INTO v_old FROM construction_estimates WHERE id = p_estimate_id FOR UPDATE;
  IF v_old.id IS NULL THEN RAISE EXCEPTION 'That estimate does not exist'; END IF;
  IF v_old.status = 'accepted' THEN
    RAISE EXCEPTION 'Estimate % was accepted. Work after that is a variation, not a revision.', v_old.estimate_number;
  END IF;

  -- A, B, C ... and on past Z if a job really goes that way.
  v_rev := CASE
    WHEN v_old.revision ~ '^[A-Y]$' THEN chr(ascii(v_old.revision) + 1)
    ELSE v_old.revision || '1'
  END;

  INSERT INTO construction_estimates (
    estimate_number, revision, title, client_id, client_name, project_id, site_address,
    estimate_date, valid_until, currency, overhead_percent, margin_percent,
    status, prepared_by, notes)
  VALUES (
    v_old.estimate_number, v_rev, v_old.title, v_old.client_id, v_old.client_name,
    v_old.project_id, v_old.site_address, CURRENT_DATE, v_old.valid_until, v_old.currency,
    v_old.overhead_percent, v_old.margin_percent, 'draft', v_old.prepared_by,
    coalesce(p_note, v_old.notes))
  RETURNING * INTO v_new;
  v_new_id := v_new.id;

  PERFORM set_config('kareya.estimate_apply', 'on', true);

  -- Sections first, parents before children, so a child's new parent id is
  -- already in the map by the time it is needed.
  FOR r IN
    WITH RECURSIVE tree AS (
      SELECT s.*, 1 AS depth FROM boq_sections s
       WHERE s.estimate_id = p_estimate_id AND s.parent_id IS NULL
      UNION ALL
      SELECT c.*, t.depth + 1 FROM boq_sections c JOIN tree t ON t.id = c.parent_id
       WHERE c.estimate_id = p_estimate_id
    )
    SELECT * FROM tree ORDER BY depth, sort_order
  LOOP
    INSERT INTO boq_sections (estimate_id, parent_id, code, title, notes, sort_order)
    VALUES (v_new_id,
            CASE WHEN r.parent_id IS NULL THEN NULL
                 ELSE (v_map ->> r.parent_id::text)::uuid END,
            r.code, r.title, r.notes, r.sort_order)
    RETURNING id INTO v_sec_id;
    v_map := v_map || jsonb_build_object(r.id::text, v_sec_id::text);
  END LOOP;

  INSERT INTO boq_items (estimate_id, section_id, code, description, item_type, unit, quantity,
                         rate_template_id, rate_cost, rate_override, override_reason,
                         overhead_percent, margin_percent, sort_order, notes)
  SELECT v_new_id,
         CASE WHEN i.section_id IS NULL THEN NULL ELSE (v_map ->> i.section_id::text)::uuid END,
         i.code, i.description, i.item_type, i.unit, i.quantity,
         i.rate_template_id, i.rate_cost, i.rate_override, i.override_reason,
         i.overhead_percent, i.margin_percent, i.sort_order, i.notes
    FROM boq_items i WHERE i.estimate_id = p_estimate_id
   ORDER BY i.sort_order;

  UPDATE construction_estimates SET status = 'superseded'
   WHERE id = p_estimate_id AND status <> 'declined';

  PERFORM set_config('kareya.estimate_apply', '', true);

  SELECT * INTO v_new FROM construction_estimates WHERE id = v_new_id;
  RETURN v_new;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.revise_estimate(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 10. THE FLAT BILLS THAT ARE ALREADY THERE
-- construction_boq rows are not thrown away and not silently converted.
-- This turns one project's flat bill into an estimate when somebody asks
-- for it, so the old numbers survive and can be built up properly.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.import_legacy_boq(p_project_id uuid)
 RETURNS public.construction_estimates
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_proj construction_projects; v_est construction_estimates; v_sec uuid; v_n integer;
BEGIN
  SELECT * INTO v_proj FROM construction_projects WHERE id = p_project_id;
  IF v_proj.id IS NULL THEN RAISE EXCEPTION 'That project does not exist'; END IF;

  SELECT count(*) INTO v_n FROM construction_boq WHERE project_id = p_project_id;
  IF v_n = 0 THEN RAISE EXCEPTION 'That project has no bill of quantities to import'; END IF;

  INSERT INTO construction_estimates (title, client_name, project_id, currency, status, notes)
  VALUES (v_proj.name || ' — imported bill', v_proj.client_name, p_project_id,
          coalesce(v_proj.currency, 'USD'), 'draft',
          'Imported from the flat bill of quantities. Rates came across as typed figures with no build-up behind them.')
  RETURNING * INTO v_est;

  INSERT INTO boq_sections (estimate_id, title, sort_order)
  VALUES (v_est.id, 'Imported bill', 0) RETURNING id INTO v_sec;

  INSERT INTO boq_items (estimate_id, section_id, description, item_type, unit, quantity,
                         rate_cost, sort_order, notes)
  SELECT v_est.id, v_sec,
         coalesce(b.description, 'Item'), 'measured', b.unit, coalesce(b.quantity, 0),
         coalesce(b.unit_rate, 0),
         row_number() OVER (ORDER BY b.item_no, b.description),
         CASE WHEN b.item_no IS NOT NULL THEN 'Was item ' || b.item_no ELSE NULL END
    FROM construction_boq b WHERE b.project_id = p_project_id;

  PERFORM renumber_boq(v_est.id);
  RETURN v_est;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.import_legacy_boq(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 11. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.estimating_reconciliation();
CREATE OR REPLACE FUNCTION public.estimating_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- Priced work with no build-up behind it.
  SELECT 'item', i.id, coalesce(i.code, '') || ' ' || i.description,
         'Rate typed in with no build-up, so a price change cannot be traced through it.'
    FROM boq_items i
    JOIN construction_estimates e ON e.id = i.estimate_id
   WHERE i.item_type IN ('measured', 'lump') AND i.rate_template_id IS NULL
     AND i.rate_cost > 0 AND e.status = 'draft'

  UNION ALL
  -- Sold at or below cost.
  SELECT 'item', i.id, coalesce(i.code, '') || ' ' || i.description,
         'Sells for ' || i.amount_sell::text || ' and costs ' || i.amount_cost::text
    FROM boq_items i
    JOIN construction_estimates e ON e.id = i.estimate_id
   WHERE i.item_type IN ('measured', 'lump') AND i.amount_sell > 0
     AND i.amount_sell <= i.amount_cost AND e.status = 'draft'

  UNION ALL
  -- A rate template that has lost its components is a rate of zero.
  SELECT 'rate', t.id, coalesce(t.code || ' ', '') || t.description,
         'This rate has no resources in it, so it prices at nothing.'
    FROM rate_templates t
   WHERE t.is_active
     AND NOT EXISTS (SELECT 1 FROM rate_components c WHERE c.template_id = t.id)

  UNION ALL
  -- A resource priced at nothing prices everything built on it at nothing.
  SELECT 'resource', r.id, r.name,
         'Priced at zero, so every rate that uses it is understated.'
    FROM estimate_resources r
   WHERE r.is_active AND r.unit_cost = 0
     AND EXISTS (SELECT 1 FROM rate_components c WHERE c.resource_id = r.id)

  UNION ALL
  -- Prices that have not been looked at for a long time.
  SELECT 'resource', r.id, r.name,
         'Last priced on ' || r.priced_on::text || '. Check it before quoting from it.'
    FROM estimate_resources r
   WHERE r.is_active AND r.priced_on IS NOT NULL
     AND r.priced_on < CURRENT_DATE - 180

  UNION ALL
  -- Old flat bills nobody has brought across.
  SELECT 'legacy', p.id, p.name,
         'Has a flat bill of quantities that has not been imported as an estimate.'
    FROM construction_projects p
   WHERE EXISTS (SELECT 1 FROM construction_boq b WHERE b.project_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM construction_estimates e WHERE e.project_id = p.id);
$function$;

GRANT EXECUTE ON FUNCTION public.estimating_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 12. ROW LEVEL SECURITY
-- A price book is commercially sensitive: it is what the contractor pays,
-- not what they charge. Estimators and management see it; nobody else does.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['estimate_resources', 'resource_price_history', 'rate_templates',
                           'rate_components', 'construction_estimates', 'boq_sections',
                           'boq_items', 'estimate_number_series']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Accountant', 'Manager']))$p$,
                   t || '_read', t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['estimate_resources', 'rate_templates', 'rate_components',
                           'construction_estimates', 'boq_sections', 'boq_items']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Estimator', 'Site Manager', 'Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
