-- =====================================================================
-- KAREYA SILO — VERTICAL: LIBRARY (library)
-- ---------------------------------------------------------------------
-- Circulation, not inventory. The distinction drives the whole design:
-- Inventory models fungible quantity ("5 in stock"); a library models five
-- INDIVIDUALLY TRACKED copies, each with its own accession number and its
-- own state — on loan to a named borrower, due on a date, on the hold
-- shelf for someone else, or lost. Stock leaves and is gone; a loaned
-- copy is expected back, and the date it is expected governs everything.
--
-- Two levels, deliberately:
--   library_items   the bibliographic record (one row per title/edition)
--   library_copies  the physical objects on the shelf (many per item)
-- A borrower reserves a TITLE (any copy will do) but borrows a COPY.
--
-- Borrowers are not a new identity model. library_members points at the
-- existing students and employees tables, so a school already running
-- Academy does not re-enter its people; walk-in public members are rows
-- with neither link set.
--
-- Two integrity rules are enforced by the database rather than the app,
-- because both are the kind of bug that is invisible until it is
-- expensive:
--   * a copy can be on exactly one active loan (uq_library_loans_active_copy)
--   * a member can hold exactly one active reservation per title
--     (uq_library_holds_active)
--
-- Fines accrue per day past due at the policy rate and are collected in
-- the app, which posts them to the ledger as service revenue.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.students, public.has_any_role(text[]).
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- The bibliographic record: one row per title/edition, however many copies
-- sit on the shelf. call_number is the shelf classification (Dewey or the
-- library's own scheme); language matters in Cambodia, where collections
-- routinely run Khmer and English side by side.
CREATE TABLE IF NOT EXISTS public.library_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  authors text,
  isbn text,
  publisher text,
  published_year integer,
  edition text,
  language text DEFAULT 'en'::text,              -- en | km | fr | zh | other
  call_number text,                              -- Dewey or local scheme
  category text,                                 -- Reference | Fiction | Textbook | ...
  subject text,
  summary text,
  cover_url text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_items_pkey PRIMARY KEY (id),
  CONSTRAINT library_items_year_check CHECK (published_year IS NULL OR (published_year >= 1000 AND published_year <= 2200))
);

-- A physical copy. accession_no is the number written inside the cover —
-- the library's permanent identifier for this object.
CREATE TABLE IF NOT EXISTS public.library_copies (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid NOT NULL,
  accession_no text,
  barcode text,
  shelf text,                                    -- physical location
  condition text DEFAULT 'good'::text,           -- good | fair | poor
  status text DEFAULT 'available'::text,         -- available | on_loan | on_hold_shelf | repair | lost | withdrawn
  acquired_date date DEFAULT CURRENT_DATE,
  cost numeric DEFAULT 0,                        -- replacement value, charged if lost
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_copies_pkey PRIMARY KEY (id),
  CONSTRAINT library_copies_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.library_items(id) ON DELETE CASCADE,
  CONSTRAINT library_copies_cost_check CHECK (cost >= 0),
  CONSTRAINT library_copies_condition_check CHECK (condition = ANY (ARRAY['good','fair','poor'])),
  CONSTRAINT library_copies_status_check CHECK (status = ANY (ARRAY['available','on_loan','on_hold_shelf','repair','lost','withdrawn']))
);

-- A borrower. student_id / employee_id link to people the Silo already
-- knows; a public member has neither set and stands on its own.
CREATE TABLE IF NOT EXISTS public.library_members (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  member_no text,
  name text NOT NULL,
  member_type text DEFAULT 'public'::text,       -- student | staff | public
  student_id uuid,
  employee_id uuid,
  email text,
  phone text,
  status text DEFAULT 'active'::text,            -- active | suspended | expired
  joined_date date DEFAULT CURRENT_DATE,
  expires_date date,
  max_items integer,                             -- NULL = use the policy default
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_members_pkey PRIMARY KEY (id),
  CONSTRAINT library_members_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE SET NULL,
  CONSTRAINT library_members_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT library_members_max_items_check CHECK (max_items IS NULL OR max_items >= 0),
  CONSTRAINT library_members_type_check CHECK (member_type = ANY (ARRAY['student','staff','public'])),
  CONSTRAINT library_members_status_check CHECK (status = ANY (ARRAY['active','suspended','expired']))
);

