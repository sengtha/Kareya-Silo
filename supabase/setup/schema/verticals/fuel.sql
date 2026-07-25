-- =====================================================================
-- KAREYA SILO — VERTICAL: PETROL STATION (fuel)
-- ---------------------------------------------------------------------
-- Tanks hold stock (litres). Pumps draw from a tank and carry a
-- cumulative litre meter (last_reading). An attendant shift is opened,
-- and on close every pump's closing meter is captured:
--     litres_sold = closing_reading - opening_reading
--     amount      = litres_sold * price_per_litre
-- Expected cash is the sum of the shift's amounts; variance is
-- counted_cash - expected_cash (the fuel-station equivalent of the
-- retail Z-report). Closing a shift also decrements each linked tank's
-- current_volume; a delivery increments it.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.has_any_role(text[]).
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- A physical storage tank. current_volume is the live dip reading in litres.
CREATE TABLE IF NOT EXISTS public.fuel_tanks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  fuel_type text DEFAULT 'gasoline'::text,     -- gasoline | diesel | premium | kerosene | lpg
  capacity numeric DEFAULT 0,                  -- litres
  current_volume numeric DEFAULT 0,            -- litres on hand
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fuel_tanks_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_tanks_capacity_check CHECK (capacity >= 0),
  CONSTRAINT fuel_tanks_current_volume_check CHECK (current_volume >= 0)
);

-- A dispenser nozzle. last_reading is the cumulative litre meter, carried
-- forward as the next shift's opening reading.
CREATE TABLE IF NOT EXISTS public.fuel_pumps (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                          -- e.g. 'Pump 1 / Nozzle A'
  tank_id uuid,
  last_reading numeric DEFAULT 0,              -- cumulative litre meter
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fuel_pumps_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_pumps_tank_id_fkey FOREIGN KEY (tank_id) REFERENCES public.fuel_tanks(id) ON DELETE SET NULL,
  CONSTRAINT fuel_pumps_last_reading_check CHECK (last_reading >= 0)
);

-- An attendant shift. Closing it produces the cash reconciliation.
CREATE TABLE IF NOT EXISTS public.fuel_shifts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  shift_number text,
  attendant_id uuid,
  opened_at timestamp with time zone DEFAULT now(),
  closed_at timestamp with time zone,
  expected_cash numeric DEFAULT 0,
  counted_cash numeric DEFAULT 0,
  variance numeric DEFAULT 0,
  status text DEFAULT 'open'::text,            -- open | closed
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fuel_shifts_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_shifts_attendant_id_fkey FOREIGN KEY (attendant_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT fuel_shifts_status_check CHECK (status = ANY (ARRAY['open','closed']))
);

-- One meter reading per pump per shift, captured at close.
CREATE TABLE IF NOT EXISTS public.fuel_readings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  shift_id uuid NOT NULL,
  pump_id uuid,
  opening_reading numeric DEFAULT 0,
  closing_reading numeric DEFAULT 0,
  litres_sold numeric DEFAULT 0,
  price_per_litre numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  CONSTRAINT fuel_readings_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_readings_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES public.fuel_shifts(id) ON DELETE CASCADE,
  CONSTRAINT fuel_readings_pump_id_fkey FOREIGN KEY (pump_id) REFERENCES public.fuel_pumps(id) ON DELETE SET NULL,
  CONSTRAINT fuel_readings_meter_check CHECK (closing_reading >= opening_reading),
  CONSTRAINT fuel_readings_litres_check CHECK (litres_sold >= 0),
  CONSTRAINT fuel_readings_price_check CHECK (price_per_litre >= 0)
);

-- A tanker drop into a tank; increments the tank's current_volume.
CREATE TABLE IF NOT EXISTS public.fuel_deliveries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  tank_id uuid,
  date date DEFAULT CURRENT_DATE,
  litres numeric DEFAULT 0,
  cost_per_litre numeric DEFAULT 0,
  total_cost numeric DEFAULT 0,
  supplier text,
  reference text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fuel_deliveries_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_deliveries_tank_id_fkey FOREIGN KEY (tank_id) REFERENCES public.fuel_tanks(id) ON DELETE SET NULL,
  CONSTRAINT fuel_deliveries_litres_check CHECK (litres > 0),
  CONSTRAINT fuel_deliveries_cost_check CHECK (cost_per_litre >= 0 AND total_cost >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_fuel_pumps_tank_id ON public.fuel_pumps (tank_id);
CREATE INDEX IF NOT EXISTS idx_fuel_shifts_status ON public.fuel_shifts (status);
CREATE INDEX IF NOT EXISTS idx_fuel_shifts_opened_at ON public.fuel_shifts (opened_at);
CREATE INDEX IF NOT EXISTS idx_fuel_readings_shift_id ON public.fuel_readings (shift_id);
CREATE INDEX IF NOT EXISTS idx_fuel_readings_pump_id ON public.fuel_readings (pump_id);
CREATE INDEX IF NOT EXISTS idx_fuel_deliveries_tank_id ON public.fuel_deliveries (tank_id);
CREATE INDEX IF NOT EXISTS idx_fuel_deliveries_date ON public.fuel_deliveries (date);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.fuel_tanks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_pumps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_deliveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View fuel tanks" ON public.fuel_tanks;
DROP POLICY IF EXISTS "Manage fuel tanks" ON public.fuel_tanks;
CREATE POLICY "View fuel tanks" ON public.fuel_tanks FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Accountant','Manager']));
CREATE POLICY "Manage fuel tanks" ON public.fuel_tanks FOR ALL TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pump Attendant','Cashier','Manager']));

DROP POLICY IF EXISTS "View fuel pumps" ON public.fuel_pumps;
DROP POLICY IF EXISTS "Manage fuel pumps" ON public.fuel_pumps;
CREATE POLICY "View fuel pumps" ON public.fuel_pumps FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Accountant','Manager']));
CREATE POLICY "Manage fuel pumps" ON public.fuel_pumps FOR ALL TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pump Attendant','Cashier','Manager']));

DROP POLICY IF EXISTS "View fuel shifts" ON public.fuel_shifts;
DROP POLICY IF EXISTS "Manage fuel shifts" ON public.fuel_shifts;
CREATE POLICY "View fuel shifts" ON public.fuel_shifts FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Accountant','Manager']));
CREATE POLICY "Manage fuel shifts" ON public.fuel_shifts FOR ALL TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pump Attendant','Cashier','Manager']));

DROP POLICY IF EXISTS "View fuel readings" ON public.fuel_readings;
DROP POLICY IF EXISTS "Manage fuel readings" ON public.fuel_readings;
CREATE POLICY "View fuel readings" ON public.fuel_readings FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Accountant','Manager']));
CREATE POLICY "Manage fuel readings" ON public.fuel_readings FOR ALL TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pump Attendant','Cashier','Manager']));

DROP POLICY IF EXISTS "View fuel deliveries" ON public.fuel_deliveries;
DROP POLICY IF EXISTS "Manage fuel deliveries" ON public.fuel_deliveries;
CREATE POLICY "View fuel deliveries" ON public.fuel_deliveries FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Accountant','Manager']));
CREATE POLICY "Manage fuel deliveries" ON public.fuel_deliveries FOR ALL TO authenticated USING (has_any_role(ARRAY['Pump Attendant','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pump Attendant','Cashier','Manager']));
