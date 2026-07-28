-- =====================================================================
-- KAREYA SILO — STAFF COMMISSION (commission)
-- ---------------------------------------------------------------------
-- Paying staff a share of what they bring in. Nothing in Kareya did this,
-- yet half a dozen modules need it: a stylist on each appointment, an
-- agent on each policy, a broker on each closed deal, a mechanic on the
-- labour of a job, a rep on a sale. So this is one engine every module
-- writes into, not a feature bolted onto each.
--
-- ONE DISTINCTION MATTERS MORE THAN ANY OTHER, and it is easy to get
-- wrong in exactly the two modules that already say "commission":
--
--   insurance_policies.commission_pct and brokerage_listings.commission_pct
--   are what the BUSINESS earns from the insurer or the deal. They are
--   revenue. The staff member's commission is a share OF that, not of the
--   premium or the sale price.
--
-- So commission_entries.base_amount is whatever the caller decides the
-- commission is computed on, and it is stored on the entry. A salon passes
-- the service price; an insurance agency passes the commission it earned.
-- Storing the base means a payout can always be explained years later.
--
-- The rule that stops money leaking: uq_commission_entries_source. One
-- employee earns commission ONCE on a given source record. Without it a
-- re-saved invoice or a double-clicked "complete" button pays twice, and
-- nobody notices until payroll.
--
-- Ledger:
--   approved  DR Commission Expense (5150) / CR Commission Payable (2150)
--   paid      DR Commission Payable / CR Cash
-- Commission is earned when the work is done, not when it is paid, so the
-- expense lands in the month the sale happened.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.chart_of_accounts,
--             public.has_any_role(text[]), public.is_employee().
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- Who earns what, on what. A rule may target one employee, or a role, or
-- everyone; and one module, or all of them. The most specific match wins.
CREATE TABLE IF NOT EXISTS public.commission_rules (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  employee_id uuid,                              -- NULL = not employee-specific
  role text,                                     -- NULL = any role
  source_module text DEFAULT 'any'::text,        -- any | sales | insurance | brokerage | salon | workshop | retail | other
  basis text DEFAULT 'percent'::text,            -- percent (of base_amount) | flat (per record)
  rate numeric DEFAULT 0,                        -- a percentage, or a flat amount
  min_value numeric DEFAULT 0,                   -- tier floor, on base_amount
  max_value numeric,                             -- tier ceiling; NULL = no upper bound
  priority integer DEFAULT 0,                    -- breaks ties between equally specific rules
  effective_from date,
  effective_to date,
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT commission_rules_pkey PRIMARY KEY (id),
  CONSTRAINT commission_rules_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT commission_rules_rate_check CHECK (rate >= 0),
  CONSTRAINT commission_rules_basis_check CHECK (basis = ANY (ARRAY['percent','flat'])),
  CONSTRAINT commission_rules_band_check CHECK (min_value >= 0 AND (max_value IS NULL OR max_value > min_value)),
  CONSTRAINT commission_rules_dates_check CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from),
  -- A percentage over 100 is a typo every time, and one that pays out more
  -- than the sale was worth.
  CONSTRAINT commission_rules_percent_check CHECK (basis <> 'percent' OR rate <= 100)
);

-- One earning. rate/basis are snapshotted from the rule so changing a rule
-- later never restates what someone was already owed.
CREATE TABLE IF NOT EXISTS public.commission_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid NOT NULL,
  rule_id uuid,
  source_module text NOT NULL,
  source_id uuid,                                -- the appointment / policy / deal
  reference text,
  date date DEFAULT CURRENT_DATE,
  base_amount numeric DEFAULT 0,                 -- what the commission was computed on
  rate numeric DEFAULT 0,                        -- snapshot
  basis text DEFAULT 'percent'::text,            -- snapshot
  amount numeric DEFAULT 0,                      -- what is owed
  status text DEFAULT 'pending'::text,           -- pending | approved | paid | cancelled
  approved_at timestamp with time zone,
  paid_at timestamp with time zone,
  payout_id uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT commission_entries_pkey PRIMARY KEY (id),
  CONSTRAINT commission_entries_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT commission_entries_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES public.commission_rules(id) ON DELETE SET NULL,
  CONSTRAINT commission_entries_amounts_check CHECK (base_amount >= 0 AND rate >= 0 AND amount >= 0),
  CONSTRAINT commission_entries_basis_check CHECK (basis = ANY (ARRAY['percent','flat'])),
  CONSTRAINT commission_entries_status_check CHECK (status = ANY (ARRAY['pending','approved','paid','cancelled']))
);

