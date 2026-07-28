-- =====================================================================
-- KAREYA SILO — VERTICAL: CO-WORKING & OFFICE HUB (coworking)
-- ---------------------------------------------------------------------
-- Deliberately thin. Most of a co-working space already exists in Kareya
-- and duplicating it would make the catalogue worse, not the product
-- better:
--   private offices and leases   -> Property (rental_units, leases)
--   monthly billing              -> Accounting (recurring_invoices)
--   deposits                     -> customer_deposits (account 2140)
--
-- So this file adds only what genuinely has no home:
--
--   cowork_plans        a membership tier, and the thing that makes
--                       co-working different from a gym membership:
--                       INCLUDED MEETING-ROOM HOURS. Hours come with the
--                       plan, reset each month, and anything beyond them
--                       is billed. Nothing else in Kareya models an
--                       allowance that resets and then overflows into a
--                       charge.
--   cowork_members      who is on which plan, and their desk if dedicated.
--   cowork_spaces       desks and meeting rooms as bookable resources.
--   cowork_bookings     meeting-room reservations, which cannot overlap.
--
-- Two rooms cannot be booked over each other — enforced by an exclusion
-- constraint, not by the screen, because two members booking from their
-- own laptops at the same moment is exactly when a screen check fails.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.clients, public.has_any_role(text[]),
--             public.is_employee().
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---- tables -------------------------------------------------------------

-- A membership tier. included_hours is per calendar month and does not roll
-- over — an allowance, not a balance.
CREATE TABLE IF NOT EXISTS public.cowork_plans (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  plan_type text DEFAULT 'hot_desk'::text,       -- hot_desk | dedicated_desk | private_office | virtual
  monthly_price numeric DEFAULT 0,
  day_pass_price numeric DEFAULT 0,
  included_hours numeric DEFAULT 0,              -- meeting-room hours per month
  overage_rate numeric DEFAULT 0,                -- charged per hour beyond that
  deposit numeric DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT cowork_plans_pkey PRIMARY KEY (id),
  CONSTRAINT cowork_plans_prices_check CHECK (monthly_price >= 0 AND day_pass_price >= 0 AND deposit >= 0),
  CONSTRAINT cowork_plans_hours_check CHECK (included_hours >= 0 AND overage_rate >= 0),
  CONSTRAINT cowork_plans_type_check CHECK (plan_type = ANY (ARRAY['hot_desk','dedicated_desk','private_office','virtual']))
);

-- A desk or a meeting room. Desks are assigned; rooms are booked.
CREATE TABLE IF NOT EXISTS public.cowork_spaces (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  space_type text DEFAULT 'desk'::text,          -- desk | meeting_room | office | phone_booth
  capacity integer DEFAULT 1,
  floor text,
  hourly_rate numeric DEFAULT 0,                 -- for non-members and overage
  is_bookable boolean DEFAULT true,
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT cowork_spaces_pkey PRIMARY KEY (id),
  CONSTRAINT cowork_spaces_capacity_check CHECK (capacity >= 0),
  CONSTRAINT cowork_spaces_rate_check CHECK (hourly_rate >= 0),
  CONSTRAINT cowork_spaces_type_check CHECK (space_type = ANY (ARRAY['desk','meeting_room','office','phone_booth']))
);

CREATE TABLE IF NOT EXISTS public.cowork_members (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  member_no text,
  name text NOT NULL,
  company_name text,
  client_id uuid,                                -- if they are also a billed client
  email text,
  phone text,
  plan_id uuid,
  desk_space_id uuid,                            -- set for a dedicated desk
  start_date date DEFAULT CURRENT_DATE,
  end_date date,
  status text DEFAULT 'active'::text,            -- active | paused | ended
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT cowork_members_pkey PRIMARY KEY (id),
  CONSTRAINT cowork_members_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT cowork_members_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.cowork_plans(id) ON DELETE SET NULL,
  CONSTRAINT cowork_members_desk_fkey FOREIGN KEY (desk_space_id) REFERENCES public.cowork_spaces(id) ON DELETE SET NULL,
  CONSTRAINT cowork_members_period_check CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT cowork_members_status_check CHECK (status = ANY (ARRAY['active','paused','ended']))
);

