-- =====================================================================
-- KAREYA SILO — VERTICAL: GARMENT / CMT FACTORY (garment)
-- ---------------------------------------------------------------------
-- Cambodia's cut-make-trim subcontract model. A buyer places a PO
-- (garment_orders) against a style (garment_styles). The style carries
-- the SMV (standard minute value — the minutes of sewing work in one
-- piece) and the CMT price per piece. Sewing lines (garment_lines) book
-- a daily output row (garment_outputs) against the order:
--
--     efficiency_pct = (output_qty * smv)
--                      / (worker_count * working_hours * 60) * 100
--
-- Each output row increments the order's produced_qty; the order flips
-- to 'completed' once produced_qty >= quantity. CMT is normally
-- invoiced on shipment, not on daily output, so the ledger posting is
-- left to the application layer.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.has_any_role(text[]).
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- A buyer style / tech-pack. smv drives every efficiency calculation.
CREATE TABLE IF NOT EXISTS public.garment_styles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  style_no text NOT NULL,                      -- e.g. 'PL-4471'
  name text,
  buyer text,                                  -- H&M, Levi's, Adidas ...
  smv numeric DEFAULT 0,                       -- standard minutes per piece
  cmt_price numeric DEFAULT 0,                 -- cut-make-trim price per piece
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_styles_pkey PRIMARY KEY (id),
  CONSTRAINT garment_styles_smv_check CHECK (smv >= 0),
  CONSTRAINT garment_styles_cmt_price_check CHECK (cmt_price >= 0)
);

-- A buyer purchase order. produced_qty is the running total maintained
-- from garment_outputs.
CREATE TABLE IF NOT EXISTS public.garment_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  po_no text,
  style_id uuid,
  buyer text,
  quantity numeric DEFAULT 0,                  -- pieces ordered
  produced_qty numeric DEFAULT 0,              -- pieces sewn to date
  cmt_price numeric DEFAULT 0,                 -- price per piece on THIS po
  order_date date DEFAULT CURRENT_DATE,
  ship_date date,
  status text DEFAULT 'pending'::text,         -- pending | in_production | completed | shipped | cancelled
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_orders_pkey PRIMARY KEY (id),
  CONSTRAINT garment_orders_style_id_fkey FOREIGN KEY (style_id) REFERENCES public.garment_styles(id) ON DELETE SET NULL,
  CONSTRAINT garment_orders_quantity_check CHECK (quantity >= 0),
  CONSTRAINT garment_orders_produced_qty_check CHECK (produced_qty >= 0),
  CONSTRAINT garment_orders_cmt_price_check CHECK (cmt_price >= 0),
  CONSTRAINT garment_orders_status_check CHECK (status = ANY (ARRAY['pending','in_production','completed','shipped','cancelled']))
);

-- A sewing line. worker_count is the manning used as the efficiency divisor.
CREATE TABLE IF NOT EXISTS public.garment_lines (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                          -- e.g. 'Line A'
  supervisor_id uuid,
  worker_count integer DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_lines_pkey PRIMARY KEY (id),
  CONSTRAINT garment_lines_supervisor_id_fkey FOREIGN KEY (supervisor_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT garment_lines_worker_count_check CHECK (worker_count >= 0)
);

-- One line's output for one day against one order.
CREATE TABLE IF NOT EXISTS public.garment_outputs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  order_id uuid,
  line_id uuid,
  date date DEFAULT CURRENT_DATE NOT NULL,
  output_qty numeric DEFAULT 0,                -- good pieces
  reject_qty numeric DEFAULT 0,
  working_hours numeric DEFAULT 0,             -- hours the line ran
  efficiency_pct numeric DEFAULT 0,            -- (qty * smv) / (workers * hours * 60) * 100
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT garment_outputs_pkey PRIMARY KEY (id),
  CONSTRAINT garment_outputs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.garment_orders(id) ON DELETE CASCADE,
  CONSTRAINT garment_outputs_line_id_fkey FOREIGN KEY (line_id) REFERENCES public.garment_lines(id) ON DELETE SET NULL,
  CONSTRAINT garment_outputs_output_qty_check CHECK (output_qty >= 0),
  CONSTRAINT garment_outputs_reject_qty_check CHECK (reject_qty >= 0),
  CONSTRAINT garment_outputs_working_hours_check CHECK (working_hours >= 0),
  CONSTRAINT garment_outputs_efficiency_check CHECK (efficiency_pct >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_garment_styles_style_no ON public.garment_styles (style_no);
CREATE INDEX IF NOT EXISTS idx_garment_orders_style_id ON public.garment_orders (style_id);
CREATE INDEX IF NOT EXISTS idx_garment_orders_status ON public.garment_orders (status);
CREATE INDEX IF NOT EXISTS idx_garment_orders_ship_date ON public.garment_orders (ship_date);
CREATE INDEX IF NOT EXISTS idx_garment_lines_supervisor_id ON public.garment_lines (supervisor_id);
CREATE INDEX IF NOT EXISTS idx_garment_outputs_order_id ON public.garment_outputs (order_id);
CREATE INDEX IF NOT EXISTS idx_garment_outputs_line_id ON public.garment_outputs (line_id);
CREATE INDEX IF NOT EXISTS idx_garment_outputs_date ON public.garment_outputs (date);
-- The merchandiser's shipment-risk view reads a single order's daily curve.
CREATE INDEX IF NOT EXISTS idx_garment_outputs_order_date ON public.garment_outputs (order_id, date);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.garment_styles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.garment_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.garment_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.garment_outputs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View garment styles" ON public.garment_styles;
DROP POLICY IF EXISTS "Manage garment styles" ON public.garment_styles;
CREATE POLICY "View garment styles" ON public.garment_styles FOR SELECT TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Accountant','Manager']));
CREATE POLICY "Manage garment styles" ON public.garment_styles FOR ALL TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager'])) WITH CHECK (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager']));

DROP POLICY IF EXISTS "View garment orders" ON public.garment_orders;
DROP POLICY IF EXISTS "Manage garment orders" ON public.garment_orders;
CREATE POLICY "View garment orders" ON public.garment_orders FOR SELECT TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Accountant','Manager']));
CREATE POLICY "Manage garment orders" ON public.garment_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager'])) WITH CHECK (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager']));

DROP POLICY IF EXISTS "View garment lines" ON public.garment_lines;
DROP POLICY IF EXISTS "Manage garment lines" ON public.garment_lines;
CREATE POLICY "View garment lines" ON public.garment_lines FOR SELECT TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Accountant','Manager']));
CREATE POLICY "Manage garment lines" ON public.garment_lines FOR ALL TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager'])) WITH CHECK (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager']));

DROP POLICY IF EXISTS "View garment outputs" ON public.garment_outputs;
DROP POLICY IF EXISTS "Manage garment outputs" ON public.garment_outputs;
CREATE POLICY "View garment outputs" ON public.garment_outputs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Accountant','Manager']));
CREATE POLICY "Manage garment outputs" ON public.garment_outputs FOR ALL TO authenticated USING (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager'])) WITH CHECK (has_any_role(ARRAY['Line Supervisor','Merchandiser','Manager']));
