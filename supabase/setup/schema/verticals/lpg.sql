-- =====================================================================
-- KAREYA SILO — VERTICAL: LPG / GAS CYLINDER DISTRIBUTION (lpg)
-- ---------------------------------------------------------------------
-- Not a delivery business with heavy bottles. Three things make it its own
-- vertical, and all three are absent everywhere else in Kareya:
--
-- 1. THE CYLINDER IS AN ASSET YOU OWN, IN SOMEBODY ELSE'S KITCHEN.
--    Water Delivery counts bottles. Here you must know that cylinder
--    LPG-00412 is physically at a named restaurant right now, because it
--    is your property and it is worth more than the gas inside it. So
--    cylinders are individually tracked, with a current holder.
--
-- 2. THE SALE IS A SWAP, NOT A DELIVERY.
--    The customer hands back an empty and takes a full one, paying for gas
--    only. Every other module treats a sale as goods leaving. Here the net
--    movement of steel is zero and the deposit only changes when the
--    customer ends up holding a different NUMBER of cylinders than before.
--
-- 3. AN OUT-OF-TEST CYLINDER MUST NOT BE FILLED OR ISSUED.
--    Cylinders are pressure-tested on a cycle and it is illegal — and
--    dangerous — to keep one in service past its retest date. That is a
--    date the software can check, so it does, in one place
--    (lpg_cylinders.next_test_date) rather than in somebody's head.
--
-- Deposits ride on the shared customer_deposits register (account 2140),
-- so cylinder deposits are a real liability rather than income, and appear
-- alongside rental and lease deposits.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.clients, public.has_any_role(text[]),
--             verticals/deposits.sql (customer_deposits).
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- A cylinder size / product line: 12.5kg household, 15kg, 45kg commercial.
CREATE TABLE IF NOT EXISTS public.lpg_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  size_kg numeric DEFAULT 0,
  gas_price numeric DEFAULT 0,                   -- price of a refill (gas only)
  cylinder_deposit numeric DEFAULT 0,            -- held, refundable, NOT income
  cylinder_value numeric DEFAULT 0,              -- replacement cost if never returned
  test_interval_months integer DEFAULT 60,       -- retest cycle for this line
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lpg_products_pkey PRIMARY KEY (id),
  CONSTRAINT lpg_products_size_check CHECK (size_kg >= 0),
  CONSTRAINT lpg_products_prices_check CHECK (gas_price >= 0 AND cylinder_deposit >= 0 AND cylinder_value >= 0),
  CONSTRAINT lpg_products_test_interval_check CHECK (test_interval_months > 0)
);

-- One physical cylinder. holder_client_id is where the steel is right now:
-- NULL means it is with us (depot), otherwise it is out with that customer.
CREATE TABLE IF NOT EXISTS public.lpg_cylinders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  serial_no text NOT NULL,                       -- stamped on the collar
  product_id uuid,
  state text DEFAULT 'full'::text,               -- full | empty | in_test | condemned
  location text DEFAULT 'depot'::text,           -- depot | with_customer | at_filler | workshop
  holder_client_id uuid,                         -- who physically has it
  manufactured_date date,
  last_test_date date,
  next_test_date date,                           -- the date that takes it out of service
  tare_weight numeric,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lpg_cylinders_pkey PRIMARY KEY (id),
  CONSTRAINT lpg_cylinders_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.lpg_products(id) ON DELETE SET NULL,
  CONSTRAINT lpg_cylinders_holder_fkey FOREIGN KEY (holder_client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT lpg_cylinders_state_check CHECK (state = ANY (ARRAY['full','empty','in_test','condemned'])),
  CONSTRAINT lpg_cylinders_location_check CHECK (location = ANY (ARRAY['depot','with_customer','at_filler','workshop'])),
  CONSTRAINT lpg_cylinders_test_order_check CHECK (next_test_date IS NULL OR last_test_date IS NULL OR next_test_date >= last_test_date),
  -- A cylinder out with a customer must say who has it, and one sitting in
  -- the depot must not claim a holder. Without this the custody record drifts
  -- and "where is cylinder X" stops having an answer.
  CONSTRAINT lpg_cylinders_custody_check CHECK (
    (location = 'with_customer' AND holder_client_id IS NOT NULL)
    OR (location <> 'with_customer' AND holder_client_id IS NULL)
  )
);

