-- =====================================================================
-- KAREYA SILO — CUSTOMER DEPOSITS HELD (deposits)
-- ---------------------------------------------------------------------
-- A deposit is NOT income. It is the customer's money, sitting with you,
-- and you will hand most of it back. Booking it as revenue overstates
-- profit and hides a real debt.
--
-- Until now Kareya had nowhere to put one. Water Delivery carried a
-- deposit amount on each product and never posted it; Vehicle Rental
-- showed "deposits held" as a dashboard figure and never posted it;
-- Property took a lease deposit that went nowhere. Three modules, one
-- missing concept.
--
-- This is one register for all of them rather than a deposit column on
-- each module's table. That way "what are we holding, and for whom" is a
-- single question with a single answer, and the total reconciles to one
-- ledger account:
--
--   taking a deposit      DR Cash / CR Customer Deposits Held (2140)
--   refunding it          DR Customer Deposits Held / CR Cash
--   keeping it (damage,   DR Customer Deposits Held / CR Other Income
--   an unreturned bottle) — only at this point does it become yours
--
-- source_module / source_id point back at whatever the deposit was taken
-- against — a rental, a lease, a gas cylinder — without this table having
-- to know about any of them.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.chart_of_accounts, public.has_any_role(text[]).
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.customer_deposits (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  source_module text NOT NULL,                   -- vehiclerental | property | water | lpg | coworking | other
  source_id uuid,                                -- the rental / lease / issue it belongs to
  reference text,
  customer_name text NOT NULL,
  customer_ref text,                             -- phone, ID number, account
  amount numeric NOT NULL,                       -- what was taken
  refunded_amount numeric DEFAULT 0,
  forfeited_amount numeric DEFAULT 0,            -- kept: damage, loss, non-return
  status text DEFAULT 'held'::text,              -- held | settled
  taken_date date DEFAULT CURRENT_DATE,
  settled_date date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT customer_deposits_pkey PRIMARY KEY (id),
  CONSTRAINT customer_deposits_amount_check CHECK (amount > 0),
  CONSTRAINT customer_deposits_parts_check CHECK (refunded_amount >= 0 AND forfeited_amount >= 0),
  -- You cannot give back, or keep, more than the customer gave you. This is
  -- the whole point of the table, so the database enforces it.
  CONSTRAINT customer_deposits_total_check CHECK (refunded_amount + forfeited_amount <= amount),
  CONSTRAINT customer_deposits_status_check CHECK (status = ANY (ARRAY['held','settled'])),
  CONSTRAINT customer_deposits_module_check CHECK (source_module = ANY (ARRAY['vehiclerental','property','water','lpg','coworking','other']))
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_customer_deposits_status ON public.customer_deposits (status);
CREATE INDEX IF NOT EXISTS idx_customer_deposits_module ON public.customer_deposits (source_module);
CREATE INDEX IF NOT EXISTS idx_customer_deposits_source ON public.customer_deposits (source_id);
CREATE INDEX IF NOT EXISTS idx_customer_deposits_taken ON public.customer_deposits (taken_date);

-- ---- chart of accounts --------------------------------------------------
-- seed_chart_of_accounts() returns early once any account exists, so a Silo
-- that installed its chart before this shipped would never get 2140. Add it
-- here, but only when the chart is already there — seeding one orphan account
-- into an empty chart would make the seeder skip everything else.
INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '2140', 'Customer Deposits Held', 'liability', 'payable', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '2140');

-- ---- row level security -------------------------------------------------
ALTER TABLE public.customer_deposits ENABLE ROW LEVEL SECURITY;

-- Front-line staff take and return deposits, so Cashier and the counter roles
-- can manage them; the register itself is money, so it stays off limits to
-- everyone else.
DROP POLICY IF EXISTS "View customer deposits" ON public.customer_deposits;
DROP POLICY IF EXISTS "Manage customer deposits" ON public.customer_deposits;
CREATE POLICY "View customer deposits" ON public.customer_deposits FOR SELECT TO authenticated
  USING (has_any_role(ARRAY['Accountant','Manager','Cashier','Rental Agent','Property Manager','Water Agent']));
CREATE POLICY "Manage customer deposits" ON public.customer_deposits FOR ALL TO authenticated
  USING (has_any_role(ARRAY['Accountant','Manager','Cashier','Rental Agent','Property Manager','Water Agent']))
  WITH CHECK (has_any_role(ARRAY['Accountant','Manager','Cashier','Rental Agent','Property Manager','Water Agent']));
