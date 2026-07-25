-- =====================================================================
-- KAREYA SILO — MANPOWER SERVICES
-- ---------------------------------------------------------------------
-- Security guards / cleaning staff placed at client sites.
--
--   manpower_sites        client posts we staff (bill rate, pay rate,
--                         headcount required per shift)
--   manpower_assignments  one employee, one site, one date, one shift.
--                         bill_rate / pay_rate are COPIED from the site at
--                         assignment time so later rate changes never
--                         rewrite billing history.
--   manpower_invoice_runs a period roll-up of WORKED shifts for one site,
--                         drafted before it becomes a client invoice.
--
-- One Silo == one business, so there is no company_id tenant key.
-- This file is IDEMPOTENT — safe to re-run on an existing Silo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.manpower_sites (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  client_name text,
  address text,
  bill_rate numeric DEFAULT 0,            -- charged to the client per shift
  pay_rate numeric DEFAULT 0,             -- paid to the worker per shift
  guards_required integer DEFAULT 0,      -- headcount needed per shift
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT manpower_sites_pkey PRIMARY KEY (id),
  CONSTRAINT manpower_sites_bill_rate_check CHECK (bill_rate >= 0),
  CONSTRAINT manpower_sites_pay_rate_check CHECK (pay_rate >= 0),
  CONSTRAINT manpower_sites_guards_required_check CHECK (guards_required >= 0)
);

CREATE TABLE IF NOT EXISTS public.manpower_assignments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  site_id uuid,
  employee_id uuid,
  date date NOT NULL DEFAULT CURRENT_DATE,
  shift text NOT NULL DEFAULT 'day'::text,        -- day | night
  status text NOT NULL DEFAULT 'scheduled'::text, -- scheduled | worked | absent | replaced
  bill_rate numeric DEFAULT 0,            -- snapshot of the site rate
  pay_rate numeric DEFAULT 0,             -- snapshot of the site rate
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT manpower_assignments_pkey PRIMARY KEY (id),
  CONSTRAINT manpower_assignments_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.manpower_sites(id) ON DELETE CASCADE,
  CONSTRAINT manpower_assignments_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT manpower_assignments_shift_check CHECK (shift = ANY (ARRAY['day','night'])),
  CONSTRAINT manpower_assignments_status_check CHECK (status = ANY (ARRAY['scheduled','worked','absent','replaced'])),
  CONSTRAINT manpower_assignments_bill_rate_check CHECK (bill_rate >= 0),
  CONSTRAINT manpower_assignments_pay_rate_check CHECK (pay_rate >= 0)
);

CREATE TABLE IF NOT EXISTS public.manpower_invoice_runs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  site_id uuid,
  period_from date NOT NULL,
  period_to date NOT NULL,
  shifts_billed integer DEFAULT 0,
  amount numeric DEFAULT 0,
  status text DEFAULT 'draft'::text,      -- draft | invoiced
  invoice_id uuid,                        -- set once raised as a client invoice
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT manpower_invoice_runs_pkey PRIMARY KEY (id),
  CONSTRAINT manpower_invoice_runs_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.manpower_sites(id) ON DELETE CASCADE,
  CONSTRAINT manpower_invoice_runs_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL,
  CONSTRAINT manpower_invoice_runs_status_check CHECK (status = ANY (ARRAY['draft','invoiced'])),
  CONSTRAINT manpower_invoice_runs_period_check CHECK (period_to >= period_from),
  CONSTRAINT manpower_invoice_runs_shifts_billed_check CHECK (shifts_billed >= 0),
  CONSTRAINT manpower_invoice_runs_amount_check CHECK (amount >= 0)
);

-- ---------------------------------------------------------------------
-- Indexes — the roster screen reads assignments by site + date.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_manpower_assignments_site_date ON public.manpower_assignments (site_id, date);
CREATE INDEX IF NOT EXISTS idx_manpower_assignments_date ON public.manpower_assignments (date);
CREATE INDEX IF NOT EXISTS idx_manpower_assignments_employee_id ON public.manpower_assignments (employee_id);
CREATE INDEX IF NOT EXISTS idx_manpower_invoice_runs_site_id ON public.manpower_invoice_runs (site_id);
CREATE INDEX IF NOT EXISTS idx_manpower_sites_is_active ON public.manpower_sites (is_active);

-- Defence in depth against double-booking one person on the same date+shift.
-- A 'replaced' row is history, so it never blocks the replacement.
CREATE UNIQUE INDEX IF NOT EXISTS uq_manpower_assignments_employee_date_shift
  ON public.manpower_assignments (employee_id, date, shift)
  WHERE employee_id IS NOT NULL AND status <> 'replaced';

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
-- Site Supervisors run the roster, Managers oversee, Accountants may read
-- (the billing runs post revenue to the ledger).
ALTER TABLE public.manpower_sites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manpower_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manpower_invoice_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View manpower sites" ON public.manpower_sites;
CREATE POLICY "View manpower sites" ON public.manpower_sites FOR SELECT TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage manpower sites" ON public.manpower_sites;
CREATE POLICY "Manage manpower sites" ON public.manpower_sites FOR ALL TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Manager'])) WITH CHECK (has_any_role(ARRAY['Site Supervisor','Manager']));

DROP POLICY IF EXISTS "View manpower assignments" ON public.manpower_assignments;
CREATE POLICY "View manpower assignments" ON public.manpower_assignments FOR SELECT TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage manpower assignments" ON public.manpower_assignments;
CREATE POLICY "Manage manpower assignments" ON public.manpower_assignments FOR ALL TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Manager'])) WITH CHECK (has_any_role(ARRAY['Site Supervisor','Manager']));

DROP POLICY IF EXISTS "View manpower invoice runs" ON public.manpower_invoice_runs;
CREATE POLICY "View manpower invoice runs" ON public.manpower_invoice_runs FOR SELECT TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Accountant','Manager']));
DROP POLICY IF EXISTS "Manage manpower invoice runs" ON public.manpower_invoice_runs;
CREATE POLICY "Manage manpower invoice runs" ON public.manpower_invoice_runs FOR ALL TO authenticated USING (has_any_role(ARRAY['Site Supervisor','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Site Supervisor','Accountant','Manager']));
