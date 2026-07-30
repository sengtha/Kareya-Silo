-- =====================================================================
-- KAREYA SILO — FREIGHT: TARIFFS, CHARGEABLE WEIGHT AND QUOTING
-- ---------------------------------------------------------------------
-- NAMING NOTE: this file is `freight_quoting.sql`, not `freight-quoting.sql`.
-- Verticals are applied in alphabetical order and a hyphen sorts BEFORE a
-- dot, so `freight-quoting.sql` would run before `freight.sql` and fail on
-- a table that does not exist yet. An underscore sorts after. Any file that
-- extends another vertical needs a name that sorts after it.
--
-- WHAT WAS WRONG
--
-- Freight quoting was a description and an amount, typed by hand. Six
-- things that decide whether a forwarder makes money on a file had nowhere
-- to live:
--
-- 1. CHARGEABLE WEIGHT DID NOT EXIST. `freight_items` carried weight_kg
--    and no volume at all, so the number the carrier bills could not even
--    be worked out. An airline bills the GREATER of gross weight and
--    volumetric weight. A 30 kg carton of pillows at 0.5 CBM is 83
--    chargeable kilos on the IATA 6000 divisor. Quoting the 30 gives away
--    53 kilos of freight on every shipment of that shape, silently.
--
-- 2. NO MINIMUM CHARGE. Every air rate has one, and on a small shipment
--    the minimum IS the price. Multiplying rate by weight under-quotes it.
--
-- 3. NO WEIGHT BREAKS. Air tariffs are banded (-45, +45, +100, +300,
--    +500, +1000) and the higher band is cheaper per kilo. That produces
--    the standard freight arithmetic where 44 kg costs MORE than 45 kg.
--    A forwarder who does not check that quotes above the market.
--
-- 4. NO BUY AND SELL. One `amount` per charge line. What the carrier
--    charges and what the client is charged were the same field, so no
--    file could say whether it made a margin until the invoices arrived.
--
-- 5. NO VALIDITY. Sea and air rates expire, often monthly. Nothing
--    recorded when a rate card stopped being true, so quoting off a dead
--    tariff looked exactly like quoting off a live one.
--
-- 6. NO CURRENCY PER LINE. Ocean freight is quoted in USD and local
--    charges are levied in local currency. One numeric column cannot hold
--    both without someone converting in their head.
--
-- WHAT THIS ADDS
--
-- A tariff (rate card) with validity dates and weight-banded rates; cargo
-- that carries volume so chargeable weight is derived rather than guessed;
-- quotes priced BY THE DATABASE from the tariff, with buy and sell held
-- apart; and a seam back into the existing job so an accepted quote
-- becomes the job's charge lines instead of being retyped.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It ships no rates. Not one. Ocean and air rates are commercial terms
-- between a forwarder and a carrier, they change monthly, and a number
-- invented here would be quoted to a real client. Every rate, minimum,
-- break and surcharge is entered by the business, with a `rate_source`
-- field for recording where it came from.
--
-- The two conversion constants ARE defaulted, because they are published
-- conventions rather than prices — the IATA volumetric divisor of 6000
-- cm3/kg and the sea freight revenue-tonne convention of 1 CBM to 1000 kg.
-- Both sit on the tariff and both are editable, because express carriers
-- commonly use 5000 and individual contracts vary. Confirm yours.
--
-- Idempotent. Apply AFTER freight.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. CARGO THAT CAN BE MEASURED
-- Volume is not a nicety. Without it the chargeable weight cannot be
-- worked out, and the chargeable weight is what the carrier invoices.
-- ---------------------------------------------------------------------
ALTER TABLE public.freight_items ADD COLUMN IF NOT EXISTS piece_count numeric DEFAULT 0;
ALTER TABLE public.freight_items ADD COLUMN IF NOT EXISTS length_cm   numeric;
ALTER TABLE public.freight_items ADD COLUMN IF NOT EXISTS width_cm    numeric;
ALTER TABLE public.freight_items ADD COLUMN IF NOT EXISTS height_cm   numeric;
ALTER TABLE public.freight_items ADD COLUMN IF NOT EXISTS volume_cbm  numeric DEFAULT 0;

COMMENT ON COLUMN public.freight_items.piece_count IS
  'Cartons / packages on this line. Separate from quantity, which is the commodity quantity on the declaration.';
COMMENT ON COLUMN public.freight_items.volume_cbm IS
  'Cubic metres. Derived from the dimensions when all three are given, otherwise typed.';

-- Dimensions are PER PIECE, as they are on a packing list. Give all three
-- and the volume follows; give none and type the volume yourself.
CREATE OR REPLACE FUNCTION public.freight_item_volume()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.length_cm IS NOT NULL AND NEW.width_cm IS NOT NULL AND NEW.height_cm IS NOT NULL THEN
    NEW.volume_cbm := round(
      (NEW.length_cm * NEW.width_cm * NEW.height_cm / 1000000.0)
      * greatest(coalesce(NEW.piece_count, 0), 1), 6);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_freight_item_volume ON public.freight_items;
CREATE TRIGGER trg_freight_item_volume
  BEFORE INSERT OR UPDATE ON public.freight_items
  FOR EACH ROW EXECUTE FUNCTION public.freight_item_volume();

