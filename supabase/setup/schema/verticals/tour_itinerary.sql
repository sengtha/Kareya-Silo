-- =====================================================================
-- KAREYA SILO — TOUR: THE ITINERARY IS THE COST SHEET
-- ---------------------------------------------------------------------
-- NAMING NOTE: this file must sort BEFORE `tour_selling.sql`, which uses
-- the pricing functions defined here. Verticals apply in alphabetical
-- order; `tour_itinerary` sorts before `tour_selling`. Do not rename
-- either without checking that.
--
-- WHAT WAS WRONG
--
-- A package carried `destinations text` — a comma-separated string — and
-- `base_price numeric`, one selling price per person. Between those two
-- columns sat everything that makes tour quoting hard, and none of it had
-- anywhere to live.
--
-- 1. THERE WAS NO ITINERARY. A three-day programme is a sequence of days,
--    each with timed items, meals, an overnight, and a set of things
--    somebody has to buy. 'Siem Reap, Tonle Sap' is not that. So the
--    programme lived in a Word file, and the price lived here, and
--    nothing connected them.
--
-- 2. ONE PRICE PER PERSON CANNOT BE RIGHT FOR TWO GROUP SIZES. A tour's
--    cost is a mix of what each traveller consumes (entrance, meals) and
--    what the GROUP consumes once (the van, the guide). Divide the second
--    kind by the number of people and the per-person price falls as the
--    group grows. On the figures in the test suite the same tour is
--    $437.50 a head for two people and $227.50 a head for ten. An agent
--    quoting the ten-person price to a couple loses money on every small
--    group, and nothing in the software could tell them.
--
-- 3. ACCOMMODATION IS NOT PER PERSON. A hotel sells a room. Two sharing a
--    twin carry half each; a traveller alone carries all of it, which is
--    the single supplement, and there was nowhere to put it.
--
-- 4. VEHICLES COME IN WHOLE NUMBERS. A twelve-seat van takes twelve
--    people. The thirteenth needs a second van, and everybody pays for
--    it — so the per-person price does NOT fall smoothly with group size.
--    It steps up at every vehicle break and at every odd number for
--    rooming. A single `base_price` cannot express a step.
--
-- 5. RATES ARE SEASONAL AND NOTHING RECORDED IT. A hotel rate valid in
--    November is not valid in May. `base_price` had no dates on it at
--    all, so a price could not stop being true.
--
-- 6. NOTHING SAID WHERE THE PRICE CAME FROM. `base_price` was typed.
--
-- WHAT THIS ADDS
--
-- The itinerary and the cost sheet are the SAME ROWS. Every line of a
-- day-by-day programme is a thing somebody buys — an entrance, a lunch, a
-- hotel night, a van, a guide day — and each carries a cost and a basis
-- saying whether it is bought per person, per group, per room or per
-- vehicle. From that one set of rows comes the printed programme, the
-- cost, and a price grid by group size, none of which can drift from the
-- others because there is only one of them.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It ships no prices. Not one entrance fee, hotel rate, van charge, guide
-- fee or markup. Those are commercial terms that vary by operator, by
-- season and by contract, and a number invented here would be quoted to a
-- real traveller. Every figure is entered by the business, with a
-- `supplier` and a `cost_source` field for recording where it came from.
--
-- Idempotent. Apply AFTER the base schema (tour_packages).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE PROGRAMME
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tour_itinerary_days (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  package_id   uuid NOT NULL,
  day_no       integer NOT NULL,
  title        text NOT NULL,                 -- 'Siem Reap — Angkor Thom & Bayon'
  summary      text,
  overnight_in text,                          -- where the group sleeps that night
  -- The B / L / D line every tour programme carries.
  breakfast    boolean DEFAULT false,
  lunch        boolean DEFAULT false,
  dinner       boolean DEFAULT false,
  notes        text,
  created_at   timestamp with time zone DEFAULT now(),
  CONSTRAINT tour_itinerary_days_pkey PRIMARY KEY (id),
  CONSTRAINT tour_itinerary_days_package_fkey FOREIGN KEY (package_id)
    REFERENCES public.tour_packages(id) ON DELETE CASCADE,
  CONSTRAINT tour_itinerary_days_no_check CHECK (day_no > 0),
  CONSTRAINT uq_tour_itinerary_day UNIQUE (package_id, day_no)
);

