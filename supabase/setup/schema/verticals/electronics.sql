-- =====================================================================
-- KAREYA SILO — VERTICAL: PHONE & ELECTRONICS
-- ---------------------------------------------------------------------
-- Retail of phones/electronics tracked per physical unit (IMEI / serial),
-- plus a repair workshop with warranty cover.
--
--   device_units    — one row per physical handset/device in stock
--   device_sales    — the sale of a unit, stamping the warranty expiry
--   device_repairs  — repair tickets; warranty repairs bill at zero
--
-- Idempotent: safe to re-run against an existing Silo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- device_units — serialised stock. An IMEI is globally unique, hence the
-- partial UNIQUE index (units without a serial are still allowed).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.device_units (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  model text NOT NULL,
  brand text,
  serial_no text,                              -- IMEI / serial
  color text,
  storage text,                                -- e.g. '128GB'
  cost_price numeric DEFAULT 0,
  sale_price numeric DEFAULT 0,
  status text DEFAULT 'in_stock'::text,        -- in_stock | sold | returned
  warranty_months integer DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT device_units_pkey PRIMARY KEY (id),
  CONSTRAINT device_units_status_check CHECK (status = ANY (ARRAY['in_stock','sold','returned'])),
  CONSTRAINT device_units_cost_price_check CHECK (cost_price >= 0),
  CONSTRAINT device_units_sale_price_check CHECK (sale_price >= 0),
  CONSTRAINT device_units_warranty_months_check CHECK (warranty_months >= 0)
);
-- An IMEI/serial identifies exactly one device — enforce it where present.
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_units_serial_no ON public.device_units (serial_no) WHERE serial_no IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_device_units_status ON public.device_units (status);
CREATE INDEX IF NOT EXISTS idx_device_units_model ON public.device_units (model);

-- ---------------------------------------------------------------------
-- device_sales — a unit leaving stock. warranty_until is stamped at the
-- point of sale (sale date + the unit's warranty_months) so a later change
-- to the unit record cannot retroactively alter a customer's cover.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.device_sales (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_no text,
  unit_id uuid,
  customer_name text NOT NULL,
  customer_phone text,
  price numeric DEFAULT 0,
  date date DEFAULT CURRENT_DATE NOT NULL,
  warranty_until date,
  sold_by uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT device_sales_pkey PRIMARY KEY (id),
  CONSTRAINT device_sales_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.device_units(id) ON DELETE SET NULL,
  CONSTRAINT device_sales_sold_by_fkey FOREIGN KEY (sold_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT device_sales_price_check CHECK (price >= 0),
  CONSTRAINT device_sales_warranty_until_check CHECK (warranty_until IS NULL OR warranty_until >= date)
);
CREATE INDEX IF NOT EXISTS idx_device_sales_unit_id ON public.device_sales (unit_id);
CREATE INDEX IF NOT EXISTS idx_device_sales_date ON public.device_sales (date);
CREATE INDEX IF NOT EXISTS idx_device_sales_warranty_until ON public.device_sales (warranty_until);
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_sales_sale_no ON public.device_sales (sale_no) WHERE sale_no IS NOT NULL;

-- ---------------------------------------------------------------------
-- device_repairs — bench tickets. Pipeline:
--   received -> diagnosing -> repairing -> ready -> collected
-- ('cancelled' may be reached from anywhere.) Repairs carried out under
-- warranty are free, so total is held at 0 for those tickets.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.device_repairs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  ticket_no text,
  customer_name text NOT NULL,
  customer_phone text,
  device_model text,
  serial_no text,                              -- IMEI / serial of the device on the bench
  fault_reported text,
  diagnosis text,
  parts_cost numeric DEFAULT 0,
  labour_cost numeric DEFAULT 0,
  total numeric DEFAULT 0,
  under_warranty boolean DEFAULT false NOT NULL,
  status text DEFAULT 'received'::text,        -- received | diagnosing | repairing | ready | collected | cancelled
  technician_id uuid,
  received_date date DEFAULT CURRENT_DATE NOT NULL,
  collected_date date,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT device_repairs_pkey PRIMARY KEY (id),
  CONSTRAINT device_repairs_technician_id_fkey FOREIGN KEY (technician_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT device_repairs_status_check CHECK (status = ANY (ARRAY['received','diagnosing','repairing','ready','collected','cancelled'])),
  CONSTRAINT device_repairs_parts_cost_check CHECK (parts_cost >= 0),
  CONSTRAINT device_repairs_labour_cost_check CHECK (labour_cost >= 0),
  CONSTRAINT device_repairs_total_check CHECK (total >= 0),
  -- A warranty job never bills the customer.
  CONSTRAINT device_repairs_warranty_free_check CHECK (under_warranty = false OR total = 0),
  CONSTRAINT device_repairs_collected_date_check CHECK (collected_date IS NULL OR collected_date >= received_date)
);
CREATE INDEX IF NOT EXISTS idx_device_repairs_status ON public.device_repairs (status);
CREATE INDEX IF NOT EXISTS idx_device_repairs_serial_no ON public.device_repairs (serial_no);
CREATE INDEX IF NOT EXISTS idx_device_repairs_technician_id ON public.device_repairs (technician_id);
CREATE INDEX IF NOT EXISTS idx_device_repairs_received_date ON public.device_repairs (received_date);
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_repairs_ticket_no ON public.device_repairs (ticket_no) WHERE ticket_no IS NOT NULL;

-- =====================================================================
-- Row Level Security — phone & electronics
-- Technicians work the bench, Cashiers sell and take payment, Managers
-- oversee. Accountants get read-only sight for the books.
-- =====================================================================
ALTER TABLE public.device_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_repairs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View device units" ON public.device_units;
DROP POLICY IF EXISTS "Manage device units" ON public.device_units;
DROP POLICY IF EXISTS "View device sales" ON public.device_sales;
DROP POLICY IF EXISTS "Manage device sales" ON public.device_sales;
DROP POLICY IF EXISTS "View device repairs" ON public.device_repairs;
DROP POLICY IF EXISTS "Manage device repairs" ON public.device_repairs;

CREATE POLICY "View device units" ON public.device_units FOR SELECT TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Accountant','Manager']));
CREATE POLICY "Manage device units" ON public.device_units FOR ALL TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Technician','Cashier','Manager']));

CREATE POLICY "View device sales" ON public.device_sales FOR SELECT TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Accountant','Manager']));
CREATE POLICY "Manage device sales" ON public.device_sales FOR ALL TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Technician','Cashier','Manager']));

CREATE POLICY "View device repairs" ON public.device_repairs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Accountant','Manager']));
CREATE POLICY "Manage device repairs" ON public.device_repairs FOR ALL TO authenticated USING (has_any_role(ARRAY['Technician','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Technician','Cashier','Manager']));