-- A counter visit: the customer brings empties back and takes fulls out.
-- Deposits move only when the count they hold changes.
CREATE TABLE IF NOT EXISTS public.lpg_exchanges (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  exchange_no text,
  client_id uuid,
  customer_name text,                            -- walk-in with no client record
  customer_phone text,
  product_id uuid,
  date date DEFAULT CURRENT_DATE,
  fulls_out integer DEFAULT 0,                   -- cylinders handed to the customer
  empties_in integer DEFAULT 0,                  -- cylinders handed back to us
  gas_price numeric DEFAULT 0,                   -- snapshot per cylinder
  gas_total numeric DEFAULT 0,                   -- fulls_out * gas_price
  deposit_taken numeric DEFAULT 0,               -- when they leave holding more
  deposit_refunded numeric DEFAULT 0,            -- when they leave holding fewer
  driver_id uuid,
  paid boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lpg_exchanges_pkey PRIMARY KEY (id),
  CONSTRAINT lpg_exchanges_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT lpg_exchanges_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.lpg_products(id) ON DELETE SET NULL,
  CONSTRAINT lpg_exchanges_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT lpg_exchanges_counts_check CHECK (fulls_out >= 0 AND empties_in >= 0),
  CONSTRAINT lpg_exchanges_amounts_check CHECK (gas_price >= 0 AND gas_total >= 0 AND deposit_taken >= 0 AND deposit_refunded >= 0),
  -- One visit either takes a deposit or gives one back. Both at once means the
  -- net was computed twice.
  CONSTRAINT lpg_exchanges_deposit_direction_check CHECK (deposit_taken = 0 OR deposit_refunded = 0)
);

-- Which serials moved in a visit, and which way. Optional: a small depot can
-- trade by count alone, while a commercial one tracks every serial.
CREATE TABLE IF NOT EXISTS public.lpg_exchange_lines (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  exchange_id uuid NOT NULL,
  cylinder_id uuid,
  direction text NOT NULL,                       -- out (to customer) | in (returned)
  CONSTRAINT lpg_exchange_lines_pkey PRIMARY KEY (id),
  CONSTRAINT lpg_exchange_lines_exchange_id_fkey FOREIGN KEY (exchange_id) REFERENCES public.lpg_exchanges(id) ON DELETE CASCADE,
  CONSTRAINT lpg_exchange_lines_cylinder_id_fkey FOREIGN KEY (cylinder_id) REFERENCES public.lpg_cylinders(id) ON DELETE SET NULL,
  CONSTRAINT lpg_exchange_lines_direction_check CHECK (direction = ANY (ARRAY['out','in']))
);

-- A pressure test / requalification. Writing one is what moves the cylinder's
-- next_test_date forward, so the service date always has a record behind it.
CREATE TABLE IF NOT EXISTS public.lpg_tests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  cylinder_id uuid NOT NULL,
  test_date date DEFAULT CURRENT_DATE,
  next_test_date date,
  result text DEFAULT 'pass'::text,              -- pass | fail
  facility text,
  certificate_no text,
  cost numeric DEFAULT 0,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lpg_tests_pkey PRIMARY KEY (id),
  CONSTRAINT lpg_tests_cylinder_id_fkey FOREIGN KEY (cylinder_id) REFERENCES public.lpg_cylinders(id) ON DELETE CASCADE,
  CONSTRAINT lpg_tests_cost_check CHECK (cost >= 0),
  CONSTRAINT lpg_tests_result_check CHECK (result = ANY (ARRAY['pass','fail'])),
  CONSTRAINT lpg_tests_next_check CHECK (next_test_date IS NULL OR next_test_date >= test_date)
);