-- One row per thing that happens, whether or not it costs anything.
-- 'Free time at the old market' belongs on the programme and costs
-- nothing; it is the same table with is_costed false.
CREATE TABLE IF NOT EXISTS public.tour_itinerary_items (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  day_id        uuid NOT NULL,
  sort_order    integer DEFAULT 0,
  start_time    time,                         -- optional; a programme need not be to the minute
  title         text NOT NULL,
  description   text,
  item_type     text DEFAULT 'sightseeing' NOT NULL,

  -- ---- the costing half of the same row ----
  is_costed     boolean DEFAULT true,         -- false = on the programme, not in the price
  is_optional   boolean DEFAULT false,        -- offered and priced separately, not in the tour price
  supplier      text,
  cost_basis    text DEFAULT 'per_person' NOT NULL,
  unit_cost     numeric DEFAULT 0 NOT NULL,
  quantity      numeric DEFAULT 1 NOT NULL,   -- nights, days, tickets — whatever the unit is
  unit_capacity numeric,                      -- per_vehicle only: seats in one vehicle
  currency      text,
  cost_source   text,                         -- where this figure came from
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT tour_itinerary_items_pkey PRIMARY KEY (id),
  CONSTRAINT tour_itinerary_items_day_fkey FOREIGN KEY (day_id)
    REFERENCES public.tour_itinerary_days(id) ON DELETE CASCADE,
  CONSTRAINT tour_itinerary_items_type_check CHECK (item_type = ANY (ARRAY[
    'sightseeing', 'meal', 'transport', 'accommodation', 'activity',
    'guide', 'permit', 'free_time', 'other'])),
  CONSTRAINT tour_itinerary_items_basis_check CHECK (cost_basis = ANY (ARRAY[
    'per_person', 'per_group', 'per_room_night', 'per_vehicle'])),
  CONSTRAINT tour_itinerary_items_cost_check CHECK (unit_cost >= 0),
  CONSTRAINT tour_itinerary_items_qty_check CHECK (quantity >= 0),
  -- A vehicle with no seat count cannot be counted out into vehicles.
  CONSTRAINT tour_itinerary_items_vehicle_check
    CHECK (cost_basis <> 'per_vehicle' OR coalesce(unit_capacity, 0) > 0)
);

CREATE INDEX IF NOT EXISTS idx_tour_itinerary_days_package ON public.tour_itinerary_days (package_id);
CREATE INDEX IF NOT EXISTS idx_tour_itinerary_items_day ON public.tour_itinerary_items (day_id);

COMMENT ON TABLE public.tour_itinerary_items IS
  'The programme and the cost sheet are the same rows. Kareya ships no prices: every figure here is entered by the business.';