-- A meeting-room reservation. included_hours / billable_hours are frozen at
-- booking from the member's remaining allowance, so a later plan change never
-- restates what a past booking cost.
CREATE TABLE IF NOT EXISTS public.cowork_bookings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  space_id uuid NOT NULL,
  member_id uuid,
  guest_name text,                               -- non-member booking
  purpose text,
  start_time timestamp with time zone NOT NULL,
  end_time timestamp with time zone NOT NULL,
  hours numeric DEFAULT 0,
  included_hours numeric DEFAULT 0,              -- drawn from the plan allowance
  billable_hours numeric DEFAULT 0,              -- the overage
  hourly_rate numeric DEFAULT 0,                 -- snapshot
  charge numeric DEFAULT 0,                      -- billable_hours * hourly_rate
  status text DEFAULT 'booked'::text,            -- booked | in_use | completed | cancelled
  invoiced boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT cowork_bookings_pkey PRIMARY KEY (id),
  CONSTRAINT cowork_bookings_space_id_fkey FOREIGN KEY (space_id) REFERENCES public.cowork_spaces(id) ON DELETE CASCADE,
  CONSTRAINT cowork_bookings_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.cowork_members(id) ON DELETE SET NULL,
  CONSTRAINT cowork_bookings_period_check CHECK (end_time > start_time),
  CONSTRAINT cowork_bookings_hours_check CHECK (hours >= 0 AND included_hours >= 0 AND billable_hours >= 0),
  CONSTRAINT cowork_bookings_amounts_check CHECK (hourly_rate >= 0 AND charge >= 0),
  -- The split must add up: every hour is either covered by the plan or billed.
  CONSTRAINT cowork_bookings_split_check CHECK (included_hours + billable_hours <= hours + 0.001),
  CONSTRAINT cowork_bookings_status_check CHECK (status = ANY (ARRAY['booked','in_use','completed','cancelled']))
);

-- One room, one booking at a time.
DO $ex$ BEGIN
  ALTER TABLE public.cowork_bookings
    ADD CONSTRAINT cowork_bookings_no_overlap
    EXCLUDE USING gist (
      space_id WITH =,
      tstzrange(start_time, end_time) WITH &&
    ) WHERE (status <> 'cancelled');
EXCEPTION WHEN duplicate_table THEN NULL; WHEN duplicate_object THEN NULL; END $ex$;

-- A dedicated desk belongs to one member at a time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cowork_members_desk
  ON public.cowork_members (desk_space_id)
  WHERE desk_space_id IS NOT NULL AND status = 'active';

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cowork_members_status ON public.cowork_members (status);
CREATE INDEX IF NOT EXISTS idx_cowork_members_plan ON public.cowork_members (plan_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_cowork_members_no ON public.cowork_members (member_no) WHERE member_no IS NOT NULL AND member_no <> '';
CREATE INDEX IF NOT EXISTS idx_cowork_spaces_type ON public.cowork_spaces (space_type);
CREATE INDEX IF NOT EXISTS idx_cowork_bookings_space ON public.cowork_bookings (space_id);
CREATE INDEX IF NOT EXISTS idx_cowork_bookings_member ON public.cowork_bookings (member_id);
CREATE INDEX IF NOT EXISTS idx_cowork_bookings_start ON public.cowork_bookings (start_time);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.cowork_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cowork_spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cowork_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cowork_bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View cowork plans" ON public.cowork_plans;
DROP POLICY IF EXISTS "Manage cowork plans" ON public.cowork_plans;
CREATE POLICY "View cowork plans" ON public.cowork_plans FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage cowork plans" ON public.cowork_plans FOR ALL TO authenticated USING (has_any_role(ARRAY['Community Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['Community Manager','Manager']));

DROP POLICY IF EXISTS "View cowork spaces" ON public.cowork_spaces;
DROP POLICY IF EXISTS "Manage cowork spaces" ON public.cowork_spaces;
CREATE POLICY "View cowork spaces" ON public.cowork_spaces FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage cowork spaces" ON public.cowork_spaces FOR ALL TO authenticated USING (has_any_role(ARRAY['Community Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['Community Manager','Manager']));

DROP POLICY IF EXISTS "View cowork members" ON public.cowork_members;
DROP POLICY IF EXISTS "Manage cowork members" ON public.cowork_members;
CREATE POLICY "View cowork members" ON public.cowork_members FOR SELECT TO authenticated USING (has_any_role(ARRAY['Community Manager','Reception','Cashier','Accountant','Manager']));
CREATE POLICY "Manage cowork members" ON public.cowork_members FOR ALL TO authenticated USING (has_any_role(ARRAY['Community Manager','Reception','Manager'])) WITH CHECK (has_any_role(ARRAY['Community Manager','Reception','Manager']));

DROP POLICY IF EXISTS "View cowork bookings" ON public.cowork_bookings;
DROP POLICY IF EXISTS "Manage cowork bookings" ON public.cowork_bookings;
CREATE POLICY "View cowork bookings" ON public.cowork_bookings FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage cowork bookings" ON public.cowork_bookings FOR ALL TO authenticated USING (has_any_role(ARRAY['Community Manager','Reception','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Community Manager','Reception','Cashier','Manager']));