-- ---------------------------------------------------------------------
-- 2. TARIFFS — A RATE CARD THAT KNOWS WHEN IT STOPS BEING TRUE
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.freight_tariffs (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  name          text NOT NULL,
  carrier       text,                              -- shipping line, airline, trucker
  mode          text DEFAULT 'sea' NOT NULL,       -- sea | air | land
  service_type  text DEFAULT 'lcl',                -- fcl | lcl | air | truck | courier
  origin        text,
  destination   text,
  currency      text DEFAULT 'USD',

  -- Published conventions, not prices. Editable because contracts differ.
  volumetric_divisor numeric DEFAULT 6000,         -- cm3 per kg (air). Express often 5000.
  wm_kg_per_cbm      numeric DEFAULT 1000,         -- revenue tonne (sea LCL W/M)

  valid_from    date DEFAULT CURRENT_DATE,
  valid_to      date,
  rate_source   text,                              -- where these rates came from
  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_tariffs_pkey PRIMARY KEY (id),
  CONSTRAINT freight_tariffs_mode_check CHECK (mode = ANY (ARRAY['sea','air','land'])),
  CONSTRAINT freight_tariffs_divisor_check CHECK (volumetric_divisor > 0),
  CONSTRAINT freight_tariffs_wm_check CHECK (wm_kg_per_cbm > 0),
  CONSTRAINT freight_tariffs_validity_check CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

COMMENT ON TABLE public.freight_tariffs IS
  'A carrier rate card. Kareya ships no rates: every figure here is entered by the business.';

-- ---- the lines on the card ------------------------------------------
-- A charge_code may appear several times with different weight bands.
-- That is a weight break, and it is why 44 kg can cost more than 45 kg.
CREATE TABLE IF NOT EXISTS public.freight_tariff_rates (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  tariff_id      uuid NOT NULL,
  charge_code    text NOT NULL,                    -- FRT | FSC | THC | DOC | CUS | ...
  description    text NOT NULL,
  basis          text DEFAULT 'per_kg' NOT NULL,
  container_type text,                             -- 20GP | 40GP | 40HC — per_container only
  break_from_kg  numeric DEFAULT 0 NOT NULL,       -- band floor, inclusive
  break_to_kg    numeric,                          -- band ceiling, exclusive; NULL = open
  buy_rate       numeric DEFAULT 0 NOT NULL,       -- what the carrier charges us
  sell_rate      numeric DEFAULT 0 NOT NULL,       -- what the client is charged
  minimum_charge numeric DEFAULT 0 NOT NULL,       -- MIN. On a small shipment this IS the price.
  currency       text,                             -- NULL = the tariff's currency
  is_disbursement boolean DEFAULT false,           -- fronted for the client, never revenue
  sort_order     integer DEFAULT 0,
  notes          text,
  created_at     timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_tariff_rates_pkey PRIMARY KEY (id),
  CONSTRAINT freight_tariff_rates_tariff_fkey FOREIGN KEY (tariff_id)
    REFERENCES public.freight_tariffs(id) ON DELETE CASCADE,
  CONSTRAINT freight_tariff_rates_basis_check CHECK (basis = ANY (ARRAY[
    'per_kg', 'per_cbm', 'per_wm', 'per_container', 'per_shipment',
    'per_document', 'per_piece', 'percent_of_value'])),
  CONSTRAINT freight_tariff_rates_break_check
    CHECK (break_to_kg IS NULL OR break_to_kg > break_from_kg),
  CONSTRAINT freight_tariff_rates_from_check CHECK (break_from_kg >= 0),
  CONSTRAINT freight_tariff_rates_min_check CHECK (minimum_charge >= 0)
);

CREATE INDEX IF NOT EXISTS idx_freight_tariff_rates_tariff ON public.freight_tariff_rates (tariff_id);
CREATE INDEX IF NOT EXISTS idx_freight_tariff_rates_code ON public.freight_tariff_rates (tariff_id, charge_code);
CREATE INDEX IF NOT EXISTS idx_freight_tariffs_active ON public.freight_tariffs (is_active, valid_to);

-- Bands of the same charge code must not overlap, or which rate applies
-- becomes a matter of luck.
CREATE OR REPLACE FUNCTION public.freight_break_no_overlap()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_clash text;
BEGIN
  SELECT coalesce(r.break_from_kg, 0)::text || '–' || coalesce(r.break_to_kg::text, 'up')
    INTO v_clash
    FROM freight_tariff_rates r
   WHERE r.tariff_id = NEW.tariff_id
     AND r.charge_code = NEW.charge_code
     AND coalesce(r.container_type, '') = coalesce(NEW.container_type, '')
     AND r.id <> NEW.id
     -- half-open bands [from, to) overlap when each starts before the other ends
     AND coalesce(NEW.break_to_kg, 'infinity'::numeric) > r.break_from_kg
     AND coalesce(r.break_to_kg, 'infinity'::numeric) > NEW.break_from_kg
   LIMIT 1;

  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION 'Charge % already has a band covering this weight (%). Bands must not overlap.',
      NEW.charge_code, v_clash;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_freight_break_no_overlap ON public.freight_tariff_rates;
CREATE TRIGGER trg_freight_break_no_overlap
  BEFORE INSERT OR UPDATE ON public.freight_tariff_rates
  FOR EACH ROW EXECUTE FUNCTION public.freight_break_no_overlap();

-- ---------------------------------------------------------------------
-- 3. CHARGEABLE WEIGHT
-- The arithmetic the whole module turns on, in one place, so the browser
-- and the invoice cannot disagree about it.
-- ---------------------------------------------------------------------

-- Volumetric (dimensional) weight. A cubic metre is 1,000,000 cm3, so at
-- the IATA divisor of 6000 one CBM is 166.67 kg.
CREATE OR REPLACE FUNCTION public.freight_volumetric_kg(
  p_volume_cbm numeric, p_divisor numeric DEFAULT 6000)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $$
  SELECT CASE WHEN coalesce(p_divisor, 0) <= 0 THEN 0
              ELSE round(coalesce(p_volume_cbm, 0) * 1000000.0 / p_divisor, 4) END;
$$;

-- What an airline bills: the greater of the two.
CREATE OR REPLACE FUNCTION public.freight_chargeable_kg(
  p_gross_kg numeric, p_volume_cbm numeric, p_divisor numeric DEFAULT 6000)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $$
  SELECT greatest(coalesce(p_gross_kg, 0),
                  public.freight_volumetric_kg(p_volume_cbm, p_divisor));
$$;

-- Sea LCL is billed W/M — weight or measurement, whichever is greater,
-- in revenue tonnes. One CBM against one tonne by convention.
CREATE OR REPLACE FUNCTION public.freight_revenue_tonnes(
  p_gross_kg numeric, p_volume_cbm numeric, p_kg_per_cbm numeric DEFAULT 1000)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $$
  SELECT greatest(
    CASE WHEN coalesce(p_kg_per_cbm, 0) <= 0 THEN 0
         ELSE round(coalesce(p_gross_kg, 0) / p_kg_per_cbm, 4) END,
    round(coalesce(p_volume_cbm, 0), 4));
$$;

GRANT EXECUTE ON FUNCTION public.freight_volumetric_kg(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_chargeable_kg(numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_revenue_tonnes(numeric, numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. QUOTES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.freight_quotes (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_no      text,
  revision      text DEFAULT 'A' NOT NULL,
  job_id        uuid,                              -- set when accepted, or quoting an existing file
  client_name   text NOT NULL,
  direction     text DEFAULT 'import',
  mode          text DEFAULT 'sea',
  origin        text,
  destination   text,
  incoterm      text,
  tariff_id     uuid,

  -- the cargo the price is built on
  gross_weight_kg numeric DEFAULT 0 NOT NULL,
  volume_cbm      numeric DEFAULT 0 NOT NULL,
  piece_count     numeric DEFAULT 0 NOT NULL,
  document_count  numeric DEFAULT 1 NOT NULL,
  declared_value  numeric DEFAULT 0 NOT NULL,

  currency      text DEFAULT 'USD',
  fx_rate       numeric DEFAULT 1 NOT NULL,        -- quote currency -> reporting currency
  quote_date    date DEFAULT CURRENT_DATE NOT NULL,
  valid_until   date,                              -- a freight rate that never expires is a fiction
  status        text DEFAULT 'draft' NOT NULL,
  sent_on       date,
  decided_on    date,
  prepared_by   uuid,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_quotes_pkey PRIMARY KEY (id),
  CONSTRAINT freight_quotes_job_fkey FOREIGN KEY (job_id)
    REFERENCES public.freight_jobs(id) ON DELETE SET NULL,
  CONSTRAINT freight_quotes_tariff_fkey FOREIGN KEY (tariff_id)
    REFERENCES public.freight_tariffs(id) ON DELETE SET NULL,
  CONSTRAINT freight_quotes_prepared_fkey FOREIGN KEY (prepared_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT freight_quotes_status_check CHECK (status = ANY (ARRAY[
    'draft', 'sent', 'accepted', 'declined', 'expired', 'superseded'])),
  CONSTRAINT freight_quotes_mode_check CHECK (mode = ANY (ARRAY['sea','air','land'])),
  CONSTRAINT freight_quotes_fx_check CHECK (fx_rate > 0),
  CONSTRAINT freight_quotes_validity_check CHECK (valid_until IS NULL OR valid_until >= quote_date)
);

-- FCL is priced per box, so the boxes have to be counted.
CREATE TABLE IF NOT EXISTS public.freight_quote_containers (
  id              uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_id        uuid NOT NULL,
  container_type  text NOT NULL,                   -- 20GP | 40GP | 40HC | 40RF | ...
  container_count integer DEFAULT 1 NOT NULL,
  CONSTRAINT freight_quote_containers_pkey PRIMARY KEY (id),
  CONSTRAINT freight_quote_containers_quote_fkey FOREIGN KEY (quote_id)
    REFERENCES public.freight_quotes(id) ON DELETE CASCADE,
  CONSTRAINT freight_quote_containers_count_check CHECK (container_count > 0),
  CONSTRAINT uq_freight_quote_container UNIQUE (quote_id, container_type)
);

-- Buy and sell on the same row. A file that cannot say what it cost
-- cannot say what it made.
CREATE TABLE IF NOT EXISTS public.freight_quote_lines (
  id              uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_id        uuid NOT NULL,
  rate_id         uuid,                            -- the tariff line this came from
  charge_code     text,
  description     text NOT NULL,
  basis           text DEFAULT 'per_shipment' NOT NULL,
  quantity        numeric DEFAULT 0 NOT NULL,      -- chargeable kg / CBM / containers / 1
  buy_rate        numeric DEFAULT 0 NOT NULL,
  sell_rate       numeric DEFAULT 0 NOT NULL,
  minimum_charge  numeric DEFAULT 0 NOT NULL,
  minimum_applied boolean DEFAULT false,           -- the MIN beat the calculation
  amount_buy      numeric DEFAULT 0 NOT NULL,
  amount_sell     numeric DEFAULT 0 NOT NULL,
  currency        text,
  fx_rate         numeric DEFAULT 1 NOT NULL,      -- line currency -> quote currency
  is_disbursement boolean DEFAULT false,
  is_manual       boolean DEFAULT false,           -- typed, not priced from the tariff
  sort_order      integer DEFAULT 0,
  notes           text,
  CONSTRAINT freight_quote_lines_pkey PRIMARY KEY (id),
  CONSTRAINT freight_quote_lines_quote_fkey FOREIGN KEY (quote_id)
    REFERENCES public.freight_quotes(id) ON DELETE CASCADE,
  CONSTRAINT freight_quote_lines_rate_fkey FOREIGN KEY (rate_id)
    REFERENCES public.freight_tariff_rates(id) ON DELETE SET NULL,
  CONSTRAINT freight_quote_lines_fx_check CHECK (fx_rate > 0)
);

CREATE INDEX IF NOT EXISTS idx_freight_quotes_status ON public.freight_quotes (status);
CREATE INDEX IF NOT EXISTS idx_freight_quotes_job ON public.freight_quotes (job_id);
CREATE INDEX IF NOT EXISTS idx_freight_quote_lines_quote ON public.freight_quote_lines (quote_id);
CREATE INDEX IF NOT EXISTS idx_freight_quote_containers_quote ON public.freight_quote_containers (quote_id);

-- ---- numbering -------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.freight_quote_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'FQ-',
  width   integer DEFAULT 4,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT freight_quote_series_pkey PRIMARY KEY (id),
  CONSTRAINT freight_quote_series_singleton CHECK (id = true)
);
INSERT INTO public.freight_quote_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_freight_quote_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_s freight_quote_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('freight_quote_series'));
  SELECT * INTO v_s FROM freight_quote_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO freight_quote_series (id) VALUES (true) RETURNING * INTO v_s; END IF;
  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE freight_quote_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE freight_quote_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;
  RETURN coalesce(v_s.prefix, 'FQ-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 4), 1), '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.freight_quote_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  -- A revision keeps the number it was given; only a new quote takes one.
  IF NEW.quote_no IS NULL OR trim(NEW.quote_no) = '' THEN
    NEW.quote_no := allocate_freight_quote_no(coalesce(NEW.quote_date, CURRENT_DATE));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_freight_quote_number ON public.freight_quotes;
CREATE TRIGGER trg_freight_quote_number
  BEFORE INSERT ON public.freight_quotes
  FOR EACH ROW EXECUTE FUNCTION public.freight_quote_number();

-- A quote that has gone to the client is what the client was sent.
CREATE OR REPLACE FUNCTION public.freight_quote_line_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_status text; v_quote uuid;
BEGIN
  v_quote := coalesce(NEW.quote_id, OLD.quote_id);
  SELECT status INTO v_status FROM freight_quotes WHERE id = v_quote;
  IF v_status IN ('sent', 'accepted', 'declined', 'superseded')
     AND coalesce(current_setting('kareya.freight_repricing', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This quote has gone to the client. Take a revision rather than changing what they were sent.';
  END IF;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_freight_quote_line_frozen ON public.freight_quote_lines;
CREATE TRIGGER trg_freight_quote_line_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.freight_quote_lines
  FOR EACH ROW EXECUTE FUNCTION public.freight_quote_line_frozen();

-- ---------------------------------------------------------------------
-- 5. PRICING
-- ---------------------------------------------------------------------

-- How much of a thing this quote is buying, for a given basis.
CREATE OR REPLACE FUNCTION public.freight_basis_quantity(
  p_quote_id uuid, p_basis text, p_container_type text DEFAULT NULL)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_q freight_quotes; v_div numeric; v_wm numeric;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;

  SELECT coalesce(t.volumetric_divisor, 6000), coalesce(t.wm_kg_per_cbm, 1000)
    INTO v_div, v_wm
    FROM freight_tariffs t WHERE t.id = v_q.tariff_id;
  v_div := coalesce(v_div, 6000);
  v_wm  := coalesce(v_wm, 1000);

  RETURN CASE p_basis
    WHEN 'per_kg'    THEN freight_chargeable_kg(v_q.gross_weight_kg, v_q.volume_cbm, v_div)
    WHEN 'per_cbm'   THEN round(v_q.volume_cbm, 4)
    WHEN 'per_wm'    THEN freight_revenue_tonnes(v_q.gross_weight_kg, v_q.volume_cbm, v_wm)
    WHEN 'per_piece' THEN v_q.piece_count
    WHEN 'per_document' THEN v_q.document_count
    WHEN 'percent_of_value' THEN v_q.declared_value
    WHEN 'per_container' THEN coalesce((
      SELECT sum(c.container_count) FROM freight_quote_containers c
       WHERE c.quote_id = p_quote_id
         AND (p_container_type IS NULL OR c.container_type = p_container_type)), 0)
    ELSE 1                                          -- per_shipment
  END;
END;
$$;

-- Which band of a charge code applies at this weight. Half-open [from, to).
CREATE OR REPLACE FUNCTION public.freight_pick_rate(
  p_tariff_id uuid, p_charge_code text, p_chargeable_kg numeric,
  p_container_type text DEFAULT NULL)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT r.id FROM freight_tariff_rates r
   WHERE r.tariff_id = p_tariff_id
     AND r.charge_code = p_charge_code
     AND coalesce(r.container_type, '') = coalesce(p_container_type, '')
     AND coalesce(p_chargeable_kg, 0) >= r.break_from_kg
     AND (r.break_to_kg IS NULL OR coalesce(p_chargeable_kg, 0) < r.break_to_kg)
   ORDER BY r.break_from_kg DESC
   LIMIT 1;
$$;

-- The standard freight trap, made visible: a higher weight band carries a
-- lower rate, so paying for the break weight can cost LESS than paying for
-- what you actually have. Reports the saving; changes nothing.
DROP FUNCTION IF EXISTS public.freight_break_advice(uuid, text, numeric);
CREATE OR REPLACE FUNCTION public.freight_break_advice(
  p_tariff_id uuid, p_charge_code text, p_chargeable_kg numeric)
 RETURNS TABLE (
   out_next_break_kg numeric,
   out_as_shipped    numeric,
   out_at_break      numeric,
   out_saving        numeric
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_here freight_tariff_rates;
  v_next freight_tariff_rates;
  v_here_amt numeric; v_next_amt numeric;
BEGIN
  SELECT * INTO v_here FROM freight_tariff_rates
   WHERE id = freight_pick_rate(p_tariff_id, p_charge_code, p_chargeable_kg);
  IF v_here.id IS NULL THEN RETURN; END IF;

  -- the cheapest band above the one we are in
  SELECT * INTO v_next FROM freight_tariff_rates r
   WHERE r.tariff_id = p_tariff_id
     AND r.charge_code = p_charge_code
     AND r.break_from_kg > coalesce(p_chargeable_kg, 0)
   ORDER BY r.break_from_kg ASC
   LIMIT 1;
  IF v_next.id IS NULL THEN RETURN; END IF;

  v_here_amt := greatest(round(coalesce(p_chargeable_kg, 0) * v_here.sell_rate, 4), v_here.minimum_charge);
  v_next_amt := greatest(round(v_next.break_from_kg * v_next.sell_rate, 4), v_next.minimum_charge);

  IF v_next_amt >= v_here_amt THEN RETURN; END IF;   -- no trap here

  out_next_break_kg := v_next.break_from_kg;
  out_as_shipped    := v_here_amt;
  out_at_break      := v_next_amt;
  out_saving        := round(v_here_amt - v_next_amt, 4);
  RETURN NEXT;
END;
$$;

-- Rebuild a quote's lines from its tariff. Manual lines are kept: a
-- forwarder always has one charge the rate card never anticipated.
CREATE OR REPLACE FUNCTION public.price_freight_quote(p_quote_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_q freight_quotes;
  v_t freight_tariffs;
  v_kg numeric;
  v_rate record;
  v_qty numeric;
  v_cur text;
  v_n integer := 0;
  v_sort integer := 0;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status <> 'draft' THEN
    RAISE EXCEPTION 'This quote is already %. Take a revision to reprice it.', v_q.status;
  END IF;
  IF v_q.tariff_id IS NULL THEN
    RAISE EXCEPTION 'Pick the tariff this is priced on. Without one there are no rates to apply.';
  END IF;

  SELECT * INTO v_t FROM freight_tariffs WHERE id = v_q.tariff_id;
  IF v_t.is_active IS FALSE THEN
    RAISE EXCEPTION 'That tariff has been withdrawn.';
  END IF;
  IF v_t.valid_to IS NOT NULL AND v_q.quote_date > v_t.valid_to THEN
    RAISE EXCEPTION 'That tariff expired on %. Load the current rates before quoting.', v_t.valid_to;
  END IF;
  IF v_q.quote_date < v_t.valid_from THEN
    RAISE EXCEPTION 'That tariff does not start until %.', v_t.valid_from;
  END IF;

  v_kg := freight_chargeable_kg(v_q.gross_weight_kg, v_q.volume_cbm,
                                coalesce(v_t.volumetric_divisor, 6000));

  -- Repricing rewrites priced lines. The guard lets it, once.
  PERFORM set_config('kareya.freight_repricing', 'on', true);
  DELETE FROM freight_quote_lines WHERE quote_id = p_quote_id AND is_manual = false;

  FOR v_rate IN
    SELECT r.* FROM freight_tariff_rates r
     WHERE r.tariff_id = v_q.tariff_id
       -- the band that applies at this shipment's chargeable weight
       AND r.id = freight_pick_rate(v_q.tariff_id, r.charge_code, v_kg, r.container_type)
     ORDER BY r.sort_order, r.charge_code
  LOOP
    v_qty := freight_basis_quantity(p_quote_id, v_rate.basis, v_rate.container_type);
    IF coalesce(v_qty, 0) <= 0 AND v_rate.minimum_charge <= 0 THEN
      CONTINUE;                                     -- nothing of this to charge
    END IF;
    v_cur := coalesce(v_rate.currency, v_t.currency, v_q.currency);
    v_sort := v_sort + 10;

    INSERT INTO freight_quote_lines (
      quote_id, rate_id, charge_code, description, basis, quantity,
      buy_rate, sell_rate, minimum_charge, minimum_applied,
      amount_buy, amount_sell, currency, fx_rate, is_disbursement, is_manual, sort_order)
    VALUES (
      p_quote_id, v_rate.id, v_rate.charge_code, v_rate.description, v_rate.basis, v_qty,
      v_rate.buy_rate, v_rate.sell_rate, v_rate.minimum_charge,
      -- the minimum bites when the calculation falls under it
      CASE WHEN v_rate.basis = 'percent_of_value'
           THEN round(v_qty * v_rate.sell_rate / 100.0, 4)
           ELSE round(v_qty * v_rate.sell_rate, 4) END < v_rate.minimum_charge,
      -- percent_of_value is a percentage, not a rate per unit
      CASE WHEN v_rate.basis = 'percent_of_value'
           THEN round(v_qty * v_rate.buy_rate / 100.0, 4)
           ELSE round(v_qty * v_rate.buy_rate, 4) END,
      CASE WHEN v_rate.basis = 'percent_of_value'
           THEN greatest(round(v_qty * v_rate.sell_rate / 100.0, 4), v_rate.minimum_charge)
           ELSE greatest(round(v_qty * v_rate.sell_rate, 4), v_rate.minimum_charge) END,
      v_cur, 1, v_rate.is_disbursement, false, v_sort);
    v_n := v_n + 1;
  END LOOP;

  PERFORM set_config('kareya.freight_repricing', 'off', true);
  RETURN v_n;
END;
$$;

-- What the quote says, totalled the way a forwarder reads it: revenue and
-- disbursements apart, and the margin on the revenue only.
DROP FUNCTION IF EXISTS public.freight_quote_summary(uuid);
CREATE OR REPLACE FUNCTION public.freight_quote_summary(p_quote_id uuid)
 RETURNS TABLE (
   out_chargeable_kg   numeric,
   out_volumetric_kg   numeric,
   out_revenue_tonnes  numeric,
   out_sell            numeric,   -- the forwarder's own fees
   out_disbursements   numeric,   -- fronted for the client, never income
   out_total_to_client numeric,
   out_buy             numeric,   -- what the carrier charges us, revenue lines only
   out_margin          numeric,
   out_margin_pct      numeric,
   out_total_base      numeric    -- total to client in the reporting currency
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_q freight_quotes; v_div numeric; v_wm numeric;
  v_sell numeric; v_disb numeric; v_buy numeric; v_total numeric;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;

  SELECT coalesce(t.volumetric_divisor, 6000), coalesce(t.wm_kg_per_cbm, 1000)
    INTO v_div, v_wm FROM freight_tariffs t WHERE t.id = v_q.tariff_id;
  v_div := coalesce(v_div, 6000); v_wm := coalesce(v_wm, 1000);

  SELECT
    coalesce(sum(l.amount_sell * l.fx_rate) FILTER (WHERE NOT l.is_disbursement), 0),
    coalesce(sum(l.amount_sell * l.fx_rate) FILTER (WHERE l.is_disbursement), 0),
    coalesce(sum(l.amount_buy  * l.fx_rate) FILTER (WHERE NOT l.is_disbursement), 0)
  INTO v_sell, v_disb, v_buy
  FROM freight_quote_lines l WHERE l.quote_id = p_quote_id;

  v_total := v_sell + v_disb;

  out_chargeable_kg   := freight_chargeable_kg(v_q.gross_weight_kg, v_q.volume_cbm, v_div);
  out_volumetric_kg   := freight_volumetric_kg(v_q.volume_cbm, v_div);
  out_revenue_tonnes  := freight_revenue_tonnes(v_q.gross_weight_kg, v_q.volume_cbm, v_wm);
  out_sell            := round(v_sell, 4);
  out_disbursements   := round(v_disb, 4);
  out_total_to_client := round(v_total, 4);
  out_buy             := round(v_buy, 4);
  out_margin          := round(v_sell - v_buy, 4);
  out_margin_pct      := CASE WHEN v_sell = 0 THEN 0
                              ELSE round(100 * (v_sell - v_buy) / v_sell, 2) END;
  out_total_base      := round(v_total * coalesce(v_q.fx_rate, 1), 2);
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. THE LIFE OF A QUOTE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_freight_quote(p_quote_id uuid)
 RETURNS freight_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_q freight_quotes; v_n integer; v_sell numeric; v_buy numeric;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status <> 'draft' THEN RAISE EXCEPTION 'This quote is already %', v_q.status; END IF;

  SELECT count(*) INTO v_n FROM freight_quote_lines WHERE quote_id = p_quote_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'This quote has no charges on it. Price it against a tariff first.';
  END IF;

  IF coalesce(v_q.gross_weight_kg, 0) <= 0 AND coalesce(v_q.volume_cbm, 0) <= 0
     AND NOT EXISTS (SELECT 1 FROM freight_quote_containers WHERE quote_id = p_quote_id) THEN
    RAISE EXCEPTION 'This quote has no cargo on it — no weight, no volume, no containers.';
  END IF;

  IF v_q.valid_until IS NULL THEN
    RAISE EXCEPTION 'Set how long this price holds. A freight rate that never expires is a fiction.';
  END IF;

  SELECT sum.out_sell, sum.out_buy INTO v_sell, v_buy FROM freight_quote_summary(p_quote_id) sum;
  IF v_sell < v_buy THEN
    RAISE EXCEPTION 'This quote sells at % against a buy cost of %. Reprice it or state why in writing.',
      round(v_sell, 2), round(v_buy, 2);
  END IF;

  UPDATE freight_quotes SET status = 'sent', sent_on = CURRENT_DATE
   WHERE id = p_quote_id RETURNING * INTO v_q;
  RETURN v_q;
END;
$$;

-- Accepting turns a quote into a working file. The charge lines are
-- carried across, so nobody retypes what was already agreed.
CREATE OR REPLACE FUNCTION public.accept_freight_quote(p_quote_id uuid)
 RETURNS freight_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_q freight_quotes; v_job freight_jobs; v_job_id uuid; v_total numeric;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'This quote is already %', v_q.status;
  END IF;
  IF v_q.valid_until IS NOT NULL AND v_q.valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'This price expired on %. Take a revision at current rates.', v_q.valid_until;
  END IF;

  v_job_id := v_q.job_id;
  IF v_job_id IS NULL THEN
    INSERT INTO freight_jobs (client_name, direction, mode, origin_port, destination_port,
                              incoterm, status, charges_total, notes)
    VALUES (v_q.client_name, coalesce(v_q.direction, 'import'), coalesce(v_q.mode, 'sea'),
            v_q.origin, v_q.destination, v_q.incoterm, 'booked', 0,
            'From quote ' || coalesce(v_q.quote_no, '') || ' ' || v_q.revision)
    RETURNING id INTO v_job_id;
  ELSE
    UPDATE freight_jobs SET status = 'booked' WHERE id = v_job_id AND status = 'quote';
  END IF;

  -- The job's charges become what was quoted, not what someone remembers.
  DELETE FROM freight_charges WHERE job_id = v_job_id;
  INSERT INTO freight_charges (job_id, description, amount, is_disbursement)
  SELECT v_job_id,
         coalesce(l.charge_code || ' — ', '') || l.description,
         -- line currency -> quote currency -> reporting currency, because the
         -- job holds one plain amount and the ledger reads it
         round(l.amount_sell * l.fx_rate * coalesce(v_q.fx_rate, 1), 2),
         l.is_disbursement
    FROM freight_quote_lines l WHERE l.quote_id = p_quote_id
   ORDER BY l.sort_order;

  SELECT coalesce(sum(amount), 0) INTO v_total FROM freight_charges WHERE job_id = v_job_id;
  UPDATE freight_jobs SET charges_total = v_total WHERE id = v_job_id RETURNING * INTO v_job;

  UPDATE freight_quotes
     SET status = 'accepted', decided_on = CURRENT_DATE, job_id = v_job_id
   WHERE id = p_quote_id;

  RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.decline_freight_quote(p_quote_id uuid, p_reason text DEFAULT NULL)
 RETURNS freight_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_q freight_quotes;
BEGIN
  SELECT * INTO v_q FROM freight_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status NOT IN ('draft', 'sent') THEN
    RAISE EXCEPTION 'This quote is already %', v_q.status;
  END IF;
  -- A lost quote is worth more than a deleted one: it says what the market
  -- would not pay.
  UPDATE freight_quotes
     SET status = 'declined', decided_on = CURRENT_DATE,
         notes = coalesce(notes || E'\n', '') || 'Declined: ' || coalesce(p_reason, 'no reason given')
   WHERE id = p_quote_id RETURNING * INTO v_q;
  RETURN v_q;
END;
$$;

-- A revision copies the shape and leaves the sent quote exactly as sent.
CREATE OR REPLACE FUNCTION public.revise_freight_quote(
  p_quote_id uuid, p_tariff_id uuid DEFAULT NULL)
 RETURNS freight_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_old freight_quotes; v_new freight_quotes; v_new_id uuid;
BEGIN
  SELECT * INTO v_old FROM freight_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_old.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;

  INSERT INTO freight_quotes (
    quote_no, revision, job_id, client_name, direction, mode, origin, destination,
    incoterm, tariff_id, gross_weight_kg, volume_cbm, piece_count, document_count,
    declared_value, currency, fx_rate, quote_date, valid_until, status, prepared_by, notes)
  VALUES (
    v_old.quote_no, chr(ascii(v_old.revision) + 1), v_old.job_id, v_old.client_name,
    v_old.direction, v_old.mode, v_old.origin, v_old.destination, v_old.incoterm,
    coalesce(p_tariff_id, v_old.tariff_id), v_old.gross_weight_kg, v_old.volume_cbm,
    v_old.piece_count, v_old.document_count, v_old.declared_value, v_old.currency,
    v_old.fx_rate, CURRENT_DATE, NULL, 'draft', v_old.prepared_by, v_old.notes)
  RETURNING id INTO v_new_id;

  INSERT INTO freight_quote_containers (quote_id, container_type, container_count)
  SELECT v_new_id, c.container_type, c.container_count
    FROM freight_quote_containers c WHERE c.quote_id = p_quote_id;

  -- Manual lines are carried; priced lines come back from the tariff.
  PERFORM set_config('kareya.freight_repricing', 'on', true);
  INSERT INTO freight_quote_lines (
    quote_id, rate_id, charge_code, description, basis, quantity, buy_rate, sell_rate,
    minimum_charge, minimum_applied, amount_buy, amount_sell, currency, fx_rate,
    is_disbursement, is_manual, sort_order, notes)
  SELECT v_new_id, l.rate_id, l.charge_code, l.description, l.basis, l.quantity,
         l.buy_rate, l.sell_rate, l.minimum_charge, l.minimum_applied, l.amount_buy,
         l.amount_sell, l.currency, l.fx_rate, l.is_disbursement, l.is_manual,
         l.sort_order, l.notes
    FROM freight_quote_lines l WHERE l.quote_id = p_quote_id AND l.is_manual = true;
  PERFORM set_config('kareya.freight_repricing', 'off', true);

  IF v_old.status IN ('draft', 'sent') THEN
    UPDATE freight_quotes SET status = 'superseded' WHERE id = p_quote_id;
  END IF;

  SELECT * INTO v_new FROM freight_quotes WHERE id = v_new_id;
  RETURN v_new;
END;
$$;

-- Validity is only real if something acts on it.
CREATE OR REPLACE FUNCTION public.expire_freight_quotes()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  WITH gone AS (
    UPDATE freight_quotes SET status = 'expired'
     WHERE status = 'sent' AND valid_until IS NOT NULL AND valid_until < CURRENT_DATE
     RETURNING 1)
  SELECT count(*) INTO v_n FROM gone;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. WHAT NEEDS LOOKING AT
-- Names the drift. Fixes nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.freight_quoting_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Quoted off a rate card that had already expired.
  SELECT 'quote', q.id, coalesce(q.quote_no, '—') || ' ' || q.revision,
         'Priced on tariff "' || t.name || '", which expired on ' || t.valid_to::text || '.'
    FROM freight_quotes q JOIN freight_tariffs t ON t.id = q.tariff_id
   WHERE t.valid_to IS NOT NULL AND q.quote_date > t.valid_to

  UNION ALL
  -- Sent below what the carrier charges us.
  SELECT 'quote', q.id, coalesce(q.quote_no, '—') || ' ' || q.revision,
         'Sells at ' || round(sum.out_sell, 2)::text || ' against a buy cost of '
         || round(sum.out_buy, 2)::text || '.'
    FROM freight_quotes q CROSS JOIN LATERAL freight_quote_summary(q.id) sum
   WHERE q.status IN ('sent', 'accepted') AND sum.out_sell < sum.out_buy

  UNION ALL
  -- Still open, and the price no longer holds.
  SELECT 'quote', q.id, coalesce(q.quote_no, '—') || ' ' || q.revision,
         'Still shown as sent but the price expired on ' || q.valid_until::text || '.'
    FROM freight_quotes q
   WHERE q.status = 'sent' AND q.valid_until IS NOT NULL AND q.valid_until < CURRENT_DATE

  UNION ALL
  -- Cargo that cannot be priced: an air shipment with no volume is billed
  -- on gross weight, which is the defect this module was built to stop.
  SELECT 'quote', q.id, coalesce(q.quote_no, '—') || ' ' || q.revision,
         'Air shipment with no volume recorded, so the chargeable weight is only the gross weight.'
    FROM freight_quotes q
   WHERE q.mode = 'air' AND coalesce(q.volume_cbm, 0) = 0 AND coalesce(q.gross_weight_kg, 0) > 0

  UNION ALL
  -- The job drifted away from what was accepted.
  SELECT 'job', j.id, coalesce(j.job_no, j.client_name),
         'Billed ' || round(coalesce(j.charges_total, 0), 2)::text
         || ' against an accepted quote of ' || qt.quoted::text || '.'
    FROM freight_jobs j
    JOIN freight_quotes q ON q.job_id = j.id AND q.status = 'accepted'
    CROSS JOIN LATERAL (
      -- the same rounding accept_freight_quote used, so a cent of rounding
      -- is never reported as drift
      SELECT coalesce(sum(round(l.amount_sell * l.fx_rate * coalesce(q.fx_rate, 1), 2)), 0) AS quoted
        FROM freight_quote_lines l WHERE l.quote_id = q.id) qt
   WHERE abs(coalesce(j.charges_total, 0) - qt.quoted) > 0.001

  UNION ALL
  -- A file nobody priced.
  SELECT 'job', j.id, coalesce(j.job_no, j.client_name),
         'Has charges but no quote behind them, so nothing says where the price came from.'
    FROM freight_jobs j
   WHERE coalesce(j.charges_total, 0) > 0
     AND NOT EXISTS (SELECT 1 FROM freight_quotes q WHERE q.job_id = j.id)

  UNION ALL
  -- A rate card nobody has replaced.
  SELECT 'tariff', t.id, t.name,
         'Still active but expired on ' || t.valid_to::text || '.'
    FROM freight_tariffs t
   WHERE t.is_active AND t.valid_to IS NOT NULL AND t.valid_to < CURRENT_DATE;
$$;

GRANT EXECUTE ON FUNCTION public.freight_basis_quantity(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_pick_rate(uuid, text, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_break_advice(uuid, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.price_freight_quote(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_quote_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_freight_quote(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_freight_quote(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_freight_quote(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revise_freight_quote(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expire_freight_quotes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.freight_quoting_reconciliation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_freight_quote_no(date) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
-- Buy rates are what the forwarder pays the carrier. A client who sees
-- them sees the margin, so this is the most confidential table in the
-- module and it follows the same roles as the rest of freight.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['freight_tariffs', 'freight_tariff_rates', 'freight_quotes',
                           'freight_quote_containers', 'freight_quote_lines']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']))$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
