-- =====================================================================
-- KAREYA SILO — VERTICAL: PROPERTY DEVELOPER (borey / condo)
-- ---------------------------------------------------------------------
-- Installment sales of housing units. A developer lists PROJECTS (a borey
-- phase, a condo tower), each holding UNITS (villa / shophouse / condo /
-- land). A unit is sold on a CONTRACT: the buyer pays a booking fee and a
-- down payment up front, and the financed remainder
--   (sale_price - booking_fee - down_payment)
-- is spread over `term_months` INSTALLMENTS. When interest_rate > 0 it is
-- an ANNUAL flat rate applied over the term and baked into the schedule;
-- 0 means interest-free installments (the Cambodian borey norm).
--
-- Money in arrives as PAYMENTS, allocated oldest-installment-first
-- (partials allowed). A contract completes when every installment is paid.
--
-- One Silo == one business, so there is NO company_id here — the Silo IS
-- the tenant. Fully idempotent: safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Projects — a borey / condo development (or a phase of one)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dev_projects (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  location text,                             -- commune / district / city
  phase text,                                -- e.g. 'Phase 2'
  total_units integer DEFAULT 0,             -- planned unit count
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT dev_projects_pkey PRIMARY KEY (id),
  CONSTRAINT dev_projects_total_units_check CHECK (total_units >= 0)
);

-- ---------------------------------------------------------------------
-- Units — the sellable inventory inside a project
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dev_units (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  project_id uuid,
  unit_no text NOT NULL,                     -- e.g. 'A-12'
  unit_type text DEFAULT 'villa'::text,      -- villa | shophouse | condo | land
  block text,                                -- block / street / tower
  land_area numeric,                         -- m²
  floor_area numeric,                        -- m²
  list_price numeric DEFAULT 0,
  status text DEFAULT 'available'::text,     -- available | reserved | sold | handed_over
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT dev_units_pkey PRIMARY KEY (id),
  CONSTRAINT dev_units_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.dev_projects(id) ON DELETE SET NULL,
  CONSTRAINT dev_units_status_check CHECK (status = ANY (ARRAY['available','reserved','sold','handed_over'])),
  CONSTRAINT dev_units_type_check CHECK (unit_type = ANY (ARRAY['villa','shophouse','condo','land','apartment','other'])),
  CONSTRAINT dev_units_list_price_check CHECK (list_price >= 0)
);

-- ---------------------------------------------------------------------
-- Contracts — one buyer purchasing one unit on installments
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dev_contracts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  contract_no text,                          -- human-facing sale contract no.
  unit_id uuid,
  buyer_name text NOT NULL,
  buyer_phone text,
  buyer_id_no text,                          -- national ID / passport
  sale_price numeric DEFAULT 0,              -- agreed price (may differ from list)
  booking_fee numeric DEFAULT 0,             -- reservation deposit, paid up front
  down_payment numeric DEFAULT 0,            -- paid up front at signing
  term_months integer DEFAULT 12,            -- number of monthly installments
  interest_rate numeric DEFAULT 0,           -- ANNUAL %, 0 = interest-free
  start_date date DEFAULT CURRENT_DATE,      -- first installment is start_date + 1 month
  status text DEFAULT 'active'::text,        -- draft | active | completed | cancelled
  agent_id uuid,                             -- selling employee
  currency text DEFAULT 'USD'::text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT dev_contracts_pkey PRIMARY KEY (id),
  CONSTRAINT dev_contracts_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.dev_units(id) ON DELETE SET NULL,
  CONSTRAINT dev_contracts_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT dev_contracts_status_check CHECK (status = ANY (ARRAY['draft','active','completed','cancelled'])),
  CONSTRAINT dev_contracts_term_months_check CHECK (term_months >= 0),
  CONSTRAINT dev_contracts_amounts_check CHECK (sale_price >= 0 AND booking_fee >= 0 AND down_payment >= 0 AND interest_rate >= 0),
  CONSTRAINT dev_contracts_upfront_check CHECK (booking_fee + down_payment <= sale_price)
);