-- ---- indexes ------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_lpg_cylinders_serial ON public.lpg_cylinders (serial_no);
CREATE INDEX IF NOT EXISTS idx_lpg_cylinders_state ON public.lpg_cylinders (state);
CREATE INDEX IF NOT EXISTS idx_lpg_cylinders_location ON public.lpg_cylinders (location);
CREATE INDEX IF NOT EXISTS idx_lpg_cylinders_holder ON public.lpg_cylinders (holder_client_id);
-- Drives the "due for test" list, which is the safety report.
CREATE INDEX IF NOT EXISTS idx_lpg_cylinders_next_test ON public.lpg_cylinders (next_test_date);
CREATE INDEX IF NOT EXISTS idx_lpg_exchanges_client ON public.lpg_exchanges (client_id);
CREATE INDEX IF NOT EXISTS idx_lpg_exchanges_date ON public.lpg_exchanges (date);
CREATE INDEX IF NOT EXISTS idx_lpg_exchange_lines_exchange ON public.lpg_exchange_lines (exchange_id);
CREATE INDEX IF NOT EXISTS idx_lpg_tests_cylinder ON public.lpg_tests (cylinder_id);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.lpg_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lpg_cylinders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lpg_exchanges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lpg_exchange_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lpg_tests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View lpg products" ON public.lpg_products;
DROP POLICY IF EXISTS "Manage lpg products" ON public.lpg_products;
CREATE POLICY "View lpg products" ON public.lpg_products FOR SELECT TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Accountant','Manager']));
CREATE POLICY "Manage lpg products" ON public.lpg_products FOR ALL TO authenticated USING (has_any_role(ARRAY['Gas Agent','Manager'])) WITH CHECK (has_any_role(ARRAY['Gas Agent','Manager']));

DROP POLICY IF EXISTS "View lpg cylinders" ON public.lpg_cylinders;
DROP POLICY IF EXISTS "Manage lpg cylinders" ON public.lpg_cylinders;
CREATE POLICY "View lpg cylinders" ON public.lpg_cylinders FOR SELECT TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Accountant','Manager']));
CREATE POLICY "Manage lpg cylinders" ON public.lpg_cylinders FOR ALL TO authenticated USING (has_any_role(ARRAY['Gas Agent','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Gas Agent','Cashier','Manager']));

DROP POLICY IF EXISTS "View lpg exchanges" ON public.lpg_exchanges;
DROP POLICY IF EXISTS "Manage lpg exchanges" ON public.lpg_exchanges;
CREATE POLICY "View lpg exchanges" ON public.lpg_exchanges FOR SELECT TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Accountant','Manager']));
CREATE POLICY "Manage lpg exchanges" ON public.lpg_exchanges FOR ALL TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Manager']));

DROP POLICY IF EXISTS "View lpg exchange lines" ON public.lpg_exchange_lines;
DROP POLICY IF EXISTS "Manage lpg exchange lines" ON public.lpg_exchange_lines;
CREATE POLICY "View lpg exchange lines" ON public.lpg_exchange_lines FOR SELECT TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Accountant','Manager']));
CREATE POLICY "Manage lpg exchange lines" ON public.lpg_exchange_lines FOR ALL TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Manager']));

DROP POLICY IF EXISTS "View lpg tests" ON public.lpg_tests;
DROP POLICY IF EXISTS "Manage lpg tests" ON public.lpg_tests;
CREATE POLICY "View lpg tests" ON public.lpg_tests FOR SELECT TO authenticated USING (has_any_role(ARRAY['Gas Agent','Driver','Cashier','Accountant','Manager']));
CREATE POLICY "Manage lpg tests" ON public.lpg_tests FOR ALL TO authenticated USING (has_any_role(ARRAY['Gas Agent','Manager'])) WITH CHECK (has_any_role(ARRAY['Gas Agent','Manager']));
