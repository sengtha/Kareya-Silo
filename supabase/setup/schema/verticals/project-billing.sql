-- =====================================================================
-- PROJECT BILLING — turn tracked time into money.
-- ---------------------------------------------------------------------
-- Projects already tracked billable hours and a rate, but the value was
-- display-only: nothing converted it into an invoice. This closes that
-- loop for consultants, agencies, IT shops, architects and accountants.
--
--   time_entries.invoiced / invoice_id  stamped when hours are billed, so
--                                       the same hours can never be billed
--                                       twice.
--   project_retainers                   money paid UP FRONT against future
--                                       work. Drawn down as hours are
--                                       billed; not revenue until consumed.
-- Idempotent.
-- =====================================================================

ALTER TABLE public.time_entries ADD COLUMN IF NOT EXISTS invoiced boolean NOT NULL DEFAULT false;
ALTER TABLE public.time_entries ADD COLUMN IF NOT EXISTS invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL;

-- Only unbilled billable hours are ever offered for billing, so index that.
CREATE INDEX IF NOT EXISTS idx_time_entries_unbilled
  ON public.time_entries (project_id) WHERE billable = true AND invoiced = false;

CREATE TABLE IF NOT EXISTS public.project_retainers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  project_id uuid REFERENCES public.projects(id) ON DELETE CASCADE,
  client_id uuid REFERENCES public.clients(id) ON DELETE SET NULL,
  date date DEFAULT CURRENT_DATE NOT NULL,
  amount numeric NOT NULL,
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT project_retainers_pkey PRIMARY KEY (id),
  CONSTRAINT project_retainers_amount_positive CHECK (amount > 0)
);
CREATE INDEX IF NOT EXISTS idx_project_retainers_project ON public.project_retainers (project_id);

ALTER TABLE public.project_retainers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "View project retainers" ON public.project_retainers;
CREATE POLICY "View project retainers" ON public.project_retainers
  FOR SELECT TO authenticated USING (is_employee());
DROP POLICY IF EXISTS "Manage project retainers" ON public.project_retainers;
CREATE POLICY "Manage project retainers" ON public.project_retainers
  FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']))
  WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
