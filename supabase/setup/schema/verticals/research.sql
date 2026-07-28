-- =====================================================================
-- KAREYA SILO — RESEARCH INSTITUTE add-on (research)
-- ---------------------------------------------------------------------
-- Grants/RMS already carries the money side of a research centre: grants
-- with a principal investigator, funders, budget lines, milestones,
-- disbursements and an indirect-cost rate. This file adds only the three
-- things that were genuinely missing, so it extends Grants rather than
-- standing up a duplicate vertical.
--
--   research_outputs    what the money produced — papers, datasets,
--                       reports — linked to the grant that funded them.
--                       Funders ask for exactly this at reporting time and
--                       there was nowhere to keep it.
--   ethics_approvals    a protocol with an approval that EXPIRES. The
--                       expiry is the point: approved-then-lapsed is the
--                       state that gets institutions into trouble, so it
--                       is a date the system can check rather than a note
--                       in a drawer.
--   research_equipment  shared instruments booked by time slot, with an
--                       optional charge rate so machine time can be
--                       recovered against a grant.
--   equipment_bookings  the reservations themselves.
--
-- Two bookings of one instrument cannot overlap. That is enforced by an
-- exclusion constraint, not by the app: the UI cannot make that promise
-- once two researchers book from different laptops at the same moment.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.grants, public.assets,
--             public.lab_instruments, public.has_any_role(text[]),
--             public.is_employee().
-- =====================================================================

-- Needed for the exclusion constraint below: lets a plain equality column
-- (equipment_id) share a GiST index with a range. Ships with Supabase.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---- tables -------------------------------------------------------------

-- A research output. status tracks the publication pipeline, because a
-- paper under review is a reportable commitment, not nothing.
CREATE TABLE IF NOT EXISTS public.research_outputs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  output_type text DEFAULT 'journal_article'::text,
  authors text,
  venue text,                                    -- journal, conference, publisher
  publication_date date,
  doi text,
  url text,
  grant_id uuid,
  lead_id uuid,                                  -- lead author on staff
  status text DEFAULT 'planned'::text,
  citation_count integer DEFAULT 0,
  open_access boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT research_outputs_pkey PRIMARY KEY (id),
  CONSTRAINT research_outputs_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE SET NULL,
  CONSTRAINT research_outputs_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT research_outputs_citation_check CHECK (citation_count >= 0),
  CONSTRAINT research_outputs_type_check CHECK (output_type = ANY (ARRAY['journal_article','conference','book','chapter','dataset','report','thesis','patent','software','other'])),
  CONSTRAINT research_outputs_status_check CHECK (status = ANY (ARRAY['planned','submitted','under_review','accepted','published','rejected']))
);

