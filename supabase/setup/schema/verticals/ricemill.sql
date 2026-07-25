-- =====================================================================
-- KAREYA SILO — RICE MILL / AGRO-PROCESSING vertical
-- ---------------------------------------------------------------------
-- One Silo == one business, so there is NO company_id tenant key: the
-- Silo IS the tenant. Access is gated on the local `employees` roster
-- through has_any_role() (defined in kareya_silo_schema.sql), which also
-- returns true for Admin/Founder.
--
-- Flow:
--   1. mill_intakes  — the weighbridge ticket for paddy bought from a
--      farmer. gross_weight is weighed in, a moisture deduction is taken
--      (every point above the 14% base costs 1% of gross), and the
--      supplier is paid on net_weight × price_per_kg. This is a PURCHASE
--      (cost) — never revenue.
--   2. mill_runs     — one milling batch: input_weight kg of paddy in,
--      output_weight kg of product out, yield_pct = out / in × 100.
--   3. mill_outputs  — the per-product breakdown of a run (white rice,
--      broken rice, bran, husk) with weight_kg × unit_price = value.
--      Output value is the sellable side and the only ledger revenue.
--
-- Idempotent: safe to re-run on an existing Silo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.mill_intakes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  intake_no text,                            -- weighbridge ticket no, e.g. 'MI-004312'
  supplier_name text NOT NULL,               -- farmer / collector
  supplier_phone text,
  date date DEFAULT CURRENT_DATE,
  paddy_type text,                           -- e.g. 'Sen Kra Ob', 'IR504'
  gross_weight numeric DEFAULT 0,            -- kg on the weighbridge
  moisture_pct numeric DEFAULT 0,            -- measured moisture
  deduction_kg numeric DEFAULT 0,            -- moisture/impurity deduction
  net_weight numeric DEFAULT 0,              -- gross - deduction
  price_per_kg numeric DEFAULT 0,
  total_cost numeric DEFAULT 0,              -- net_weight * price_per_kg
  paid boolean DEFAULT false,                -- supplier settled?
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT mill_intakes_pkey PRIMARY KEY (id),
  CONSTRAINT mill_intakes_gross_weight_check CHECK (gross_weight >= 0),
  CONSTRAINT mill_intakes_moisture_pct_check CHECK (moisture_pct >= 0 AND moisture_pct <= 100),
  CONSTRAINT mill_intakes_deduction_kg_check CHECK (deduction_kg >= 0 AND deduction_kg <= gross_weight),
  CONSTRAINT mill_intakes_net_weight_check CHECK (net_weight >= 0),
  CONSTRAINT mill_intakes_price_per_kg_check CHECK (price_per_kg >= 0),
  CONSTRAINT mill_intakes_total_cost_check CHECK (total_cost >= 0)
);

CREATE TABLE IF NOT EXISTS public.mill_runs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  run_no text,                               -- batch no, e.g. 'MR-004312'
  date date DEFAULT CURRENT_DATE,
  input_weight numeric DEFAULT 0,            -- kg paddy milled
  output_weight numeric DEFAULT 0,           -- total kg produced (sum of outputs)
  yield_pct numeric DEFAULT 0,               -- output_weight / input_weight * 100
  operator_id uuid,                          -- employee running the mill
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT mill_runs_pkey PRIMARY KEY (id),
  CONSTRAINT mill_runs_operator_id_fkey FOREIGN KEY (operator_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT mill_runs_input_weight_check CHECK (input_weight >= 0),
  CONSTRAINT mill_runs_output_weight_check CHECK (output_weight >= 0),
  CONSTRAINT mill_runs_yield_pct_check CHECK (yield_pct >= 0 AND yield_pct <= 200)
);

CREATE TABLE IF NOT EXISTS public.mill_outputs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  run_id uuid NOT NULL,
  product text DEFAULT 'white rice'::text,   -- white rice | broken rice | bran | husk
  weight_kg numeric DEFAULT 0,
  unit_price numeric DEFAULT 0,
  value numeric DEFAULT 0,                   -- weight_kg * unit_price
  CONSTRAINT mill_outputs_pkey PRIMARY KEY (id),
  CONSTRAINT mill_outputs_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.mill_runs(id) ON DELETE CASCADE,
  CONSTRAINT mill_outputs_product_check CHECK (product = ANY (ARRAY['white rice','broken rice','bran','husk'])),
  CONSTRAINT mill_outputs_weight_kg_check CHECK (weight_kg >= 0),
  CONSTRAINT mill_outputs_unit_price_check CHECK (unit_price >= 0),
  CONSTRAINT mill_outputs_value_check CHECK (value >= 0)
);

CREATE INDEX IF NOT EXISTS idx_mill_intakes_date ON public.mill_intakes (date);
CREATE INDEX IF NOT EXISTS idx_mill_intakes_paid ON public.mill_intakes (paid);
CREATE INDEX IF NOT EXISTS idx_mill_runs_date ON public.mill_runs (date);
CREATE INDEX IF NOT EXISTS idx_mill_runs_operator_id ON public.mill_runs (operator_id);
CREATE INDEX IF NOT EXISTS idx_mill_outputs_run_id ON public.mill_outputs (run_id);
CREATE INDEX IF NOT EXISTS idx_mill_outputs_product ON public.mill_outputs (product);

-- ---------------------------------------------------------------------
-- Row Level Security
-- Mill Operator / Cashier / Manager run the floor; Accountant reads only
-- (they settle suppliers and book output revenue from the ledger side).
-- ---------------------------------------------------------------------
ALTER TABLE public.mill_intakes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mill_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mill_outputs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View mill intakes" ON public.mill_intakes;
CREATE POLICY "View mill intakes" ON public.mill_intakes FOR SELECT TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage mill intakes" ON public.mill_intakes;
CREATE POLICY "Manage mill intakes" ON public.mill_intakes FOR ALL TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Mill Operator','Cashier','Manager']));

DROP POLICY IF EXISTS "View mill runs" ON public.mill_runs;
CREATE POLICY "View mill runs" ON public.mill_runs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage mill runs" ON public.mill_runs;
CREATE POLICY "Manage mill runs" ON public.mill_runs FOR ALL TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Mill Operator','Cashier','Manager']));

DROP POLICY IF EXISTS "View mill outputs" ON public.mill_outputs;
CREATE POLICY "View mill outputs" ON public.mill_outputs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage mill outputs" ON public.mill_outputs;
CREATE POLICY "Manage mill outputs" ON public.mill_outputs FOR ALL TO authenticated USING (has_any_role(ARRAY['Mill Operator','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Mill Operator','Cashier','Manager']));