-- The printable programme, in order. One query for the whole document.
DROP FUNCTION IF EXISTS public.tour_programme(uuid);
CREATE OR REPLACE FUNCTION public.tour_programme(p_package_id uuid)
 RETURNS TABLE (
   out_day_no       integer,
   out_day_title    text,
   out_summary      text,
   out_overnight    text,
   out_meals        text,
   out_start_time   time,
   out_title        text,
   out_description  text,
   out_item_type    text,
   out_is_optional  boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT d.day_no, d.title, d.summary, d.overnight_in,
         nullif(concat_ws('/',
           CASE WHEN d.breakfast THEN 'B' END,
           CASE WHEN d.lunch     THEN 'L' END,
           CASE WHEN d.dinner    THEN 'D' END), ''),
         i.start_time, i.title, i.description, i.item_type, i.is_optional
    FROM tour_itinerary_days d
    LEFT JOIN tour_itinerary_items i ON i.day_id = d.id
   WHERE d.package_id = p_package_id
   ORDER BY d.day_no, i.sort_order NULLS LAST, i.start_time NULLS LAST;
$$;

-- ---------------------------------------------------------------------
-- 2. A COSTING — THE PROGRAMME PRICED FOR A SEASON
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tour_costings (
  id              uuid DEFAULT gen_random_uuid() NOT NULL,
  package_id      uuid NOT NULL,
  name            text NOT NULL,              -- 'Nov 2027 – Mar 2028'
  season          text,                       -- high | low | peak | shoulder — the operator's own words
  currency        text DEFAULT 'USD',

  -- How many share a room. Everything about the single supplement follows
  -- from this one number.
  room_occupancy  integer DEFAULT 2 NOT NULL,
  markup_percent  numeric DEFAULT 0 NOT NULL,
  child_percent   numeric DEFAULT 100 NOT NULL,   -- a child pays this share of the adult price

  valid_from      date DEFAULT CURRENT_DATE NOT NULL,
  valid_to        date,
  status          text DEFAULT 'draft' NOT NULL,  -- draft | published | superseded
  published_on    date,
  prepared_by     uuid,
  notes           text,
  created_at      timestamp with time zone DEFAULT now(),
  CONSTRAINT tour_costings_pkey PRIMARY KEY (id),
  CONSTRAINT tour_costings_package_fkey FOREIGN KEY (package_id)
    REFERENCES public.tour_packages(id) ON DELETE CASCADE,
  CONSTRAINT tour_costings_prepared_fkey FOREIGN KEY (prepared_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT tour_costings_status_check CHECK (status = ANY (ARRAY['draft','published','superseded'])),
  CONSTRAINT tour_costings_occupancy_check CHECK (room_occupancy > 0),
  CONSTRAINT tour_costings_child_check CHECK (child_percent >= 0),
  CONSTRAINT tour_costings_validity_check CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

-- The grid a tour operator actually publishes: a price for each group size.
CREATE TABLE IF NOT EXISTS public.tour_price_bands (
  id                 uuid DEFAULT gen_random_uuid() NOT NULL,
  costing_id         uuid NOT NULL,
  min_pax            integer NOT NULL,
  max_pax            integer,                    -- NULL = open ended
  cost_per_person    numeric DEFAULT 0 NOT NULL,
  price_per_person   numeric DEFAULT 0 NOT NULL,
  single_supplement  numeric DEFAULT 0 NOT NULL,
  child_price        numeric DEFAULT 0 NOT NULL,
  rooms              integer DEFAULT 0,          -- what the arithmetic assumed
  vehicles           integer DEFAULT 0,
  is_override        boolean DEFAULT false,      -- priced by hand, not from the itinerary
  override_reason    text,
  CONSTRAINT tour_price_bands_pkey PRIMARY KEY (id),
  CONSTRAINT tour_price_bands_costing_fkey FOREIGN KEY (costing_id)
    REFERENCES public.tour_costings(id) ON DELETE CASCADE,
  CONSTRAINT tour_price_bands_min_check CHECK (min_pax > 0),
  CONSTRAINT tour_price_bands_range_check CHECK (max_pax IS NULL OR max_pax >= min_pax),
  CONSTRAINT uq_tour_price_band UNIQUE (costing_id, min_pax)
);

CREATE INDEX IF NOT EXISTS idx_tour_costings_package ON public.tour_costings (package_id, status);
CREATE INDEX IF NOT EXISTS idx_tour_price_bands_costing ON public.tour_price_bands (costing_id);

-- Bands of one costing must not overlap, or which price applies to a
-- party of six becomes a matter of luck.
CREATE OR REPLACE FUNCTION public.tour_band_no_overlap()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_clash text;
BEGIN
  SELECT b.min_pax::text || '–' || coalesce(b.max_pax::text, 'up')
    INTO v_clash
    FROM tour_price_bands b
   WHERE b.costing_id = NEW.costing_id
     AND b.id <> NEW.id
     AND coalesce(NEW.max_pax, 2147483647) >= b.min_pax
     AND coalesce(b.max_pax, 2147483647) >= NEW.min_pax
   LIMIT 1;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION 'A band covering % to % already exists (%). Bands must not overlap.',
      NEW.min_pax, coalesce(NEW.max_pax::text, 'up'), v_clash;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tour_band_no_overlap ON public.tour_price_bands;
CREATE TRIGGER trg_tour_band_no_overlap
  BEFORE INSERT OR UPDATE ON public.tour_price_bands
  FOR EACH ROW EXECUTE FUNCTION public.tour_band_no_overlap();

-- A published costing is what somebody was quoted.
CREATE OR REPLACE FUNCTION public.tour_band_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_status text; v_costing uuid;
BEGIN
  v_costing := coalesce(NEW.costing_id, OLD.costing_id);
  SELECT status INTO v_status FROM tour_costings WHERE id = v_costing;
  IF v_status IN ('published', 'superseded')
     AND coalesce(current_setting('kareya.tour_repricing', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This costing has been published. Take a new costing rather than changing a price somebody was quoted.';
  END IF;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_tour_band_frozen ON public.tour_price_bands;
CREATE TRIGGER trg_tour_band_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.tour_price_bands
  FOR EACH ROW EXECUTE FUNCTION public.tour_band_frozen();

-- ---------------------------------------------------------------------
-- 3. THE ARITHMETIC
-- All of it here, so the browser, the printed programme and the invoice
-- cannot disagree about what a tour costs.
-- ---------------------------------------------------------------------

-- What the itinerary costs for a party of this size.
--
-- The four bases behave differently on purpose:
--   per_person     — every traveller consumes one
--   per_group      — bought once, however many go
--   per_room_night — bought by the room; rooms = ceil(pax / occupancy)
--   per_vehicle    — bought by the vehicle; vehicles = ceil(pax / seats)
--
-- The last two are why the per-person price does not fall smoothly. It
-- steps, at every vehicle break and at every odd number for rooming.
DROP FUNCTION IF EXISTS public.tour_cost_at_pax(uuid, integer);
CREATE OR REPLACE FUNCTION public.tour_cost_at_pax(p_costing_id uuid, p_pax integer)
 RETURNS TABLE (
   out_per_person_cost   numeric,   -- the per-person items, for one traveller
   out_group_cost        numeric,   -- the per-group items, for the whole party
   out_room_cost         numeric,   -- all rooms, whole stay
   out_vehicle_cost      numeric,
   out_rooms             integer,
   out_vehicles          integer,
   out_total             numeric,   -- everything, for the whole party
   out_cost_per_person   numeric,
   out_single_supplement numeric    -- sole occupancy, at cost
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_c tour_costings;
  v_pp numeric; v_grp numeric; v_room_one numeric;
  v_rooms integer; v_vehicles integer; v_veh_cost numeric;
BEGIN
  SELECT * INTO v_c FROM tour_costings WHERE id = p_costing_id;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'That costing does not exist'; END IF;
  IF coalesce(p_pax, 0) <= 0 THEN RAISE EXCEPTION 'A party has to have somebody in it'; END IF;

  -- Optional excursions are offered separately and are not in the tour
  -- price. Uncosted rows are on the programme only.
  SELECT
    coalesce(sum(i.unit_cost * i.quantity) FILTER (WHERE i.cost_basis = 'per_person'), 0),
    coalesce(sum(i.unit_cost * i.quantity) FILTER (WHERE i.cost_basis = 'per_group'), 0),
    coalesce(sum(i.unit_cost * i.quantity) FILTER (WHERE i.cost_basis = 'per_room_night'), 0)
  INTO v_pp, v_grp, v_room_one
  FROM tour_itinerary_items i
  JOIN tour_itinerary_days d ON d.id = i.day_id
  WHERE d.package_id = v_c.package_id AND i.is_costed AND NOT i.is_optional;

  v_rooms := ceil(p_pax::numeric / v_c.room_occupancy);

  -- Vehicles are counted per item, because a tour may use a coach on one
  -- day and a boat on another, each with its own capacity.
  SELECT coalesce(sum(ceil(p_pax::numeric / i.unit_capacity) * i.unit_cost * i.quantity), 0),
         coalesce(max(ceil(p_pax::numeric / i.unit_capacity)), 0)
    INTO v_veh_cost, v_vehicles
    FROM tour_itinerary_items i
    JOIN tour_itinerary_days d ON d.id = i.day_id
   WHERE d.package_id = v_c.package_id AND i.is_costed AND NOT i.is_optional
     AND i.cost_basis = 'per_vehicle';

  out_per_person_cost := round(v_pp, 4);
  out_group_cost      := round(v_grp, 4);
  out_room_cost       := round(v_room_one * v_rooms, 4);
  out_vehicle_cost    := round(v_veh_cost, 4);
  out_rooms           := v_rooms;
  out_vehicles        := v_vehicles;
  out_total           := round(v_pp * p_pax + v_grp + v_room_one * v_rooms + v_veh_cost, 4);
  out_cost_per_person := round(out_total / p_pax, 4);

  -- A traveller alone in a room carries the part the others would have
  -- carried: the room, less their own share of it.
  out_single_supplement := round(v_room_one * (v_c.room_occupancy - 1)::numeric / v_c.room_occupancy, 4);
  RETURN NEXT;
END;
$$;

-- Rebuild the grid from the itinerary.
--
-- A band is priced at its SMALLEST party, because that is where the
-- per-group cost is spread thinnest. Price a 4–6 band at six and every
-- party of four loses money.
CREATE OR REPLACE FUNCTION public.price_tour_costing(p_costing_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_c tour_costings;
  v_band record;
  v_cost record;
  v_n integer := 0;
BEGIN
  SELECT * INTO v_c FROM tour_costings WHERE id = p_costing_id FOR UPDATE;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'That costing does not exist'; END IF;
  IF v_c.status <> 'draft' THEN
    RAISE EXCEPTION 'This costing is already %. Take a new one to reprice it.', v_c.status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM tour_price_bands WHERE costing_id = p_costing_id) THEN
    RAISE EXCEPTION 'Set the group sizes you sell at first. There is no single price that is right for two people and for ten.';
  END IF;

  PERFORM set_config('kareya.tour_repricing', 'on', true);

  FOR v_band IN
    SELECT * FROM tour_price_bands WHERE costing_id = p_costing_id AND NOT is_override
     ORDER BY min_pax
  LOOP
    SELECT * INTO v_cost FROM tour_cost_at_pax(p_costing_id, v_band.min_pax);

    UPDATE tour_price_bands SET
      cost_per_person   = v_cost.out_cost_per_person,
      price_per_person  = round(v_cost.out_cost_per_person * (1 + v_c.markup_percent / 100.0), 2),
      -- The supplement is marked up the same as everything else, because
      -- it is sold, not merely recovered.
      single_supplement = round(v_cost.out_single_supplement * (1 + v_c.markup_percent / 100.0), 2),
      child_price       = round(v_cost.out_cost_per_person * (1 + v_c.markup_percent / 100.0)
                                * v_c.child_percent / 100.0, 2),
      rooms             = v_cost.out_rooms,
      vehicles          = v_cost.out_vehicles
    WHERE id = v_band.id;
    v_n := v_n + 1;
  END LOOP;

  PERFORM set_config('kareya.tour_repricing', 'off', true);
  RETURN v_n;
END;
$$;

-- The price grid as published, plus what each band cost to build.
DROP FUNCTION IF EXISTS public.tour_price_grid(uuid);
CREATE OR REPLACE FUNCTION public.tour_price_grid(p_costing_id uuid)
 RETURNS TABLE (
   out_min_pax     integer,
   out_max_pax     integer,
   out_cost        numeric,
   out_price       numeric,
   out_single      numeric,
   out_child       numeric,
   out_rooms       integer,
   out_vehicles    integer,
   out_margin      numeric,
   out_is_override boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT b.min_pax, b.max_pax, b.cost_per_person, b.price_per_person,
         b.single_supplement, b.child_price, b.rooms, b.vehicles,
         round(b.price_per_person - b.cost_per_person, 2), b.is_override
    FROM tour_price_bands b
   WHERE b.costing_id = p_costing_id
   ORDER BY b.min_pax;
$$;

-- What a party of this size pays on this date, from the costing that is
-- valid then. This is what a booking should be priced at, and what
-- `tour_packages.base_price` could never say.
DROP FUNCTION IF EXISTS public.tour_price_for(uuid, integer, date);
CREATE OR REPLACE FUNCTION public.tour_price_for(
  p_package_id uuid, p_pax integer, p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_costing_id uuid,
   out_min_pax    integer,
   out_price      numeric,
   out_single     numeric,
   out_child      numeric,
   out_cost       numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT c.id, b.min_pax, b.price_per_person, b.single_supplement, b.child_price, b.cost_per_person
    FROM tour_costings c
    JOIN tour_price_bands b ON b.costing_id = c.id
   WHERE c.package_id = p_package_id
     AND c.status = 'published'
     AND p_on >= c.valid_from
     AND (c.valid_to IS NULL OR p_on <= c.valid_to)
     AND p_pax >= b.min_pax
     AND (b.max_pax IS NULL OR p_pax <= b.max_pax)
   ORDER BY c.valid_from DESC
   LIMIT 1;
$$;

-- ---------------------------------------------------------------------
-- 4. THE LIFE OF A COSTING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.publish_tour_costing(p_costing_id uuid)
 RETURNS tour_costings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_c tour_costings; v_bad integer; v_items integer;
BEGIN
  SELECT * INTO v_c FROM tour_costings WHERE id = p_costing_id FOR UPDATE;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'That costing does not exist'; END IF;
  IF v_c.status <> 'draft' THEN RAISE EXCEPTION 'This costing is already %', v_c.status; END IF;

  SELECT count(*) INTO v_items
    FROM tour_itinerary_items i JOIN tour_itinerary_days d ON d.id = i.day_id
   WHERE d.package_id = v_c.package_id AND i.is_costed AND NOT i.is_optional;
  IF v_items = 0 THEN
    RAISE EXCEPTION 'This package has no costed itinerary, so there is nothing behind the price.';
  END IF;

  SELECT count(*) INTO v_bad FROM tour_price_bands
   WHERE costing_id = p_costing_id AND price_per_person <= 0;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% band(s) have no price. Price the costing from the itinerary first.', v_bad;
  END IF;

  SELECT count(*) INTO v_bad FROM tour_price_bands
   WHERE costing_id = p_costing_id AND price_per_person < cost_per_person;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% band(s) sell below what the tour costs to run.', v_bad;
  END IF;

  -- Two published costings covering the same day would make the price a
  -- matter of which row came back first.
  UPDATE tour_costings SET status = 'superseded'
   WHERE package_id = v_c.package_id AND status = 'published' AND id <> p_costing_id
     AND (v_c.valid_to IS NULL OR valid_from <= v_c.valid_to)
     AND (valid_to IS NULL OR valid_to >= v_c.valid_from);

  UPDATE tour_costings SET status = 'published', published_on = CURRENT_DATE
   WHERE id = p_costing_id RETURNING * INTO v_c;

  -- The package's own headline price follows the smallest band, so the
  -- brochure figure and the grid cannot drift apart.
  UPDATE tour_packages SET base_price = (
      SELECT price_per_person FROM tour_price_bands
       WHERE costing_id = p_costing_id ORDER BY min_pax LIMIT 1),
    cost_estimate = (
      SELECT cost_per_person FROM tour_price_bands
       WHERE costing_id = p_costing_id ORDER BY min_pax LIMIT 1)
   WHERE id = v_c.package_id;

  RETURN v_c;
END;
$$;

-- A new season, or a corrected one. The published grid is left as it was.
CREATE OR REPLACE FUNCTION public.copy_tour_costing(
  p_costing_id uuid, p_name text, p_valid_from date DEFAULT NULL, p_valid_to date DEFAULT NULL)
 RETURNS tour_costings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_old tour_costings; v_new tour_costings; v_new_id uuid;
BEGIN
  SELECT * INTO v_old FROM tour_costings WHERE id = p_costing_id;
  IF v_old.id IS NULL THEN RAISE EXCEPTION 'That costing does not exist'; END IF;

  INSERT INTO tour_costings (package_id, name, season, currency, room_occupancy,
                             markup_percent, child_percent, valid_from, valid_to,
                             status, prepared_by, notes)
  VALUES (v_old.package_id, p_name, v_old.season, v_old.currency, v_old.room_occupancy,
          v_old.markup_percent, v_old.child_percent,
          coalesce(p_valid_from, CURRENT_DATE), p_valid_to,
          'draft', v_old.prepared_by, v_old.notes)
  RETURNING id INTO v_new_id;

  -- The band shape is carried; the prices are not, because they come back
  -- from the itinerary at whatever it costs now.
  INSERT INTO tour_price_bands (costing_id, min_pax, max_pax)
  SELECT v_new_id, b.min_pax, b.max_pax FROM tour_price_bands b
   WHERE b.costing_id = p_costing_id ORDER BY b.min_pax;

  SELECT * INTO v_new FROM tour_costings WHERE id = v_new_id;
  RETURN v_new;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tour_costing_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- The defect this vertical exists to stop: one price for every party size.
  SELECT 'package', p.id, p.name,
         'Has a price but no costing behind it, so nothing says where the number came from.'
    FROM tour_packages p
   WHERE coalesce(p.base_price, 0) > 0
     AND NOT EXISTS (SELECT 1 FROM tour_costings c WHERE c.package_id = p.id)

  UNION ALL
  SELECT 'package', p.id, p.name,
         'Is sold but has no itinerary, so the programme lives outside Kareya.'
    FROM tour_packages p
   WHERE p.is_active
     AND NOT EXISTS (SELECT 1 FROM tour_itinerary_days d WHERE d.package_id = p.id)

  UNION ALL
  -- A costing whose season has ended but which is still the live price.
  SELECT 'costing', c.id, p.name || ' — ' || c.name,
         'Still published but the season ended on ' || c.valid_to::text || '.'
    FROM tour_costings c JOIN tour_packages p ON p.id = c.package_id
   WHERE c.status = 'published' AND c.valid_to IS NOT NULL AND c.valid_to < CURRENT_DATE

  UNION ALL
  -- Priced by hand, below what it costs.
  SELECT 'costing', c.id, p.name || ' — ' || c.name,
         'The ' || b.min_pax::text || '-person band sells at ' || b.price_per_person::text
         || ' against a cost of ' || b.cost_per_person::text || '.'
    FROM tour_price_bands b
    JOIN tour_costings c ON c.id = b.costing_id
    JOIN tour_packages p ON p.id = c.package_id
   WHERE b.price_per_person < b.cost_per_person

  UNION ALL
  -- The itinerary moved after the costing was priced against it.
  SELECT 'costing', c.id, p.name || ' — ' || c.name,
         'The itinerary was changed after this costing was published. The grid no longer matches the programme.'
    FROM tour_costings c JOIN tour_packages p ON p.id = c.package_id
   WHERE c.status = 'published' AND c.published_on IS NOT NULL
     AND EXISTS (SELECT 1 FROM tour_itinerary_items i
                   JOIN tour_itinerary_days d ON d.id = i.day_id
                  WHERE d.package_id = c.package_id
                    AND i.created_at::date > c.published_on)

  UNION ALL
  -- An itinerary row that costs money and nobody said where the figure
  -- came from.
  SELECT 'package', p.id, p.name,
         'Itinerary item "' || i.title || '" carries a cost with no source recorded.'
    FROM tour_itinerary_items i
    JOIN tour_itinerary_days d ON d.id = i.day_id
    JOIN tour_packages p ON p.id = d.package_id
   WHERE i.is_costed AND i.unit_cost > 0
     AND coalesce(i.cost_source, '') = '' AND coalesce(i.supplier, '') = '';
$$;

GRANT EXECUTE ON FUNCTION public.tour_programme(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_cost_at_pax(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.price_tour_costing(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_price_grid(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_price_for(uuid, integer, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_tour_costing(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.copy_tour_costing(uuid, text, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_costing_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- Costs are what the operator pays suppliers. A traveller who sees them
-- sees the margin, and a guide has no reason to.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tour_itinerary_days', 'tour_itinerary_items',
                           'tour_costings', 'tour_price_bands']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Travel Agent','Guide','Accountant','Manager']))$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Travel Agent','Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Travel Agent','Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