-- An ethics / IRB protocol. Dates run submitted -> approved -> expires, and
-- each is checked against the one before it so the record cannot describe
-- an impossible sequence.
CREATE TABLE IF NOT EXISTS public.ethics_approvals (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  protocol_no text,
  title text NOT NULL,
  committee text,                                -- the reviewing body
  grant_id uuid,
  pi_id uuid,
  submitted_date date,
  approved_date date,
  expires_date date,
  status text DEFAULT 'draft'::text,
  conditions text,                               -- conditions of approval
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ethics_approvals_pkey PRIMARY KEY (id),
  CONSTRAINT ethics_approvals_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE SET NULL,
  CONSTRAINT ethics_approvals_pi_id_fkey FOREIGN KEY (pi_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT ethics_approvals_status_check CHECK (status = ANY (ARRAY['draft','submitted','approved','rejected','expired','withdrawn'])),
  CONSTRAINT ethics_approvals_approved_check CHECK (approved_date IS NULL OR submitted_date IS NULL OR approved_date >= submitted_date),
  CONSTRAINT ethics_approvals_expiry_check CHECK (expires_date IS NULL OR approved_date IS NULL OR expires_date >= approved_date)
);

-- A bookable shared resource. It may point at an existing fixed asset or a
-- lab instrument, so the equipment register is not re-typed; both links are
-- optional because plenty of shared kit is neither.
CREATE TABLE IF NOT EXISTS public.research_equipment (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  code text,
  location text,
  asset_id uuid,
  lab_instrument_id uuid,
  charge_rate numeric DEFAULT 0,                 -- 0 = free to use
  charge_unit text DEFAULT 'hour'::text,         -- hour | day
  requires_approval boolean DEFAULT false,
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT research_equipment_pkey PRIMARY KEY (id),
  CONSTRAINT research_equipment_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE SET NULL,
  CONSTRAINT research_equipment_lab_instrument_id_fkey FOREIGN KEY (lab_instrument_id) REFERENCES public.lab_instruments(id) ON DELETE SET NULL,
  CONSTRAINT research_equipment_charge_rate_check CHECK (charge_rate >= 0),
  CONSTRAINT research_equipment_charge_unit_check CHECK (charge_unit = ANY (ARRAY['hour','day']))
);

-- A reservation. charge is frozen at booking from the rate then in force,
-- so re-pricing the instrument later never restates a grant's costs.
CREATE TABLE IF NOT EXISTS public.equipment_bookings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  equipment_id uuid NOT NULL,
  booked_by uuid,
  grant_id uuid,                                 -- who the machine time is charged to
  purpose text,
  start_time timestamp with time zone NOT NULL,
  end_time timestamp with time zone NOT NULL,
  status text DEFAULT 'booked'::text,
  charge_rate numeric DEFAULT 0,                 -- snapshot of the rate at booking
  charge numeric DEFAULT 0,
  charged boolean DEFAULT false,                 -- recovered against the grant
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT equipment_bookings_pkey PRIMARY KEY (id),
  CONSTRAINT equipment_bookings_equipment_id_fkey FOREIGN KEY (equipment_id) REFERENCES public.research_equipment(id) ON DELETE CASCADE,
  CONSTRAINT equipment_bookings_booked_by_fkey FOREIGN KEY (booked_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT equipment_bookings_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE SET NULL,
  CONSTRAINT equipment_bookings_period_check CHECK (end_time > start_time),
  CONSTRAINT equipment_bookings_charge_check CHECK (charge >= 0 AND charge_rate >= 0),
  CONSTRAINT equipment_bookings_status_check CHECK (status = ANY (ARRAY['booked','in_use','completed','cancelled']))
);

-- One instrument cannot be in two places at once. Enforced here rather than
-- in the app because the UI cannot promise it once two researchers book from
-- different machines in the same moment. Cancelled bookings are excluded so
-- a released slot frees up immediately.
DO $ex$ BEGIN
  ALTER TABLE public.equipment_bookings
    ADD CONSTRAINT equipment_bookings_no_overlap
    EXCLUDE USING gist (
      equipment_id WITH =,
      tstzrange(start_time, end_time) WITH &&
    ) WHERE (status <> 'cancelled');
EXCEPTION WHEN duplicate_table THEN NULL; WHEN duplicate_object THEN NULL; END $ex$;

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_research_outputs_grant_id ON public.research_outputs (grant_id);
CREATE INDEX IF NOT EXISTS idx_research_outputs_status ON public.research_outputs (status);
CREATE INDEX IF NOT EXISTS idx_research_outputs_pub_date ON public.research_outputs (publication_date);
CREATE UNIQUE INDEX IF NOT EXISTS uq_research_outputs_doi ON public.research_outputs (doi) WHERE doi IS NOT NULL AND doi <> '';

CREATE INDEX IF NOT EXISTS idx_ethics_approvals_grant_id ON public.ethics_approvals (grant_id);
CREATE INDEX IF NOT EXISTS idx_ethics_approvals_status ON public.ethics_approvals (status);
CREATE INDEX IF NOT EXISTS idx_ethics_approvals_expires ON public.ethics_approvals (expires_date);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ethics_approvals_protocol ON public.ethics_approvals (protocol_no) WHERE protocol_no IS NOT NULL AND protocol_no <> '';

CREATE INDEX IF NOT EXISTS idx_research_equipment_active ON public.research_equipment (is_active);
CREATE INDEX IF NOT EXISTS idx_equipment_bookings_equipment ON public.equipment_bookings (equipment_id);
CREATE INDEX IF NOT EXISTS idx_equipment_bookings_grant_id ON public.equipment_bookings (grant_id);
CREATE INDEX IF NOT EXISTS idx_equipment_bookings_start ON public.equipment_bookings (start_time);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.research_outputs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ethics_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.research_equipment ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment_bookings ENABLE ROW LEVEL SECURITY;

-- Outputs and the equipment register are readable by any employee — a
-- researcher needs to see the publication list and what is bookable.
-- Ethics protocols are narrower: they carry the terms research runs under.
DROP POLICY IF EXISTS "View research outputs" ON public.research_outputs;
DROP POLICY IF EXISTS "Manage research outputs" ON public.research_outputs;
CREATE POLICY "View research outputs" ON public.research_outputs FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage research outputs" ON public.research_outputs FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Manager']));

DROP POLICY IF EXISTS "View ethics approvals" ON public.ethics_approvals;
DROP POLICY IF EXISTS "Manage ethics approvals" ON public.ethics_approvals;
CREATE POLICY "View ethics approvals" ON public.ethics_approvals FOR SELECT TO authenticated USING (has_any_role(ARRAY['Grants','Lab','Accountant','Manager']));
CREATE POLICY "Manage ethics approvals" ON public.ethics_approvals FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Manager']));

DROP POLICY IF EXISTS "View research equipment" ON public.research_equipment;
DROP POLICY IF EXISTS "Manage research equipment" ON public.research_equipment;
CREATE POLICY "View research equipment" ON public.research_equipment FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage research equipment" ON public.research_equipment FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Lab','Manager']));

-- Any employee may book shared kit; that is the point of a shared register.
DROP POLICY IF EXISTS "View equipment bookings" ON public.equipment_bookings;
DROP POLICY IF EXISTS "Manage equipment bookings" ON public.equipment_bookings;
CREATE POLICY "View equipment bookings" ON public.equipment_bookings FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage equipment bookings" ON public.equipment_bookings FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());
