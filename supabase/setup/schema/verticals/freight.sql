-- =====================================================================
-- KAREYA SILO — VERTICAL: FREIGHT FORWARDING / CUSTOMS BROKERAGE
-- ---------------------------------------------------------------------
-- A freight job is one consignment moved for a client, import or export,
-- by sea / air / land. It carries the transport paperwork (BL or AWB,
-- container no., incoterm, customs reference) and moves through a fixed
-- pipeline: quote -> booked -> in_transit -> customs -> delivered ->
-- closed (or cancelled at any point).
--
-- ACCOUNTING NOTE — the one distinction that matters here:
--   A charge line is either REVENUE (the forwarder's own fee: freight,
--   handling, clearance fee, documentation) or a DISBURSEMENT — duties,
--   taxes, port and terminal fees PAID ON THE CLIENT'S BEHALF and merely
--   recharged at cost. Disbursements are pass-through cash, NOT income,
--   and must never be posted to a revenue account. `is_disbursement`
--   carries that flag; `charges_total` on the job is the gross billed to
--   the client (revenue + disbursements).
--
-- Idempotent: safe to run repeatedly. Apply AFTER kareya_silo_schema.sql
-- (references public.employees) and alongside RLS.sql.
-- =====================================================================

-- ---- jobs --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.freight_jobs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  job_no text,                                 -- human-facing job / file no.
  client_name text NOT NULL,
  direction text DEFAULT 'import'::text,       -- import | export
  mode text DEFAULT 'sea'::text,               -- sea | air | land
  origin_port text,                            -- port / airport of loading
  destination_port text,                       -- port / airport of discharge
  container_no text,                           -- e.g. MSKU1234567 (sea FCL)
  bl_awb_no text,                              -- Bill of Lading / Air Waybill
  incoterm text,                               -- EXW | FOB | CIF | DDP | ...
  customs_ref text,                            -- customs declaration reference
  etd date,                                    -- estimated time of departure
  eta date,                                    -- estimated time of arrival
  status text DEFAULT 'quote'::text,           -- quote | booked | in_transit | customs | delivered | closed | cancelled
  charges_total numeric DEFAULT 0,             -- gross billed = revenue + disbursements
  officer_id uuid,                             -- freight officer / broker owning the file
  notes text,
  closed_at timestamp with time zone,   -- stamped on close; revenue is reported in this month
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_jobs_pkey PRIMARY KEY (id),
  CONSTRAINT freight_jobs_officer_id_fkey FOREIGN KEY (officer_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT freight_jobs_direction_check CHECK (direction = ANY (ARRAY['import','export'])),
  CONSTRAINT freight_jobs_mode_check CHECK (mode = ANY (ARRAY['sea','air','land'])),
  CONSTRAINT freight_jobs_status_check CHECK (status = ANY (ARRAY['quote','booked','in_transit','customs','delivered','closed','cancelled']))
);

-- ---- cargo lines -------------------------------------------------------
-- One row per commodity on the declaration. hs_code is the harmonised
-- tariff code customs assesses duty against; declared_value is the customs
-- value of that line (NOT what the client is billed — that lives in charges).
CREATE TABLE IF NOT EXISTS public.freight_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  job_id uuid NOT NULL,
  description text NOT NULL,
  hs_code text,                                -- harmonised system tariff code
  quantity numeric DEFAULT 0,
  weight_kg numeric DEFAULT 0,
  declared_value numeric DEFAULT 0,            -- customs value of the line
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_items_pkey PRIMARY KEY (id),
  CONSTRAINT freight_items_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.freight_jobs(id) ON DELETE CASCADE
);

-- ---- charge lines ------------------------------------------------------
-- is_disbursement = false -> the forwarder's own fee, real REVENUE.
-- is_disbursement = true  -> duty/tax/port fee fronted for the client,
--                            recharged at cost. Pass-through, never income.
CREATE TABLE IF NOT EXISTS public.freight_charges (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  job_id uuid NOT NULL,
  description text NOT NULL,
  amount numeric DEFAULT 0,
  is_disbursement boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT freight_charges_pkey PRIMARY KEY (id),
  CONSTRAINT freight_charges_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.freight_jobs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_freight_jobs_status ON public.freight_jobs (status);
CREATE INDEX IF NOT EXISTS idx_freight_jobs_officer_id ON public.freight_jobs (officer_id);
CREATE INDEX IF NOT EXISTS idx_freight_jobs_eta ON public.freight_jobs (eta);
CREATE INDEX IF NOT EXISTS idx_freight_items_job_id ON public.freight_items (job_id);
CREATE INDEX IF NOT EXISTS idx_freight_charges_job_id ON public.freight_charges (job_id);
CREATE INDEX IF NOT EXISTS idx_freight_charges_is_disbursement ON public.freight_charges (is_disbursement);

-- =====================================================================
-- ROW LEVEL SECURITY
-- Freight Officers run the files, Customs Brokers clear them, Accountants
-- need read + charge access to bill and to keep disbursements out of
-- revenue, Managers oversee.
-- =====================================================================
ALTER TABLE public.freight_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freight_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.freight_charges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View freight jobs" ON public.freight_jobs;
DROP POLICY IF EXISTS "Manage freight jobs" ON public.freight_jobs;
DROP POLICY IF EXISTS "View freight items" ON public.freight_items;
DROP POLICY IF EXISTS "Manage freight items" ON public.freight_items;
DROP POLICY IF EXISTS "View freight charges" ON public.freight_charges;
DROP POLICY IF EXISTS "Manage freight charges" ON public.freight_charges;

CREATE POLICY "View freight jobs" ON public.freight_jobs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));
CREATE POLICY "Manage freight jobs" ON public.freight_jobs FOR ALL TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));

CREATE POLICY "View freight items" ON public.freight_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));
CREATE POLICY "Manage freight items" ON public.freight_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));

CREATE POLICY "View freight charges" ON public.freight_charges FOR SELECT TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));
CREATE POLICY "Manage freight charges" ON public.freight_charges FOR ALL TO authenticated USING (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Freight Officer','Customs Broker','Accountant','Manager']));
