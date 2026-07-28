-- =====================================================================
-- KAREYA SILO — CONSIGNMENT STOCK + PUBLICATION METADATA (consignment)
-- ---------------------------------------------------------------------
-- Consigned goods sit in your shop but belong to someone else. You pay
-- only for what sells and send the rest back. That is an ACCOUNTING
-- difference, not a screen difference, and getting it wrong overstates
-- your assets:
--
--   receiving consigned stock   NO ledger entry. You hold the goods but
--                               own nothing, so nothing is capitalised
--                               into Inventory (1200) and no payable
--                               arises yet.
--   selling consigned stock     DR Cost of Goods Sold / CR Consignment
--                               Payable (2130). The cost hits the P&L and
--                               the debt to the owner appears — without
--                               ever having booked an asset you did not own.
--   settling with the consignor DR Consignment Payable / CR Cash.
--   returning unsold stock      NO ledger entry. Quantity falls; you never
--                               owed anything for it.
--
-- This is deliberately general rather than bookshop-specific: consignment
-- is how phone accessories, cosmetics and pharmacy stock commonly move in
-- Cambodia. The publication columns (isbn / author / publisher) ride along
-- because a bookshop is otherwise just Retail — ISBN is an EAN-13 and the
-- existing barcode field already scans it.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.stock_items, public.retail_products, public.vendors,
--             public.chart_of_accounts, public.has_any_role(text[]).
-- =====================================================================

-- ---- columns on the existing catalogs ----------------------------------
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS is_consigned boolean DEFAULT false;
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS consignor_vendor_id uuid;
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS isbn text;
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS author text;
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS publisher text;

ALTER TABLE public.retail_products ADD COLUMN IF NOT EXISTS is_consigned boolean DEFAULT false;
ALTER TABLE public.retail_products ADD COLUMN IF NOT EXISTS consignor_vendor_id uuid;
ALTER TABLE public.retail_products ADD COLUMN IF NOT EXISTS isbn text;
ALTER TABLE public.retail_products ADD COLUMN IF NOT EXISTS author text;
ALTER TABLE public.retail_products ADD COLUMN IF NOT EXISTS publisher text;

DO $fk$ BEGIN
  ALTER TABLE public.stock_items
    ADD CONSTRAINT stock_items_consignor_fkey
    FOREIGN KEY (consignor_vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $fk$;

DO $fk$ BEGIN
  ALTER TABLE public.retail_products
    ADD CONSTRAINT retail_products_consignor_fkey
    FOREIGN KEY (consignor_vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $fk$;

-- ---- settlement --------------------------------------------------------
-- What sold in a period and what the consignor is therefore owed. Kept as
-- a document rather than derived on the fly so the figure agreed with the
-- publisher survives later edits to cost prices.
CREATE TABLE IF NOT EXISTS public.consignment_settlements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  vendor_id uuid NOT NULL,
  reference text,
  period_from date NOT NULL,
  period_to date NOT NULL,
  qty_sold numeric DEFAULT 0,
  amount numeric DEFAULT 0,                      -- what we owe the consignor
  status text DEFAULT 'draft'::text,             -- draft | settled
  settled_date date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT consignment_settlements_pkey PRIMARY KEY (id),
  CONSTRAINT consignment_settlements_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE CASCADE,
  CONSTRAINT consignment_settlements_period_check CHECK (period_to >= period_from),
  CONSTRAINT consignment_settlements_qty_check CHECK (qty_sold >= 0),
  CONSTRAINT consignment_settlements_amount_check CHECK (amount >= 0),
  CONSTRAINT consignment_settlements_status_check CHECK (status = ANY (ARRAY['draft','settled']))
);

CREATE TABLE IF NOT EXISTS public.consignment_settlement_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  settlement_id uuid NOT NULL,
  stock_item_id uuid,
  description text,
  quantity numeric DEFAULT 0,
  unit_cost numeric DEFAULT 0,                   -- what the consignor is paid per unit
  line_total numeric DEFAULT 0,
  CONSTRAINT consignment_settlement_items_pkey PRIMARY KEY (id),
  CONSTRAINT consignment_settlement_items_settlement_id_fkey FOREIGN KEY (settlement_id) REFERENCES public.consignment_settlements(id) ON DELETE CASCADE,
  CONSTRAINT consignment_settlement_items_stock_item_id_fkey FOREIGN KEY (stock_item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL,
  CONSTRAINT consignment_settlement_items_quantity_check CHECK (quantity >= 0),
  CONSTRAINT consignment_settlement_items_unit_cost_check CHECK (unit_cost >= 0),
  CONSTRAINT consignment_settlement_items_line_total_check CHECK (line_total >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_stock_items_consigned ON public.stock_items (is_consigned) WHERE is_consigned = true;
CREATE INDEX IF NOT EXISTS idx_stock_items_consignor ON public.stock_items (consignor_vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_items_isbn ON public.stock_items (isbn) WHERE isbn IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_retail_products_consigned ON public.retail_products (is_consigned) WHERE is_consigned = true;
CREATE INDEX IF NOT EXISTS idx_retail_products_consignor ON public.retail_products (consignor_vendor_id);
CREATE INDEX IF NOT EXISTS idx_consignment_settlements_vendor ON public.consignment_settlements (vendor_id);
CREATE INDEX IF NOT EXISTS idx_consignment_settlements_status ON public.consignment_settlements (status);
CREATE INDEX IF NOT EXISTS idx_consignment_settlement_items_settlement ON public.consignment_settlement_items (settlement_id);

-- ---- chart of accounts --------------------------------------------------
-- seed_chart_of_accounts() returns early when any account already exists, so
-- a Silo that installed its chart before this file shipped would never see
-- account 2130. Add it here directly, and only when the chart is present —
-- installing one orphan account into an empty chart would make the seeder
-- skip everything else.
INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '2130', 'Consignment Payable', 'liability', 'payable', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '2130');

-- ---- row level security -------------------------------------------------
ALTER TABLE public.consignment_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consignment_settlement_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View consignment settlements" ON public.consignment_settlements;
DROP POLICY IF EXISTS "Manage consignment settlements" ON public.consignment_settlements;
CREATE POLICY "View consignment settlements" ON public.consignment_settlements FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager','Cashier']));
CREATE POLICY "Manage consignment settlements" ON public.consignment_settlements FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View consignment settlement items" ON public.consignment_settlement_items;
DROP POLICY IF EXISTS "Manage consignment settlement items" ON public.consignment_settlement_items;
CREATE POLICY "View consignment settlement items" ON public.consignment_settlement_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Manager','Cashier']));
CREATE POLICY "Manage consignment settlement items" ON public.consignment_settlement_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