-- ---------------------------------------------------------------------
-- Installments — the generated amortization schedule of a contract
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dev_installments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  contract_id uuid NOT NULL,
  installment_no integer NOT NULL,           -- 1-based
  due_date date,
  amount_due numeric DEFAULT 0,
  amount_paid numeric DEFAULT 0,
  status text DEFAULT 'pending'::text,       -- pending | partial | paid
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT dev_installments_pkey PRIMARY KEY (id),
  CONSTRAINT dev_installments_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.dev_contracts(id) ON DELETE CASCADE,
  CONSTRAINT dev_installments_status_check CHECK (status = ANY (ARRAY['pending','partial','paid'])),
  CONSTRAINT dev_installments_amounts_check CHECK (amount_due >= 0 AND amount_paid >= 0),
  CONSTRAINT dev_installments_no_check CHECK (installment_no > 0),
  CONSTRAINT dev_installments_unique_no UNIQUE (contract_id, installment_no)
);

-- ---------------------------------------------------------------------
-- Payments — cash received against a contract. `installment_id` records
-- the FIRST installment the payment was allocated to; a single payment may
-- clear several installments (the allocation lives in dev_installments).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dev_payments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  contract_id uuid NOT NULL,
  installment_id uuid,
  date date DEFAULT CURRENT_DATE,
  amount numeric DEFAULT 0,
  method text DEFAULT 'cash'::text,          -- cash | bank | aba | wing | cheque | other
  received_by uuid,
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT dev_payments_pkey PRIMARY KEY (id),
  CONSTRAINT dev_payments_contract_id_fkey FOREIGN KEY (contract_id) REFERENCES public.dev_contracts(id) ON DELETE CASCADE,
  CONSTRAINT dev_payments_installment_id_fkey FOREIGN KEY (installment_id) REFERENCES public.dev_installments(id) ON DELETE SET NULL,
  CONSTRAINT dev_payments_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT dev_payments_amount_check CHECK (amount >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_dev_units_project_id ON public.dev_units (project_id);
CREATE INDEX IF NOT EXISTS idx_dev_units_status ON public.dev_units (status);
CREATE INDEX IF NOT EXISTS idx_dev_contracts_unit_id ON public.dev_contracts (unit_id);
CREATE INDEX IF NOT EXISTS idx_dev_contracts_status ON public.dev_contracts (status);
CREATE INDEX IF NOT EXISTS idx_dev_contracts_agent_id ON public.dev_contracts (agent_id);
CREATE INDEX IF NOT EXISTS idx_dev_installments_contract_id ON public.dev_installments (contract_id);
CREATE INDEX IF NOT EXISTS idx_dev_installments_due_date ON public.dev_installments (due_date);
CREATE INDEX IF NOT EXISTS idx_dev_installments_status ON public.dev_installments (status);
CREATE INDEX IF NOT EXISTS idx_dev_payments_contract_id ON public.dev_payments (contract_id);
CREATE INDEX IF NOT EXISTS idx_dev_payments_date ON public.dev_payments (date);

-- =====================================================================
-- ROW LEVEL SECURITY
-- Sales Agents work the inventory and write contracts, Accountants collect
-- and reconcile, Managers see and do everything.
-- =====================================================================
ALTER TABLE public.dev_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_installments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View dev projects" ON public.dev_projects;
CREATE POLICY "View dev projects" ON public.dev_projects FOR SELECT TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage dev projects" ON public.dev_projects;
CREATE POLICY "Manage dev projects" ON public.dev_projects FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));

DROP POLICY IF EXISTS "View dev units" ON public.dev_units;
CREATE POLICY "View dev units" ON public.dev_units FOR SELECT TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage dev units" ON public.dev_units;
CREATE POLICY "Manage dev units" ON public.dev_units FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));

DROP POLICY IF EXISTS "View dev contracts" ON public.dev_contracts;
CREATE POLICY "View dev contracts" ON public.dev_contracts FOR SELECT TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage dev contracts" ON public.dev_contracts;
CREATE POLICY "Manage dev contracts" ON public.dev_contracts FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));

DROP POLICY IF EXISTS "View dev installments" ON public.dev_installments;
CREATE POLICY "View dev installments" ON public.dev_installments FOR SELECT TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage dev installments" ON public.dev_installments;
CREATE POLICY "Manage dev installments" ON public.dev_installments FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));

DROP POLICY IF EXISTS "View dev payments" ON public.dev_payments;
CREATE POLICY "View dev payments" ON public.dev_payments FOR SELECT TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage dev payments" ON public.dev_payments;
CREATE POLICY "Manage dev payments" ON public.dev_payments FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Agent','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Agent','Accountant','Manager']));