-- A circulation record. due_date is snapshotted from the policy at issue
-- so a later policy change never retrospectively makes a loan overdue.
-- fine_amount is frozen at return; 'overdue' is a derived state the app
-- computes from due_date, and is also written here once collected.
CREATE TABLE IF NOT EXISTS public.library_loans (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  copy_id uuid NOT NULL,
  member_id uuid NOT NULL,
  loaned_at date DEFAULT CURRENT_DATE,
  due_date date NOT NULL,
  returned_at date,
  renew_count integer DEFAULT 0,
  status text DEFAULT 'on_loan'::text,           -- on_loan | returned | lost
  fine_amount numeric DEFAULT 0,                 -- accrued at return
  fine_paid boolean DEFAULT false,
  fine_waived boolean DEFAULT false,
  issued_by uuid,
  returned_by uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_loans_pkey PRIMARY KEY (id),
  CONSTRAINT library_loans_copy_id_fkey FOREIGN KEY (copy_id) REFERENCES public.library_copies(id) ON DELETE CASCADE,
  CONSTRAINT library_loans_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.library_members(id) ON DELETE CASCADE,
  CONSTRAINT library_loans_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT library_loans_returned_by_fkey FOREIGN KEY (returned_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT library_loans_renew_count_check CHECK (renew_count >= 0),
  CONSTRAINT library_loans_fine_check CHECK (fine_amount >= 0),
  CONSTRAINT library_loans_due_check CHECK (due_date >= loaned_at),
  CONSTRAINT library_loans_returned_check CHECK (returned_at IS NULL OR returned_at >= loaned_at),
  CONSTRAINT library_loans_status_check CHECK (status = ANY (ARRAY['on_loan','returned','lost']))
);

-- A reservation, placed against a TITLE because any copy satisfies it.
-- When a copy comes back it moves to the hold shelf for the first waiting
-- member and the hold becomes 'ready' until expires_at.
CREATE TABLE IF NOT EXISTS public.library_holds (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid NOT NULL,
  member_id uuid NOT NULL,
  placed_at timestamp with time zone DEFAULT now(),
  status text DEFAULT 'waiting'::text,           -- waiting | ready | fulfilled | cancelled | expired
  ready_at timestamp with time zone,
  expires_at date,                               -- how long the hold shelf keeps it
  copy_id uuid,                                  -- the copy set aside once ready
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_holds_pkey PRIMARY KEY (id),
  CONSTRAINT library_holds_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.library_items(id) ON DELETE CASCADE,
  CONSTRAINT library_holds_member_id_fkey FOREIGN KEY (member_id) REFERENCES public.library_members(id) ON DELETE CASCADE,
  CONSTRAINT library_holds_copy_id_fkey FOREIGN KEY (copy_id) REFERENCES public.library_copies(id) ON DELETE SET NULL,
  CONSTRAINT library_holds_status_check CHECK (status = ANY (ARRAY['waiting','ready','fulfilled','cancelled','expired']))
);

-- Circulation policy, one row for the whole library (id is forced true).
CREATE TABLE IF NOT EXISTS public.library_policy (
  id boolean DEFAULT true NOT NULL,
  loan_days integer DEFAULT 14,
  max_renewals integer DEFAULT 2,
  max_items_per_member integer DEFAULT 3,
  fine_per_day numeric DEFAULT 0.10,
  grace_days integer DEFAULT 0,                  -- days past due before a fine starts
  hold_shelf_days integer DEFAULT 3,
  currency text DEFAULT 'USD'::text,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT library_policy_pkey PRIMARY KEY (id),
  CONSTRAINT library_policy_singleton CHECK (id = true),
  CONSTRAINT library_policy_loan_days_check CHECK (loan_days > 0),
  CONSTRAINT library_policy_renewals_check CHECK (max_renewals >= 0),
  CONSTRAINT library_policy_max_items_check CHECK (max_items_per_member >= 0),
  CONSTRAINT library_policy_fine_check CHECK (fine_per_day >= 0),
  CONSTRAINT library_policy_grace_check CHECK (grace_days >= 0),
  CONSTRAINT library_policy_hold_shelf_check CHECK (hold_shelf_days >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_library_items_title ON public.library_items (title);
CREATE INDEX IF NOT EXISTS idx_library_items_call_number ON public.library_items (call_number);
CREATE INDEX IF NOT EXISTS idx_library_items_category ON public.library_items (category);
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_items_isbn ON public.library_items (isbn) WHERE isbn IS NOT NULL AND isbn <> '';

CREATE INDEX IF NOT EXISTS idx_library_copies_item_id ON public.library_copies (item_id);
CREATE INDEX IF NOT EXISTS idx_library_copies_status ON public.library_copies (status);
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_copies_accession ON public.library_copies (accession_no) WHERE accession_no IS NOT NULL AND accession_no <> '';
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_copies_barcode ON public.library_copies (barcode) WHERE barcode IS NOT NULL AND barcode <> '';

CREATE INDEX IF NOT EXISTS idx_library_members_status ON public.library_members (status);
CREATE INDEX IF NOT EXISTS idx_library_members_student_id ON public.library_members (student_id);
CREATE INDEX IF NOT EXISTS idx_library_members_employee_id ON public.library_members (employee_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_members_no ON public.library_members (member_no) WHERE member_no IS NOT NULL AND member_no <> '';

CREATE INDEX IF NOT EXISTS idx_library_loans_member_id ON public.library_loans (member_id);
CREATE INDEX IF NOT EXISTS idx_library_loans_status ON public.library_loans (status);
CREATE INDEX IF NOT EXISTS idx_library_loans_due_date ON public.library_loans (due_date);
-- A physical copy cannot be in two places. This is the constraint that stops
-- the same book being issued twice, which the UI alone cannot guarantee
-- once two librarians are working at different desks.
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_loans_active_copy ON public.library_loans (copy_id) WHERE status = 'on_loan';

CREATE INDEX IF NOT EXISTS idx_library_holds_item_id ON public.library_holds (item_id);
CREATE INDEX IF NOT EXISTS idx_library_holds_member_id ON public.library_holds (member_id);
CREATE INDEX IF NOT EXISTS idx_library_holds_status ON public.library_holds (status);
-- One live reservation per member per title, so the queue cannot be gamed
-- by placing the same hold repeatedly.
CREATE UNIQUE INDEX IF NOT EXISTS uq_library_holds_active ON public.library_holds (item_id, member_id) WHERE status = ANY (ARRAY['waiting','ready']);

-- ---- seed ---------------------------------------------------------------
-- Default circulation policy, so the module works before anyone visits
-- Settings. Never overwrites a policy the library has already tuned.
INSERT INTO public.library_policy (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.library_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_copies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_loans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_policy ENABLE ROW LEVEL SECURITY;

-- The catalog is readable by any employee: staff and teachers look books up
-- without being able to issue them. Everything that moves stock or money is
-- Librarian/Manager only.
DROP POLICY IF EXISTS "View library items" ON public.library_items;
DROP POLICY IF EXISTS "Manage library items" ON public.library_items;
CREATE POLICY "View library items" ON public.library_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage library items" ON public.library_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));

DROP POLICY IF EXISTS "View library copies" ON public.library_copies;
DROP POLICY IF EXISTS "Manage library copies" ON public.library_copies;
CREATE POLICY "View library copies" ON public.library_copies FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage library copies" ON public.library_copies FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));

DROP POLICY IF EXISTS "View library members" ON public.library_members;
DROP POLICY IF EXISTS "Manage library members" ON public.library_members;
CREATE POLICY "View library members" ON public.library_members FOR SELECT TO authenticated USING (has_any_role(ARRAY['Librarian','Teacher','Manager','Accountant']));
CREATE POLICY "Manage library members" ON public.library_members FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));

DROP POLICY IF EXISTS "View library loans" ON public.library_loans;
DROP POLICY IF EXISTS "Manage library loans" ON public.library_loans;
CREATE POLICY "View library loans" ON public.library_loans FOR SELECT TO authenticated USING (has_any_role(ARRAY['Librarian','Teacher','Manager','Accountant']));
CREATE POLICY "Manage library loans" ON public.library_loans FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));

DROP POLICY IF EXISTS "View library holds" ON public.library_holds;
DROP POLICY IF EXISTS "Manage library holds" ON public.library_holds;
CREATE POLICY "View library holds" ON public.library_holds FOR SELECT TO authenticated USING (has_any_role(ARRAY['Librarian','Teacher','Manager','Accountant']));
CREATE POLICY "Manage library holds" ON public.library_holds FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));

DROP POLICY IF EXISTS "View library policy" ON public.library_policy;
DROP POLICY IF EXISTS "Manage library policy" ON public.library_policy;
CREATE POLICY "View library policy" ON public.library_policy FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage library policy" ON public.library_policy FOR ALL TO authenticated USING (has_any_role(ARRAY['Librarian','Manager'])) WITH CHECK (has_any_role(ARRAY['Librarian','Manager']));