-- A batch: everything approved for one person over a period, paid together.
CREATE TABLE IF NOT EXISTS public.commission_payouts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid NOT NULL,
  reference text,
  period_from date NOT NULL,
  period_to date NOT NULL,
  entry_count integer DEFAULT 0,
  amount numeric DEFAULT 0,
  status text DEFAULT 'draft'::text,             -- draft | paid
  paid_date date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT commission_payouts_pkey PRIMARY KEY (id),
  CONSTRAINT commission_payouts_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT commission_payouts_period_check CHECK (period_to >= period_from),
  CONSTRAINT commission_payouts_amounts_check CHECK (entry_count >= 0 AND amount >= 0),
  CONSTRAINT commission_payouts_status_check CHECK (status = ANY (ARRAY['draft','paid']))
);

DO $fk$ BEGIN
  ALTER TABLE public.commission_entries
    ADD CONSTRAINT commission_entries_payout_id_fkey
    FOREIGN KEY (payout_id) REFERENCES public.commission_payouts(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $fk$;

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_commission_rules_employee ON public.commission_rules (employee_id);
CREATE INDEX IF NOT EXISTS idx_commission_rules_module ON public.commission_rules (source_module);
CREATE INDEX IF NOT EXISTS idx_commission_rules_active ON public.commission_rules (is_active);

CREATE INDEX IF NOT EXISTS idx_commission_entries_employee ON public.commission_entries (employee_id);
CREATE INDEX IF NOT EXISTS idx_commission_entries_status ON public.commission_entries (status);
CREATE INDEX IF NOT EXISTS idx_commission_entries_date ON public.commission_entries (date);
CREATE INDEX IF NOT EXISTS idx_commission_entries_payout ON public.commission_entries (payout_id);
-- The guard: one employee earns commission ONCE on a given source record.
-- Cancelled entries are excluded so a mistake can be voided and redone.
CREATE UNIQUE INDEX IF NOT EXISTS uq_commission_entries_source
  ON public.commission_entries (employee_id, source_module, source_id)
  WHERE source_id IS NOT NULL AND status <> 'cancelled';

CREATE INDEX IF NOT EXISTS idx_commission_payouts_employee ON public.commission_payouts (employee_id);
CREATE INDEX IF NOT EXISTS idx_commission_payouts_status ON public.commission_payouts (status);

-- ---- chart of accounts --------------------------------------------------
-- seed_chart_of_accounts() returns early once any account exists, so a Silo
-- that installed its chart before this shipped would never get these two.
-- Guarded on the chart already being present: seeding orphan accounts into an
-- empty chart would make the seeder skip everything else.
INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '2150', 'Commission Payable', 'liability', 'payable', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '2150');

INSERT INTO public.chart_of_accounts (code, name, type, subtype, is_system)
SELECT '5150', 'Commission Expense', 'expense', 'payroll', false
WHERE EXISTS (SELECT 1 FROM public.chart_of_accounts)
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE code = '5150');

-- ---- row level security -------------------------------------------------
ALTER TABLE public.commission_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_payouts ENABLE ROW LEVEL SECURITY;

-- Rules and payouts are pay policy: HR, Accountant and management only.
-- Entries are readable by the same group, plus any employee may see their
-- OWN — people are entitled to check what they have earned.
DROP POLICY IF EXISTS "View commission rules" ON public.commission_rules;
DROP POLICY IF EXISTS "Manage commission rules" ON public.commission_rules;
CREATE POLICY "View commission rules" ON public.commission_rules FOR SELECT TO authenticated USING (has_any_role(ARRAY['HR','HR Manager','Accountant','Manager']));
CREATE POLICY "Manage commission rules" ON public.commission_rules FOR ALL TO authenticated USING (has_any_role(ARRAY['HR Manager','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['HR Manager','Accountant','Manager']));

DROP POLICY IF EXISTS "View commission entries" ON public.commission_entries;
DROP POLICY IF EXISTS "Manage commission entries" ON public.commission_entries;
CREATE POLICY "View commission entries" ON public.commission_entries FOR SELECT TO authenticated
  USING (
    has_any_role(ARRAY['HR','HR Manager','Accountant','Manager'])
    OR employee_id IN (
      SELECT e.id FROM public.employees e
      WHERE e.user_id = auth.uid() OR e.email = (auth.jwt() ->> 'email')
    )
  );
-- Writing an entry is what every module does when work completes, so any
-- employee may create one; only management can approve or pay.
CREATE POLICY "Manage commission entries" ON public.commission_entries FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

DROP POLICY IF EXISTS "View commission payouts" ON public.commission_payouts;
DROP POLICY IF EXISTS "Manage commission payouts" ON public.commission_payouts;
CREATE POLICY "View commission payouts" ON public.commission_payouts FOR SELECT TO authenticated
  USING (
    has_any_role(ARRAY['HR','HR Manager','Accountant','Manager'])
    OR employee_id IN (
      SELECT e.id FROM public.employees e
      WHERE e.user_id = auth.uid() OR e.email = (auth.jwt() ->> 'email')
    )
  );
CREATE POLICY "Manage commission payouts" ON public.commission_payouts FOR ALL TO authenticated USING (has_any_role(ARRAY['HR Manager','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['HR Manager','Accountant','Manager']));
