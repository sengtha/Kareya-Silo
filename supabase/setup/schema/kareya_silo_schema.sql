-- =====================================================================
-- KAREYA SILO — ERP schema (public schema only)
-- ---------------------------------------------------------------------
-- One Silo == one business. The ENTIRE database belongs to a single
-- business, so there is NO company_id tenant key anywhere: the Silo IS
-- the tenant. This mirrors the Normsar-Silo reference.
--
-- Identity: users arrive with a short-lived JWT minted by the Silo's
-- `authenticate-hub-user` edge function after redeeming a Hub passport.
-- That JWT's `sub` is the HUB user id, so `auth.uid()` inside the Silo
-- resolves to the Hub user id. These users do NOT exist in this Silo's
-- own `auth.users` table, so ERP tables store `user_id uuid` as PLAIN
-- columns (no FK to auth.users). The local `employees` table is the
-- business roster and the basis for all row-level security.
-- =====================================================================

-- ---------------------------------------------------------------------
-- HR / Roster / RBAC
-- ---------------------------------------------------------------------
CREATE TABLE public.employees (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid,                       -- Hub user id (from minted JWT). No FK.
  name text NOT NULL,
  email text NOT NULL,
  roles text[] DEFAULT ARRAY['Staff'::text],
  department text,
  status text DEFAULT 'active'::text,
  work_type text DEFAULT 'fixed'::text,
  work_mode text DEFAULT 'onsite'::text,
  base_salary numeric DEFAULT 0,
  avatar text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT employees_pkey PRIMARY KEY (id),
  CONSTRAINT employees_email_key UNIQUE (email)
);

CREATE TABLE public.departments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT departments_pkey PRIMARY KEY (id)
);

CREATE TABLE public.roles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  description text,
  color text DEFAULT '#0d9488'::text,
  permissions text[] DEFAULT ARRAY[]::text[],
  is_system boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT roles_pkey PRIMARY KEY (id)
);

-- ---------------------------------------------------------------------
-- Attendance / Office
-- ---------------------------------------------------------------------
CREATE TABLE public.attendance_records (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  date date DEFAULT CURRENT_DATE,
  check_in timestamp with time zone,
  check_out timestamp with time zone,
  status text DEFAULT 'present'::text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT attendance_records_pkey PRIMARY KEY (id),
  CONSTRAINT attendance_records_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE
);

-- Single-row business configuration for this Silo.
CREATE TABLE public.office_configs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  work_start_time text DEFAULT '08:00'::text,
  work_end_time text DEFAULT '17:00'::text,
  wifi_name text,
  office_lat numeric,
  office_lng numeric,
  allowed_radius_meters integer DEFAULT 100,
  CONSTRAINT office_configs_pkey PRIMARY KEY (id)
);

CREATE TABLE public.holidays (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  date date NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT holidays_pkey PRIMARY KEY (id)
);

-- ---------------------------------------------------------------------
-- Business identity / letterhead (used by documents & invoices).
-- Multiple issuing profiles allowed (e.g. per brand), hence a table.
-- ---------------------------------------------------------------------
CREATE TABLE public.business_profiles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  address text,
  phone text,
  email text,
  tax_id text,
  logo_url text,
  is_default boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT business_profiles_pkey PRIMARY KEY (id)
);

-- ---------------------------------------------------------------------
-- Projects / Tasks
-- ---------------------------------------------------------------------
CREATE TABLE public.projects (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  status text DEFAULT 'active'::text,
  manager_id uuid,
  members uuid[] DEFAULT ARRAY[]::uuid[],
  client_ids uuid[] DEFAULT ARRAY[]::uuid[],
  start_date date,
  due_date date,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT projects_pkey PRIMARY KEY (id),
  CONSTRAINT projects_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.employees(id)
);

CREATE TABLE public.tasks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  status text DEFAULT 'todo'::text,
  progress integer DEFAULT 0,
  assignee_id uuid,
  start_date date,
  due_date date,
  project_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tasks_pkey PRIMARY KEY (id),
  CONSTRAINT tasks_assignee_id_fkey FOREIGN KEY (assignee_id) REFERENCES public.employees(id),
  CONSTRAINT tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Documents & workflows
-- ---------------------------------------------------------------------
CREATE TABLE public.document_templates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  description text,
  content text,
  workflow jsonb DEFAULT '[]'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT document_templates_pkey PRIMARY KEY (id)
);

CREATE TABLE public.document_requests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  template_id uuid,
  requester_id uuid,
  title text NOT NULL,
  content text,
  status text DEFAULT 'pending'::text,
  current_step_id text,
  current_step_order integer DEFAULT 1,
  history jsonb DEFAULT '[]'::jsonb,
  attachment_url text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT document_requests_pkey PRIMARY KEY (id),
  CONSTRAINT document_requests_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES public.employees(id),
  CONSTRAINT document_requests_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.document_templates(id)
);

-- ---------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------
CREATE TABLE public.calendar_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  description text,
  start_time timestamp with time zone NOT NULL,
  end_time timestamp with time zone NOT NULL,
  type text DEFAULT 'meeting'::text,
  creator_id uuid,                    -- employee id
  attendee_ids text[] DEFAULT ARRAY[]::text[],
  location text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT calendar_events_pkey PRIMARY KEY (id),
  CONSTRAINT calendar_events_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

-- ---------------------------------------------------------------------
-- Accounting
-- ---------------------------------------------------------------------
CREATE TABLE public.products_services (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  type text DEFAULT 'product'::text,
  price numeric DEFAULT 0,
  unit text DEFAULT 'unit'::text,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT products_services_pkey PRIMARY KEY (id)
);

CREATE TABLE public.clients (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  company_name text,
  email text,
  phone text,
  type text DEFAULT 'client'::text,
  status text DEFAULT 'active'::text,
  linked_user_email text,
  activities jsonb DEFAULT '[]'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT clients_pkey PRIMARY KEY (id)
);

CREATE TABLE public.client_activities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  client_id uuid NOT NULL,
  type text NOT NULL,
  date timestamp with time zone DEFAULT now(),
  description text,
  performed_by text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT client_activities_pkey PRIMARY KEY (id),
  CONSTRAINT client_activities_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE,
  CONSTRAINT client_activities_type_check CHECK (type = ANY (ARRAY['call'::text, 'email'::text, 'meeting'::text, 'note'::text]))
);

CREATE TABLE public.invoices (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  client_id uuid,
  invoice_number text NOT NULL,
  date date DEFAULT CURRENT_DATE,
  due_date date,
  tax_rate numeric DEFAULT 0,
  discount numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  status text DEFAULT 'pending'::text,
  template_id uuid,
  follow_ups jsonb DEFAULT '[]'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT invoices_pkey PRIMARY KEY (id),
  CONSTRAINT invoices_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL
);

CREATE TABLE public.invoice_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_id uuid,
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  price numeric DEFAULT 0,
  product_id uuid,
  CONSTRAINT invoice_items_pkey PRIMARY KEY (id),
  CONSTRAINT invoice_items_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE CASCADE
);

CREATE TABLE public.payroll_records (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  amount numeric DEFAULT 0,
  type text DEFAULT 'salary'::text,
  date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'paid'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payroll_records_pkey PRIMARY KEY (id),
  CONSTRAINT payroll_records_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Sales / CRM
-- ---------------------------------------------------------------------
CREATE TABLE public.deals (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  client_id uuid,
  title text NOT NULL,
  amount numeric DEFAULT 0,
  stage text DEFAULT 'new'::text,
  expected_close_date date,
  owner_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT deals_pkey PRIMARY KEY (id),
  CONSTRAINT deals_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE,
  CONSTRAINT deals_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.employees(id)
);

-- ---------------------------------------------------------------------
-- Support
-- ---------------------------------------------------------------------
CREATE TABLE public.support_forms (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  description text,
  is_active boolean DEFAULT true,
  fields jsonb DEFAULT '[]'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT support_forms_pkey PRIMARY KEY (id)
);

CREATE TABLE public.tickets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  subject text NOT NULL,
  description text,
  requester_name text,
  requester_email text,
  assignee_id uuid,
  status text DEFAULT 'open'::text,
  priority text DEFAULT 'medium'::text,
  source text DEFAULT 'form'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tickets_pkey PRIMARY KEY (id),
  CONSTRAINT tickets_assignee_id_fkey FOREIGN KEY (assignee_id) REFERENCES public.employees(id)
);

CREATE TABLE public.ticket_activities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  ticket_id uuid,
  actor_name text,
  content text,
  type text DEFAULT 'comment'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ticket_activities_pkey PRIMARY KEY (id),
  CONSTRAINT ticket_activities_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES public.tickets(id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------
CREATE TABLE public.assets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  category text NOT NULL,
  price numeric,
  purchase_date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'available'::text NOT NULL,
  condition text DEFAULT 'good'::text NOT NULL,
  serial_number text,
  assigned_to uuid,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  CONSTRAINT assets_pkey PRIMARY KEY (id),
  CONSTRAINT assets_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.employees(id) ON DELETE SET NULL
);

-- ---------------------------------------------------------------------
-- Notifications (ERP-scoped; recipient is a Hub user id)
-- ---------------------------------------------------------------------
CREATE TABLE public.notifications (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  recipient_id uuid NOT NULL,
  title text NOT NULL,
  message text NOT NULL,
  type text DEFAULT 'info'::text,
  is_read boolean DEFAULT false,
  link_to text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT notifications_pkey PRIMARY KEY (id),
  CONSTRAINT notifications_type_check CHECK (type = ANY (ARRAY['info'::text, 'success'::text, 'warning'::text, 'error'::text]))
);

-- =====================================================================
-- Indexes
-- =====================================================================
CREATE INDEX IF NOT EXISTS idx_employees_user_id ON public.employees (user_id);
CREATE INDEX IF NOT EXISTS idx_attendance_records_employee_id ON public.attendance_records (employee_id);
CREATE INDEX IF NOT EXISTS idx_tasks_project_id ON public.tasks (project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee_id ON public.tasks (assignee_id);
CREATE INDEX IF NOT EXISTS idx_projects_manager_id ON public.projects (manager_id);
CREATE INDEX IF NOT EXISTS idx_document_requests_requester_id ON public.document_requests (requester_id);
CREATE INDEX IF NOT EXISTS idx_document_requests_template_id ON public.document_requests (template_id);
CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice_id ON public.invoice_items (invoice_id);
CREATE INDEX IF NOT EXISTS idx_invoices_client_id ON public.invoices (client_id);
CREATE INDEX IF NOT EXISTS idx_client_activities_client_id ON public.client_activities (client_id);
CREATE INDEX IF NOT EXISTS idx_deals_client_id ON public.deals (client_id);
CREATE INDEX IF NOT EXISTS idx_deals_owner_id ON public.deals (owner_id);
CREATE INDEX IF NOT EXISTS idx_payroll_records_employee_id ON public.payroll_records (employee_id);
CREATE INDEX IF NOT EXISTS idx_ticket_activities_ticket_id ON public.ticket_activities (ticket_id);
CREATE INDEX IF NOT EXISTS idx_tickets_assignee_id ON public.tickets (assignee_id);
CREATE INDEX IF NOT EXISTS idx_assets_assigned_to ON public.assets (assigned_to);
CREATE INDEX IF NOT EXISTS idx_notifications_recipient_id ON public.notifications (recipient_id);

-- =====================================================================
-- RLS helper functions
-- ---------------------------------------------------------------------
-- `auth.uid()` inside the Silo == the Hub user id carried by the minted
-- JWT. All access is gated on the local `employees` roster. Because the
-- whole DB is one business, there is no company scoping — being an
-- employee at all is the base access gate.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.current_employee_id()
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT id FROM employees WHERE user_id = auth.uid() LIMIT 1;
$function$;

-- ---------------------------------------------------------------------
-- Attendance clock (server-authoritative).
--
-- Check-in/out MUST go through these RPCs, never a direct table write. They
-- stamp the real server time, compute late/present from office policy + the
-- employee's work type, and enforce one open record per day — so the client
-- can no longer forge the time, status, or date. RLS blocks employees from
-- inserting/updating attendance directly (see RLS.sql); corrections still flow
-- through the document-request workflow (HR/Admin apply them).
--
-- Times are evaluated in office-local time. The timezone is currently fixed to
-- Asia/Phnom_Penh (Cambodia); making it a per-silo setting is a follow-up.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clock_in()
 RETURNS public.attendance_records
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_cfg    office_configs;
  v_rec    attendance_records;
  v_local  timestamp := (now() AT TIME ZONE 'Asia/Phnom_Penh');
  v_today  date;
  v_status text := 'present';
  v_start  time;
BEGIN
  v_today := v_local::date;

  SELECT * INTO v_emp FROM employees WHERE user_id = auth.uid() LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  -- One open record per day (idempotent against double taps / retries).
  IF EXISTS (SELECT 1 FROM attendance_records
             WHERE employee_id = v_emp.id AND date = v_today AND check_out IS NULL) THEN
    RAISE EXCEPTION 'Already checked in today';
  END IF;

  SELECT * INTO v_cfg FROM office_configs LIMIT 1;

  -- Flexible workers are always present; otherwise 'late' if past the office
  -- start time plus a 15-minute grace period (office-local).
  IF lower(coalesce(v_emp.work_type, 'fixed')) <> 'flexible'
     AND coalesce(v_cfg.work_start_time, '') <> '' THEN
    BEGIN
      v_start := v_cfg.work_start_time::time;
      IF v_local::time > (v_start + interval '15 minutes') THEN
        v_status := 'late';
      END IF;
    EXCEPTION WHEN others THEN
      v_status := 'present';  -- malformed config → do not penalise
    END;
  END IF;

  INSERT INTO attendance_records (employee_id, date, check_in, status)
  VALUES (v_emp.id, v_today, now(), v_status)
  RETURNING * INTO v_rec;
  RETURN v_rec;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.clock_in() TO authenticated;

CREATE OR REPLACE FUNCTION public.clock_out()
 RETURNS public.attendance_records
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp employees;
  v_rec attendance_records;
BEGIN
  SELECT * INTO v_emp FROM employees WHERE user_id = auth.uid() LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  -- Close the caller's most recent open record (handles overnight shifts).
  UPDATE attendance_records SET check_out = now()
  WHERE id = (
    SELECT id FROM attendance_records
    WHERE employee_id = v_emp.id AND check_out IS NULL
    ORDER BY check_in DESC LIMIT 1
  )
  RETURNING * INTO v_rec;

  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'No active check-in found'; END IF;
  RETURN v_rec;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.clock_out() TO authenticated;

CREATE OR REPLACE FUNCTION public.is_employee()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE user_id = auth.uid()
       OR email = (auth.jwt() ->> 'email')
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_admin_or_founder()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employees e, unnest(e.roles) r
    WHERE (e.user_id = auth.uid() OR e.email = (auth.jwt() ->> 'email'))
      AND lower(r) IN ('admin', 'founder')
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_hr_or_admin()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employees e, unnest(e.roles) r
    WHERE (e.user_id = auth.uid() OR e.email = (auth.jwt() ->> 'email'))
      AND lower(r) IN ('admin', 'founder', 'hr', 'hr manager')
  );
$function$;

-- Generic "has one of these roles" (Admin/Founder always pass).
CREATE OR REPLACE FUNCTION public.has_any_role(required_roles text[])
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employees e, unnest(e.roles) r
    WHERE (e.user_id = auth.uid() OR e.email = (auth.jwt() ->> 'email'))
      AND (
        lower(r) IN ('admin', 'founder')
        OR lower(r) IN (SELECT lower(x) FROM unnest(required_roles) x)
      )
  );
$function$;

-- True when a role array contains NO privileged (admin/founder) role.
-- Used by the employees WITH CHECK so HR cannot mint admins.
CREATE OR REPLACE FUNCTION public.roles_are_unprivileged(rs text[])
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NOT EXISTS (
    SELECT 1 FROM unnest(coalesce(rs, ARRAY[]::text[])) r
    WHERE lower(r) IN ('admin', 'founder')
  );
$function$;

-- =====================================================================
-- DOCUMENT APPROVAL ENGINE (server-authoritative)
-- Advances a document request through its template workflow. SECURITY
-- DEFINER so it can update the row while the table's RLS forbids direct
-- writes. Enforces, on the SERVER: (a) the caller is an employee, (b) the
-- caller holds one of the CURRENT step's allowedRoles (admins bypass),
-- (c) separation of duties — the requester may never approve/reject/return
-- their own request, and (d) only the requester (or an admin) may resubmit.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.process_document(p_doc_id uuid, p_action text, p_comment text DEFAULT '')
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp      employees;
  v_doc      document_requests;
  v_tpl      document_templates;
  v_cur      jsonb;
  v_next     jsonb;
  v_allowed  text[];
  v_priv     boolean;
  v_status   text;
  v_next_id  text;
  v_next_ord integer;
BEGIN
  -- Identify the caller's employee row (prefer a user_id match).
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST
    LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  v_priv := EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder'));

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;

  SELECT * INTO v_tpl FROM document_templates WHERE id = v_doc.template_id;

  -- Locate the current step object in the template workflow.
  IF v_tpl.id IS NOT NULL AND v_doc.current_step_id IS NOT NULL THEN
    SELECT s INTO v_cur FROM jsonb_array_elements(coalesce(v_tpl.workflow, '[]'::jsonb)) s
      WHERE s->>'id' = v_doc.current_step_id LIMIT 1;
  END IF;

  IF p_action IN ('approve', 'reject', 'return') THEN
    IF v_doc.status <> 'pending' THEN RAISE EXCEPTION 'Document is not awaiting approval'; END IF;
    IF v_cur IS NULL THEN
      -- Orphaned/stuck (no resolvable step): only an admin may act to rescue it.
      IF NOT v_priv THEN RAISE EXCEPTION 'No current step to act on'; END IF;
    ELSE
      IF v_doc.requester_id = v_emp.id THEN RAISE EXCEPTION 'You cannot action your own request'; END IF;
      v_allowed := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_cur->'allowedRoles', '[]'::jsonb)));
      IF NOT v_priv AND NOT EXISTS (
        SELECT 1 FROM unnest(v_emp.roles) er JOIN unnest(v_allowed) ar ON lower(er) = lower(ar)
      ) THEN
        RAISE EXCEPTION 'Your role is not authorized to approve this step';
      END IF;
    END IF;
  ELSIF p_action = 'resubmit' THEN
    IF v_doc.requester_id <> v_emp.id AND NOT v_priv THEN RAISE EXCEPTION 'Only the requester may resubmit'; END IF;
    IF v_doc.status NOT IN ('returned', 'rejected') THEN RAISE EXCEPTION 'Only returned or rejected requests can be resubmitted'; END IF;
  ELSE
    RAISE EXCEPTION 'Unknown action: %', p_action;
  END IF;

  -- Compute the transition.
  IF p_action = 'approve' THEN
    SELECT s INTO v_next FROM jsonb_array_elements(coalesce(v_tpl.workflow, '[]'::jsonb)) s
      WHERE (s->>'order')::int > coalesce(v_doc.current_step_order, 0)
      ORDER BY (s->>'order')::int LIMIT 1;
    IF v_next IS NULL THEN
      v_status := 'approved'; v_next_id := NULL; v_next_ord := 0;
    ELSE
      v_status := 'pending'; v_next_id := v_next->>'id'; v_next_ord := (v_next->>'order')::int;
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_next_id := NULL; v_next_ord := v_doc.current_step_order;
  ELSIF p_action = 'return' THEN
    v_status := 'returned'; v_next_id := v_doc.current_step_id; v_next_ord := v_doc.current_step_order;
  ELSE -- resubmit
    SELECT s INTO v_next FROM jsonb_array_elements(coalesce(v_tpl.workflow, '[]'::jsonb)) s
      ORDER BY (s->>'order')::int LIMIT 1;
    v_status := 'pending'; v_next_id := v_next->>'id'; v_next_ord := coalesce((v_next->>'order')::int, 0);
  END IF;

  UPDATE document_requests SET
    status = v_status,
    current_step_id = v_next_id,
    current_step_order = v_next_ord,
    updated_at = now(),
    history = coalesce(history, '[]'::jsonb) || jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', p_action,
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', coalesce(p_comment, '')
    )
  WHERE id = p_doc_id
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_document(uuid, text, text) TO authenticated;

-- Canonical role registry: no two roles may share a name (case-insensitive).
CREATE UNIQUE INDEX IF NOT EXISTS roles_name_lower_key ON public.roles (lower(name));

-- =====================================================================
-- Careers & announcements (business-owned; the authenticated app reads
-- and writes these on the Silo client). A cross-silo PUBLIC feed on the
-- Hub for logged-out browsing is a future enhancement.
-- =====================================================================
CREATE TABLE public.job_postings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  department text,
  type text DEFAULT 'full_time'::text,
  status text DEFAULT 'open'::text,
  description text,
  salary_range text,
  is_public boolean DEFAULT true,
  posted_date date DEFAULT CURRENT_DATE,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT job_postings_pkey PRIMARY KEY (id)
);

CREATE TABLE public.candidates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  job_id uuid,
  name text NOT NULL,
  email text NOT NULL,
  phone text,
  stage text DEFAULT 'new'::text,
  applied_date timestamp with time zone DEFAULT now(),
  rating integer DEFAULT 0,
  CONSTRAINT candidates_pkey PRIMARY KEY (id),
  CONSTRAINT candidates_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.job_postings(id) ON DELETE CASCADE
);

-- Social/public posts are limited to product & service announcements
-- (job recruiting is handled by job_postings). The type CHECK enforces this.
CREATE TABLE public.market_announcements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  type text DEFAULT 'product'::text,
  content text,
  date date DEFAULT CURRENT_DATE,
  is_public boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT market_announcements_pkey PRIMARY KEY (id),
  CONSTRAINT market_announcements_type_check CHECK (type = ANY (ARRAY['product'::text, 'service'::text]))
);

CREATE INDEX IF NOT EXISTS idx_candidates_job_id ON public.candidates (job_id);

-- =====================================================================
-- DOUBLE-ENTRY ACCOUNTING
-- ---------------------------------------------------------------------
-- A full double-entry general ledger: every transaction posts a balanced
-- journal_entry (sum of debits == sum of credits) with journal_lines
-- against accounts in the chart_of_accounts. Sales invoices, vendor
-- bills, payments, and payroll auto-post; manual journals are supported.
-- All amounts are in the business's single reporting currency.
-- =====================================================================

CREATE TABLE public.chart_of_accounts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  type text NOT NULL,          -- asset | liability | equity | income | expense
  subtype text,                -- e.g. bank, receivable, payable, tax, cogs
  is_system boolean DEFAULT false,   -- seeded accounts the engine relies on
  is_active boolean DEFAULT true,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT chart_of_accounts_pkey PRIMARY KEY (id),
  CONSTRAINT chart_of_accounts_code_key UNIQUE (code),
  CONSTRAINT chart_of_accounts_type_check CHECK (type = ANY (ARRAY['asset','liability','equity','income','expense']))
);

CREATE TABLE public.tax_rates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  rate numeric NOT NULL DEFAULT 0,   -- percent, e.g. 10 for 10% VAT
  is_default boolean DEFAULT false,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tax_rates_pkey PRIMARY KEY (id)
);

CREATE TABLE public.vendors (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  email text,
  phone text,
  address text,
  tax_id text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT vendors_pkey PRIMARY KEY (id)
);

-- Vendor bills (Accounts Payable)
CREATE TABLE public.bills (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  vendor_id uuid,
  bill_number text,
  date date DEFAULT CURRENT_DATE,
  due_date date,
  category_account_id uuid,     -- expense account this bill hits
  description text,
  subtotal numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  amount numeric DEFAULT 0,      -- gross total
  status text DEFAULT 'unpaid'::text,   -- unpaid | partial | paid
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT bills_pkey PRIMARY KEY (id),
  CONSTRAINT bills_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL,
  CONSTRAINT bills_category_account_id_fkey FOREIGN KEY (category_account_id) REFERENCES public.chart_of_accounts(id) ON DELETE SET NULL,
  CONSTRAINT bills_status_check CHECK (status = ANY (ARRAY['unpaid','partial','paid']))
);

-- Payments in (from clients) and out (to vendors / payroll)
CREATE TABLE public.payments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  direction text NOT NULL,        -- in (received) | out (paid)
  date date DEFAULT CURRENT_DATE,
  amount numeric NOT NULL DEFAULT 0,
  method text DEFAULT 'bank'::text,   -- cash | bank | card | other
  deposit_account_id uuid,        -- cash/bank account money moves to/from
  invoice_id uuid,                -- when settling a sales invoice
  bill_id uuid,                   -- when settling a vendor bill
  party_type text,                -- client | vendor | employee | other
  party_id uuid,
  reference text,
  memo text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payments_pkey PRIMARY KEY (id),
  CONSTRAINT payments_direction_check CHECK (direction = ANY (ARRAY['in','out'])),
  CONSTRAINT payments_deposit_account_id_fkey FOREIGN KEY (deposit_account_id) REFERENCES public.chart_of_accounts(id) ON DELETE SET NULL,
  CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL,
  CONSTRAINT payments_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES public.bills(id) ON DELETE SET NULL
);

-- The general ledger: balanced journal entries + their lines
CREATE TABLE public.journal_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  date date DEFAULT CURRENT_DATE NOT NULL,
  memo text,
  reference text,
  source_type text DEFAULT 'manual'::text,   -- manual | invoice | bill | payment | payroll
  source_id uuid,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT journal_entries_pkey PRIMARY KEY (id)
);

CREATE TABLE public.journal_lines (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  entry_id uuid NOT NULL,
  account_id uuid NOT NULL,
  debit numeric DEFAULT 0,
  credit numeric DEFAULT 0,
  description text,
  CONSTRAINT journal_lines_pkey PRIMARY KEY (id),
  CONSTRAINT journal_lines_entry_id_fkey FOREIGN KEY (entry_id) REFERENCES public.journal_entries(id) ON DELETE CASCADE,
  CONSTRAINT journal_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT,
  CONSTRAINT journal_lines_sign_check CHECK (debit >= 0 AND credit >= 0)
);

CREATE INDEX IF NOT EXISTS idx_bills_vendor_id ON public.bills (vendor_id);
CREATE INDEX IF NOT EXISTS idx_payments_invoice_id ON public.payments (invoice_id);
CREATE INDEX IF NOT EXISTS idx_payments_bill_id ON public.payments (bill_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_entry_id ON public.journal_lines (entry_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_account_id ON public.journal_lines (account_id);
CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON public.journal_entries (date);

-- ---------------------------------------------------------------------
-- post_journal: atomically insert a balanced journal entry + lines.
-- p_lines is a jsonb array of { account_id, debit, credit, description }.
-- Rejects unbalanced entries. Returns the new entry id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_journal(
  p_date date,
  p_memo text,
  p_reference text,
  p_source_type text,
  p_source_id uuid,
  p_lines jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry_id uuid;
  v_debit numeric;
  v_credit numeric;
  v_line jsonb;
BEGIN
  SELECT COALESCE(SUM((l->>'debit')::numeric), 0), COALESCE(SUM((l->>'credit')::numeric), 0)
    INTO v_debit, v_credit
  FROM jsonb_array_elements(p_lines) AS l;

  IF round(v_debit, 2) <> round(v_credit, 2) THEN
    RAISE EXCEPTION 'Unbalanced journal: debits % <> credits %', v_debit, v_credit;
  END IF;
  IF v_debit = 0 THEN
    RAISE EXCEPTION 'Journal entry has no amounts';
  END IF;

  INSERT INTO public.journal_entries (date, memo, reference, source_type, source_id, created_by)
  VALUES (COALESCE(p_date, CURRENT_DATE), p_memo, p_reference, COALESCE(p_source_type, 'manual'), p_source_id, auth.uid())
  RETURNING id INTO v_entry_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    INSERT INTO public.journal_lines (entry_id, account_id, debit, credit, description)
    VALUES (
      v_entry_id,
      (v_line->>'account_id')::uuid,
      COALESCE((v_line->>'debit')::numeric, 0),
      COALESCE((v_line->>'credit')::numeric, 0),
      v_line->>'description'
    );
  END LOOP;

  RETURN v_entry_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.post_journal(date, text, text, text, uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- seed_chart_of_accounts: idempotently install a standard SME chart of
-- accounts. Safe to call once after provisioning; skips if any exist.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.seed_chart_of_accounts()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM chart_of_accounts) THEN RETURN; END IF;
  INSERT INTO chart_of_accounts (code, name, type, subtype, is_system) VALUES
    ('1000', 'Cash', 'asset', 'cash', true),
    ('1010', 'Bank', 'asset', 'bank', true),
    ('1100', 'Accounts Receivable', 'asset', 'receivable', true),
    ('1200', 'Inventory', 'asset', 'inventory', false),
    ('1300', 'Loans Receivable', 'asset', 'receivable', false),
    ('1500', 'Accumulated Depreciation', 'asset', 'contra', false),
    ('2000', 'Accounts Payable', 'liability', 'payable', true),
    ('2100', 'Tax Payable', 'liability', 'tax', true),
    ('3000', 'Owner Equity', 'equity', 'equity', true),
    ('3100', 'Retained Earnings', 'equity', 'retained', true),
    ('4000', 'Sales Revenue', 'income', 'sales', true),
    ('4100', 'Other Income', 'income', 'other', false),
    ('4200', 'Grant Income', 'income', 'grant', false),
    ('4300', 'Interest Income', 'income', 'interest', false),
    ('5000', 'Cost of Goods Sold', 'expense', 'cogs', false),
    ('5100', 'Salaries & Wages', 'expense', 'payroll', true),
    ('5200', 'Rent', 'expense', 'operating', false),
    ('5300', 'Utilities', 'expense', 'operating', false),
    ('5400', 'Office Supplies', 'expense', 'operating', false),
    ('5500', 'Depreciation Expense', 'expense', 'operating', false),
    ('5600', 'Grant / Program Expenses', 'expense', 'grant', false),
    ('5900', 'Other Expenses', 'expense', 'other', false);

  INSERT INTO tax_rates (name, rate, is_default) VALUES ('VAT 10%', 10, true), ('Zero-rated', 0, false);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.seed_chart_of_accounts() TO authenticated;

-- =====================================================================
-- LEAVE MANAGEMENT
-- ---------------------------------------------------------------------
-- Employees request time off against leave_types (each with an annual
-- entitlement); HR/Admin approve or reject. Balances are computed as
-- entitlement minus approved days in the year.
-- =====================================================================
CREATE TABLE public.leave_types (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  days_per_year numeric DEFAULT 0,
  is_paid boolean DEFAULT true,
  color text DEFAULT '#0d9488'::text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT leave_types_pkey PRIMARY KEY (id)
);

CREATE TABLE public.leave_requests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  type_id uuid,
  start_date date NOT NULL,
  end_date date NOT NULL,
  days numeric DEFAULT 1,
  reason text,
  status text DEFAULT 'pending'::text,   -- pending | approved | rejected | cancelled
  approver_id uuid,
  decided_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT leave_requests_pkey PRIMARY KEY (id),
  CONSTRAINT leave_requests_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT leave_requests_type_id_fkey FOREIGN KEY (type_id) REFERENCES public.leave_types(id) ON DELETE SET NULL,
  CONSTRAINT leave_requests_approver_id_fkey FOREIGN KEY (approver_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT leave_requests_status_check CHECK (status = ANY (ARRAY['pending','approved','rejected','cancelled']))
);

CREATE INDEX IF NOT EXISTS idx_leave_requests_employee_id ON public.leave_requests (employee_id);
CREATE INDEX IF NOT EXISTS idx_leave_requests_status ON public.leave_requests (status);

CREATE OR REPLACE FUNCTION public.seed_leave_types()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM leave_types) THEN RETURN; END IF;
  INSERT INTO leave_types (name, days_per_year, is_paid, color) VALUES
    ('Annual Leave', 18, true, '#0d9488'),
    ('Sick Leave', 10, true, '#f59e0b'),
    ('Unpaid Leave', 0, false, '#64748b'),
    ('Maternity Leave', 90, true, '#ec4899');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.seed_leave_types() TO authenticated;

-- =====================================================================
-- HR: payslips, performance reviews, employee documents
-- =====================================================================
CREATE TABLE public.payslips (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  period text NOT NULL,                 -- 'YYYY-MM'
  pay_date date DEFAULT CURRENT_DATE,
  base_salary numeric DEFAULT 0,
  allowances numeric DEFAULT 0,
  gross numeric DEFAULT 0,
  tax numeric DEFAULT 0,
  other_deductions numeric DEFAULT 0,
  net numeric DEFAULT 0,
  status text DEFAULT 'draft'::text,    -- draft | paid
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payslips_pkey PRIMARY KEY (id),
  CONSTRAINT payslips_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT payslips_status_check CHECK (status = ANY (ARRAY['draft','paid']))
);

CREATE TABLE public.performance_reviews (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  reviewer_id uuid,
  period text,
  review_date date DEFAULT CURRENT_DATE,
  rating integer DEFAULT 3,             -- 1..5
  strengths text,
  improvements text,
  goals text,
  status text DEFAULT 'draft'::text,    -- draft | finalized
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT performance_reviews_pkey PRIMARY KEY (id),
  CONSTRAINT performance_reviews_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT performance_reviews_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT performance_reviews_rating_check CHECK (rating BETWEEN 1 AND 5)
);

CREATE TABLE public.employee_documents (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  name text NOT NULL,
  type text DEFAULT 'contract'::text,   -- contract | id | certificate | other
  file_url text,
  issue_date date,
  expiry_date date,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT employee_documents_pkey PRIMARY KEY (id),
  CONSTRAINT employee_documents_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_payslips_employee_id ON public.payslips (employee_id);
CREATE INDEX IF NOT EXISTS idx_performance_reviews_employee_id ON public.performance_reviews (employee_id);
CREATE INDEX IF NOT EXISTS idx_employee_documents_employee_id ON public.employee_documents (employee_id);

-- =====================================================================
-- SALES: quotes / estimates (convert to invoices)
-- =====================================================================
CREATE TABLE public.quotes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_number text NOT NULL,
  client_id uuid,
  date date DEFAULT CURRENT_DATE,
  valid_until date,
  tax_rate numeric DEFAULT 0,
  discount numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  status text DEFAULT 'draft'::text,   -- draft | sent | accepted | declined | expired | invoiced
  notes text,
  invoice_id uuid,
  owner_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT quotes_pkey PRIMARY KEY (id),
  CONSTRAINT quotes_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT quotes_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL,
  CONSTRAINT quotes_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT quotes_status_check CHECK (status = ANY (ARRAY['draft','sent','accepted','declined','expired','invoiced']))
);

CREATE TABLE public.quote_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_id uuid,
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  price numeric DEFAULT 0,
  product_id uuid,
  CONSTRAINT quote_items_pkey PRIMARY KEY (id),
  CONSTRAINT quote_items_quote_id_fkey FOREIGN KEY (quote_id) REFERENCES public.quotes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_quotes_client_id ON public.quotes (client_id);
CREATE INDEX IF NOT EXISTS idx_quote_items_quote_id ON public.quote_items (quote_id);

-- =====================================================================
-- INVENTORY: stock items & movements (trading / consumable stock)
-- Distinct from `assets` (fixed equipment register). Stock is quantity-
-- tracked with reorder levels and an audit trail of every movement.
-- =====================================================================
CREATE TABLE public.stock_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sku text,
  name text NOT NULL,
  category text,
  unit text DEFAULT 'unit'::text,        -- unit | box | kg | litre | hour ...
  cost_price numeric DEFAULT 0,          -- what we pay
  sale_price numeric DEFAULT 0,          -- what we charge
  quantity numeric DEFAULT 0,            -- current on-hand (maintained by movements)
  reorder_level numeric DEFAULT 0,       -- low-stock threshold
  vendor_id uuid,
  location text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT stock_items_pkey PRIMARY KEY (id),
  CONSTRAINT stock_items_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL
);

CREATE TABLE public.stock_movements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid,
  type text DEFAULT 'in'::text,          -- in (receive) | out (issue/sell) | adjust (stock-take)
  quantity numeric NOT NULL,             -- always positive; direction implied by type
  unit_cost numeric DEFAULT 0,
  reason text,                           -- purchase | sale | damage | return | correction ...
  reference text,                        -- PO/invoice/note reference
  date date DEFAULT CURRENT_DATE,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT stock_movements_pkey PRIMARY KEY (id),
  CONSTRAINT stock_movements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE CASCADE,
  CONSTRAINT stock_movements_type_check CHECK (type = ANY (ARRAY['in','out','adjust']))
);

CREATE INDEX IF NOT EXISTS idx_stock_items_vendor_id ON public.stock_items (vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_item_id ON public.stock_movements (item_id);

-- =====================================================================
-- SUPPORT upgrades: categories, SLA tracking, CSAT, knowledge base
-- =====================================================================
-- Extend tickets with category, SLA targets, response/resolution stamps
-- and a customer-satisfaction score.
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS due_at timestamp with time zone;         -- SLA target (set from priority)
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS first_response_at timestamp with time zone;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS resolved_at timestamp with time zone;
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS csat_rating integer;                     -- 1..5
ALTER TABLE public.tickets ADD COLUMN IF NOT EXISTS csat_comment text;
ALTER TABLE public.tickets ADD CONSTRAINT tickets_csat_rating_check CHECK (csat_rating IS NULL OR csat_rating BETWEEN 1 AND 5);

-- Knowledge base / help centre articles (self-service deflection)
CREATE TABLE public.kb_articles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  category text,
  content text,
  tags text[] DEFAULT ARRAY[]::text[],
  is_published boolean DEFAULT false,
  views integer DEFAULT 0,
  author_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT kb_articles_pkey PRIMARY KEY (id),
  CONSTRAINT kb_articles_author_id_fkey FOREIGN KEY (author_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_kb_articles_category ON public.kb_articles (category);

-- =====================================================================
-- PROJECTS upgrades: budget, milestones, time tracking
-- =====================================================================
ALTER TABLE public.projects ADD COLUMN IF NOT EXISTS budget numeric DEFAULT 0;

CREATE TABLE public.project_milestones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  project_id uuid,
  title text NOT NULL,
  due_date date,
  status text DEFAULT 'pending'::text,   -- pending | done
  completed_at timestamp with time zone,
  sort_order integer DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT project_milestones_pkey PRIMARY KEY (id),
  CONSTRAINT project_milestones_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE,
  CONSTRAINT project_milestones_status_check CHECK (status = ANY (ARRAY['pending','done']))
);

CREATE TABLE public.time_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  project_id uuid,
  task_id uuid,
  employee_id uuid,
  hours numeric NOT NULL DEFAULT 0,
  description text,
  date date DEFAULT CURRENT_DATE,
  billable boolean DEFAULT true,
  rate numeric DEFAULT 0,                 -- billable rate per hour (snapshot)
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT time_entries_pkey PRIMARY KEY (id),
  CONSTRAINT time_entries_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE,
  CONSTRAINT time_entries_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE SET NULL,
  CONSTRAINT time_entries_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_project_milestones_project_id ON public.project_milestones (project_id);
CREATE INDEX IF NOT EXISTS idx_time_entries_project_id ON public.time_entries (project_id);
CREATE INDEX IF NOT EXISTS idx_time_entries_employee_id ON public.time_entries (employee_id);

-- =====================================================================
-- MARKETING: campaigns (multi-channel, with budget & funnel metrics)
-- =====================================================================
CREATE TABLE public.campaigns (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  channel text DEFAULT 'email'::text,       -- email | social | sms | event | ads
  status text DEFAULT 'draft'::text,        -- draft | scheduled | active | completed | cancelled
  audience text,
  start_date date,
  end_date date,
  budget numeric DEFAULT 0,
  spent numeric DEFAULT 0,
  reach integer DEFAULT 0,                  -- delivered / impressions
  opened integer DEFAULT 0,
  clicked integer DEFAULT 0,
  converted integer DEFAULT 0,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT campaigns_pkey PRIMARY KEY (id),
  CONSTRAINT campaigns_status_check CHECK (status = ANY (ARRAY['draft','scheduled','active','completed','cancelled']))
);

-- =====================================================================
-- PROCUREMENT: purchase orders & goods receipt (procure-to-pay)
-- Front half of the buying cycle: requisition (draft) -> approved ->
-- ordered -> received. Receiving posts stock_movements (type 'in') for
-- any linked stock item, and a PO can be turned into a vendor bill.
-- =====================================================================
CREATE TABLE public.purchase_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  po_number text NOT NULL,
  vendor_id uuid,
  status text DEFAULT 'draft'::text,     -- draft(requisition) | approved | ordered | received | cancelled
  order_date date DEFAULT CURRENT_DATE,
  expected_date date,
  subtotal numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  notes text,
  requested_by uuid,
  approved_by uuid,
  bill_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT purchase_orders_pkey PRIMARY KEY (id),
  CONSTRAINT purchase_orders_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES public.vendors(id) ON DELETE SET NULL,
  CONSTRAINT purchase_orders_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT purchase_orders_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT purchase_orders_bill_id_fkey FOREIGN KEY (bill_id) REFERENCES public.bills(id) ON DELETE SET NULL,
  CONSTRAINT purchase_orders_status_check CHECK (status = ANY (ARRAY['draft','approved','ordered','received','cancelled']))
);

CREATE TABLE public.purchase_order_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  po_id uuid,
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  price numeric DEFAULT 0,
  received_qty numeric DEFAULT 0,
  stock_item_id uuid,
  CONSTRAINT purchase_order_items_pkey PRIMARY KEY (id),
  CONSTRAINT purchase_order_items_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  CONSTRAINT purchase_order_items_stock_item_id_fkey FOREIGN KEY (stock_item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_vendor_id ON public.purchase_orders (vendor_id);
CREATE INDEX IF NOT EXISTS idx_purchase_order_items_po_id ON public.purchase_order_items (po_id);

-- =====================================================================
-- EXPENSE CLAIMS: employee-submitted, manager-approved, posts to ledger
-- =====================================================================
CREATE TABLE public.expense_claims (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  employee_id uuid,
  title text NOT NULL,
  category text,
  account_id uuid,                       -- expense account to debit
  amount numeric DEFAULT 0,
  date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'pending'::text,   -- pending | approved | rejected | reimbursed
  receipt_url text,
  notes text,
  approved_by uuid,
  reimbursed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT expense_claims_pkey PRIMARY KEY (id),
  CONSTRAINT expense_claims_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT expense_claims_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE SET NULL,
  CONSTRAINT expense_claims_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT expense_claims_status_check CHECK (status = ANY (ARRAY['pending','approved','rejected','reimbursed']))
);

CREATE INDEX IF NOT EXISTS idx_expense_claims_employee_id ON public.expense_claims (employee_id);

-- =====================================================================
-- RECURRING INVOICES: templates that generate invoices on a schedule
-- =====================================================================
CREATE TABLE public.recurring_invoices (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  client_id uuid,
  frequency text DEFAULT 'monthly'::text,   -- weekly | monthly | quarterly | yearly
  next_run date DEFAULT CURRENT_DATE,
  tax_rate numeric DEFAULT 0,
  discount numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  items jsonb DEFAULT '[]'::jsonb,          -- [{description, quantity, price}]
  status text DEFAULT 'active'::text,       -- active | paused | ended
  last_generated date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT recurring_invoices_pkey PRIMARY KEY (id),
  CONSTRAINT recurring_invoices_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT recurring_invoices_frequency_check CHECK (frequency = ANY (ARRAY['weekly','monthly','quarterly','yearly'])),
  CONSTRAINT recurring_invoices_status_check CHECK (status = ANY (ARRAY['active','paused','ended']))
);

-- =====================================================================
-- FIXED-ASSET DEPRECIATION
-- Depreciation config lives on the asset; each run records an entry and
-- posts DR Depreciation Expense / CR Accumulated Depreciation.
-- =====================================================================
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS useful_life_months integer DEFAULT 0;
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS salvage_value numeric DEFAULT 0;
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS depreciation_method text DEFAULT 'straight_line';
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS depreciation_start date;
ALTER TABLE public.assets ADD COLUMN IF NOT EXISTS accumulated_depreciation numeric DEFAULT 0;

CREATE TABLE public.depreciation_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  asset_id uuid,
  period date DEFAULT CURRENT_DATE,
  amount numeric NOT NULL DEFAULT 0,
  book_value numeric DEFAULT 0,           -- net book value after this entry
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT depreciation_entries_pkey PRIMARY KEY (id),
  CONSTRAINT depreciation_entries_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_depreciation_entries_asset_id ON public.depreciation_entries (asset_id);

-- =====================================================================
-- MULTI-CURRENCY (Cambodia runs dual USD + KHR)
-- The ledger is kept in ONE base currency (USD by default). Money-bearing
-- documents store their own `currency` plus an `exchange_rate` snapshot =
-- units of that currency per 1 unit of base. So base_amount = amount / rate.
-- USD (base): rate 1.  KHR: rate ~4100 (1 USD = 4100 KHR).
-- =====================================================================
CREATE TABLE public.currencies (
  code text NOT NULL,                    -- ISO 4217, e.g. USD, KHR
  name text NOT NULL,
  symbol text DEFAULT '$'::text,
  rate_to_base numeric DEFAULT 1,        -- units of this currency per 1 base unit
  is_base boolean DEFAULT false,
  is_active boolean DEFAULT true,
  decimals integer DEFAULT 2,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT currencies_pkey PRIMARY KEY (code)
);

-- Money-bearing documents carry their transaction currency + rate snapshot.
ALTER TABLE public.invoices        ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD';
ALTER TABLE public.invoices        ADD COLUMN IF NOT EXISTS exchange_rate numeric DEFAULT 1;
ALTER TABLE public.bills           ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD';
ALTER TABLE public.bills           ADD COLUMN IF NOT EXISTS exchange_rate numeric DEFAULT 1;
ALTER TABLE public.quotes          ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD';
ALTER TABLE public.quotes          ADD COLUMN IF NOT EXISTS exchange_rate numeric DEFAULT 1;
ALTER TABLE public.expense_claims  ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD';
ALTER TABLE public.expense_claims  ADD COLUMN IF NOT EXISTS exchange_rate numeric DEFAULT 1;
ALTER TABLE public.purchase_orders ADD COLUMN IF NOT EXISTS currency text DEFAULT 'USD';
ALTER TABLE public.purchase_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric DEFAULT 1;

-- seed_currencies: idempotently install USD (base) + KHR for Cambodia.
CREATE OR REPLACE FUNCTION public.seed_currencies()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO currencies (code, name, symbol, rate_to_base, is_base, decimals) VALUES
    ('USD', 'US Dollar', '$', 1, true, 2),
    ('KHR', 'Cambodian Riel', '៛', 4100, false, 0)
  ON CONFLICT (code) DO NOTHING;
END;
$$;
GRANT EXECUTE ON FUNCTION public.seed_currencies() TO authenticated;

-- =====================================================================
-- MANUFACTURING: bills of materials & work orders
-- A BOM defines the components consumed to build one unit of a finished
-- stock item. Completing a work order consumes component stock (out) and
-- produces finished stock (in).
-- =====================================================================
CREATE TABLE public.bills_of_materials (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  output_item_id uuid,                   -- finished good (a stock item)
  output_quantity numeric DEFAULT 1,     -- units produced per build
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT bills_of_materials_pkey PRIMARY KEY (id),
  CONSTRAINT bom_output_item_fkey FOREIGN KEY (output_item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL
);

CREATE TABLE public.bom_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bom_id uuid,
  stock_item_id uuid,                    -- component consumed
  quantity numeric DEFAULT 1,            -- per single build
  CONSTRAINT bom_items_pkey PRIMARY KEY (id),
  CONSTRAINT bom_items_bom_id_fkey FOREIGN KEY (bom_id) REFERENCES public.bills_of_materials(id) ON DELETE CASCADE,
  CONSTRAINT bom_items_stock_item_id_fkey FOREIGN KEY (stock_item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL
);

CREATE TABLE public.work_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  wo_number text NOT NULL,
  bom_id uuid,
  quantity numeric DEFAULT 1,            -- number of builds
  status text DEFAULT 'planned'::text,   -- planned | in_progress | done | cancelled
  start_date date DEFAULT CURRENT_DATE,
  due_date date,
  completed_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT work_orders_pkey PRIMARY KEY (id),
  CONSTRAINT work_orders_bom_id_fkey FOREIGN KEY (bom_id) REFERENCES public.bills_of_materials(id) ON DELETE SET NULL,
  CONSTRAINT work_orders_status_check CHECK (status = ANY (ARRAY['planned','in_progress','done','cancelled']))
);

CREATE INDEX IF NOT EXISTS idx_bom_items_bom_id ON public.bom_items (bom_id);
CREATE INDEX IF NOT EXISTS idx_work_orders_bom_id ON public.work_orders (bom_id);

-- =====================================================================
-- POINT OF SALE (POS): fast retail checkout
-- Each sale reduces stock and posts to the ledger (DR cash/bank, CR sales,
-- CR tax). Sold lines snapshot description/qty/price as JSON.
-- =====================================================================
CREATE TABLE public.pos_sales (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_number text NOT NULL,
  cashier_id uuid,
  items jsonb DEFAULT '[]'::jsonb,        -- [{stockItemId, description, quantity, price}]
  subtotal numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  payment_method text DEFAULT 'cash',     -- cash | card | bank
  tendered numeric DEFAULT 0,
  change_given numeric DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pos_sales_pkey PRIMARY KEY (id),
  CONSTRAINT pos_sales_cashier_id_fkey FOREIGN KEY (cashier_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_pos_sales_created_at ON public.pos_sales (created_at);

-- =====================================================================
-- AUDIT LOG (sovereign trust): immutable trail of sensitive actions
-- =====================================================================
CREATE TABLE public.audit_log (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  actor_id uuid,
  actor_name text,
  action text NOT NULL,                  -- e.g. 'payment.record', 'po.receive'
  entity text,                           -- e.g. 'invoice', 'purchase_order'
  entity_id text,
  detail text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT audit_log_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON public.audit_log (created_at);

-- =====================================================================
-- FLEET MANAGEMENT: vehicles, fuel, maintenance & trips
-- Vehicles tie to an employee driver; fuel and maintenance track cost and
-- odometer; trips log distance. Costs carry a currency for dual-currency ops.
-- =====================================================================
CREATE TABLE public.vehicles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  plate text,
  type text DEFAULT 'car'::text,          -- car | truck | motorcycle | van | other
  make text,
  model text,
  year integer,
  status text DEFAULT 'active'::text,     -- active | maintenance | retired
  odometer numeric DEFAULT 0,
  fuel_type text DEFAULT 'petrol'::text,  -- petrol | diesel | electric | hybrid
  driver_id uuid,
  purchase_date date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT vehicles_pkey PRIMARY KEY (id),
  CONSTRAINT vehicles_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT vehicles_status_check CHECK (status = ANY (ARRAY['active','maintenance','retired']))
);

CREATE TABLE public.fuel_logs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  vehicle_id uuid,
  date date DEFAULT CURRENT_DATE,
  liters numeric DEFAULT 0,
  cost numeric DEFAULT 0,
  odometer numeric DEFAULT 0,
  station text,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fuel_logs_pkey PRIMARY KEY (id),
  CONSTRAINT fuel_logs_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE CASCADE
);

CREATE TABLE public.maintenance_records (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  vehicle_id uuid,
  date date DEFAULT CURRENT_DATE,
  type text DEFAULT 'service'::text,      -- service | repair | inspection | tyre | other
  description text,
  cost numeric DEFAULT 0,
  odometer numeric DEFAULT 0,
  vendor text,
  next_service_date date,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT maintenance_records_pkey PRIMARY KEY (id),
  CONSTRAINT maintenance_records_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE CASCADE
);

CREATE TABLE public.trips (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  vehicle_id uuid,
  driver_id uuid,
  purpose text,
  date date DEFAULT CURRENT_DATE,
  start_odometer numeric DEFAULT 0,
  end_odometer numeric DEFAULT 0,
  distance numeric DEFAULT 0,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT trips_pkey PRIMARY KEY (id),
  CONSTRAINT trips_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE CASCADE,
  CONSTRAINT trips_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_fuel_logs_vehicle_id ON public.fuel_logs (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_maintenance_records_vehicle_id ON public.maintenance_records (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_trips_vehicle_id ON public.trips (vehicle_id);

-- =====================================================================
-- SALES ORDERS & FULFILLMENT (sell-side operational flow)
-- Mirror of purchase orders: confirm -> fulfill (ship) reduces stock, and
-- an order can be turned into an invoice. Complements quotes (financial).
-- =====================================================================
CREATE TABLE public.sales_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  so_number text NOT NULL,
  client_id uuid,
  status text DEFAULT 'draft'::text,     -- draft | confirmed | shipped | fulfilled | cancelled
  order_date date DEFAULT CURRENT_DATE,
  required_date date,
  subtotal numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  notes text,
  invoice_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT sales_orders_pkey PRIMARY KEY (id),
  CONSTRAINT sales_orders_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT sales_orders_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoices(id) ON DELETE SET NULL,
  CONSTRAINT sales_orders_status_check CHECK (status = ANY (ARRAY['draft','confirmed','shipped','fulfilled','cancelled']))
);

CREATE TABLE public.sales_order_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  so_id uuid,
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  price numeric DEFAULT 0,
  shipped_qty numeric DEFAULT 0,
  stock_item_id uuid,
  CONSTRAINT sales_order_items_pkey PRIMARY KEY (id),
  CONSTRAINT sales_order_items_so_id_fkey FOREIGN KEY (so_id) REFERENCES public.sales_orders(id) ON DELETE CASCADE,
  CONSTRAINT sales_order_items_stock_item_id_fkey FOREIGN KEY (stock_item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_sales_orders_client_id ON public.sales_orders (client_id);
CREATE INDEX IF NOT EXISTS idx_sales_order_items_so_id ON public.sales_order_items (so_id);

-- =====================================================================
-- WAREHOUSES & STOCK TRANSFERS (multi-location inventory)
-- stock_levels tracks on-hand per (item, warehouse); transfers move
-- quantity between locations (a null from = opening/receipt, null to = out).
-- =====================================================================
CREATE TABLE public.warehouses (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  code text,
  address text,
  is_default boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT warehouses_pkey PRIMARY KEY (id)
);

CREATE TABLE public.stock_levels (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid,
  warehouse_id uuid,
  quantity numeric DEFAULT 0,
  CONSTRAINT stock_levels_pkey PRIMARY KEY (id),
  CONSTRAINT stock_levels_item_wh_key UNIQUE (item_id, warehouse_id),
  CONSTRAINT stock_levels_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE CASCADE,
  CONSTRAINT stock_levels_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE
);

CREATE TABLE public.stock_transfers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid,
  from_warehouse_id uuid,
  to_warehouse_id uuid,
  quantity numeric NOT NULL DEFAULT 0,
  date date DEFAULT CURRENT_DATE,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT stock_transfers_pkey PRIMARY KEY (id),
  CONSTRAINT stock_transfers_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE CASCADE,
  CONSTRAINT stock_transfers_from_fkey FOREIGN KEY (from_warehouse_id) REFERENCES public.warehouses(id) ON DELETE SET NULL,
  CONSTRAINT stock_transfers_to_fkey FOREIGN KEY (to_warehouse_id) REFERENCES public.warehouses(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_stock_levels_warehouse_id ON public.stock_levels (warehouse_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_item_id ON public.stock_transfers (item_id);

-- =====================================================================
-- SHIPMENTS / DELIVERIES (logistics layer over fulfilled orders + fleet)
-- =====================================================================
CREATE TABLE public.shipments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  shipment_number text NOT NULL,
  sales_order_id uuid,
  vehicle_id uuid,
  driver_id uuid,
  status text DEFAULT 'pending'::text,    -- pending | in_transit | delivered | failed
  ship_date date DEFAULT CURRENT_DATE,
  delivered_at timestamp with time zone,
  address text,
  recipient text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT shipments_pkey PRIMARY KEY (id),
  CONSTRAINT shipments_sales_order_id_fkey FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id) ON DELETE SET NULL,
  CONSTRAINT shipments_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id) ON DELETE SET NULL,
  CONSTRAINT shipments_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT shipments_status_check CHECK (status = ANY (ARRAY['pending','in_transit','delivered','failed']))
);

CREATE INDEX IF NOT EXISTS idx_shipments_sales_order_id ON public.shipments (sales_order_id);

-- =====================================================================
-- SUPPLIER SCORECARDS: performance metrics on vendors
-- Lead time, rating and on-time delivery ratio (auto-tracked when a PO is
-- received vs its expected date), plus a preferred-supplier flag.
-- =====================================================================
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS lead_time_days integer DEFAULT 0;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS rating numeric DEFAULT 0;         -- 0..5
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS on_time_count integer DEFAULT 0;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS delivery_count integer DEFAULT 0;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS is_preferred boolean DEFAULT false;

-- =====================================================================
-- TRACEABILITY: lot/batch, serial numbers & shipping containers
-- Full chain traceability for recalls, expiry (FEFO) and import/export.
-- =====================================================================
-- Flag how each stock item is tracked.
ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS tracking text DEFAULT 'none';  -- none | lot | serial
ALTER TABLE public.stock_items ADD CONSTRAINT stock_items_tracking_check CHECK (tracking = ANY (ARRAY['none','lot','serial']));

-- Lot / batch records (manufacture & expiry, FEFO).
CREATE TABLE public.stock_lots (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid,
  lot_number text NOT NULL,
  quantity numeric DEFAULT 0,
  manufacture_date date,
  expiry_date date,
  warehouse_id uuid,
  status text DEFAULT 'active'::text,    -- active | quarantine | expired | consumed
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT stock_lots_pkey PRIMARY KEY (id),
  CONSTRAINT stock_lots_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE CASCADE,
  CONSTRAINT stock_lots_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE SET NULL,
  CONSTRAINT stock_lots_status_check CHECK (status = ANY (ARRAY['active','quarantine','expired','consumed']))
);

-- Individually serialized units.
CREATE TABLE public.serial_units (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  item_id uuid,
  serial_number text NOT NULL,
  status text DEFAULT 'in_stock'::text,  -- in_stock | allocated | sold | returned | scrapped
  lot_id uuid,
  warehouse_id uuid,
  sold_to uuid,
  sales_order_id uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT serial_units_pkey PRIMARY KEY (id),
  CONSTRAINT serial_units_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE CASCADE,
  CONSTRAINT serial_units_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.stock_lots(id) ON DELETE SET NULL,
  CONSTRAINT serial_units_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE SET NULL,
  CONSTRAINT serial_units_sold_to_fkey FOREIGN KEY (sold_to) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT serial_units_sales_order_id_fkey FOREIGN KEY (sales_order_id) REFERENCES public.sales_orders(id) ON DELETE SET NULL,
  CONSTRAINT serial_units_status_check CHECK (status = ANY (ARRAY['in_stock','allocated','sold','returned','scrapped']))
);

-- Shipping containers (import / export).
CREATE TABLE public.containers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  container_number text NOT NULL,
  type text DEFAULT '20ft'::text,        -- 20ft | 40ft | reefer | lcl | other
  status text DEFAULT 'planned'::text,   -- planned | loading | in_transit | arrived | unloaded | cleared
  direction text DEFAULT 'inbound'::text,-- inbound | outbound
  origin text,
  destination text,
  carrier text,
  bill_of_lading text,
  eta date,
  arrival_date date,
  purchase_order_id uuid,
  shipment_id uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT containers_pkey PRIMARY KEY (id),
  CONSTRAINT containers_po_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL,
  CONSTRAINT containers_shipment_fkey FOREIGN KEY (shipment_id) REFERENCES public.shipments(id) ON DELETE SET NULL,
  CONSTRAINT containers_status_check CHECK (status = ANY (ARRAY['planned','loading','in_transit','arrived','unloaded','cleared'])),
  CONSTRAINT containers_direction_check CHECK (direction = ANY (ARRAY['inbound','outbound']))
);

CREATE TABLE public.container_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  container_id uuid,
  description text NOT NULL,
  item_id uuid,
  quantity numeric DEFAULT 0,
  lot_number text,
  CONSTRAINT container_items_pkey PRIMARY KEY (id),
  CONSTRAINT container_items_container_id_fkey FOREIGN KEY (container_id) REFERENCES public.containers(id) ON DELETE CASCADE,
  CONSTRAINT container_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.stock_items(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_stock_lots_item_id ON public.stock_lots (item_id);
CREATE INDEX IF NOT EXISTS idx_stock_lots_expiry ON public.stock_lots (expiry_date);
CREATE INDEX IF NOT EXISTS idx_serial_units_item_id ON public.serial_units (item_id);
CREATE INDEX IF NOT EXISTS idx_container_items_container_id ON public.container_items (container_id);

-- =====================================================================
-- LMS (Learning Management): courses, lessons & enrollments
-- Employee learning & development — onboarding, compliance, upskilling.
-- Completing all lessons auto-issues a certificate.
-- =====================================================================
CREATE TABLE public.courses (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  description text,
  category text,
  level text DEFAULT 'beginner'::text,   -- beginner | intermediate | advanced
  instructor_id uuid,
  duration_hours numeric DEFAULT 0,
  passing_score integer DEFAULT 0,
  is_published boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT courses_pkey PRIMARY KEY (id),
  CONSTRAINT courses_instructor_id_fkey FOREIGN KEY (instructor_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT courses_level_check CHECK (level = ANY (ARRAY['beginner','intermediate','advanced']))
);

CREATE TABLE public.course_lessons (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  course_id uuid,
  title text NOT NULL,
  content text,
  video_url text,
  sort_order integer DEFAULT 0,
  duration_min integer DEFAULT 0,
  CONSTRAINT course_lessons_pkey PRIMARY KEY (id),
  CONSTRAINT course_lessons_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE
);

CREATE TABLE public.course_enrollments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  course_id uuid,
  employee_id uuid,
  status text DEFAULT 'enrolled'::text,   -- enrolled | in_progress | completed
  progress integer DEFAULT 0,
  completed_lessons jsonb DEFAULT '[]'::jsonb,
  score integer,
  enrolled_at timestamp with time zone DEFAULT now(),
  completed_at timestamp with time zone,
  certificate_number text,
  certified_at timestamp with time zone,
  CONSTRAINT course_enrollments_pkey PRIMARY KEY (id),
  CONSTRAINT course_enrollments_course_id_fkey FOREIGN KEY (course_id) REFERENCES public.courses(id) ON DELETE CASCADE,
  CONSTRAINT course_enrollments_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT course_enrollments_unique UNIQUE (course_id, employee_id),
  CONSTRAINT course_enrollments_status_check CHECK (status = ANY (ARRAY['enrolled','in_progress','completed']))
);

CREATE INDEX IF NOT EXISTS idx_course_lessons_course_id ON public.course_lessons (course_id);
CREATE INDEX IF NOT EXISTS idx_course_enrollments_employee_id ON public.course_enrollments (employee_id);

-- =====================================================================
-- ACADEMY (Student Information System + academic LMS)
-- A generic academic model that fits both K-12 schools and universities.
-- Students are distinct from staff (employees); teachers ARE employees.
-- =====================================================================
CREATE TABLE public.academic_terms (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                    -- "Semester 1 2026", "Term 2", "2026"
  type text DEFAULT 'semester'::text,    -- semester | term | trimester | year
  start_date date,
  end_date date,
  is_current boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT academic_terms_pkey PRIMARY KEY (id)
);

CREATE TABLE public.academic_programs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                    -- "Grade 10", "BSc Computer Science"
  code text,
  level text,                            -- primary | secondary | undergraduate | postgraduate ...
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT academic_programs_pkey PRIMARY KEY (id)
);

CREATE TABLE public.subjects (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  code text,
  credit_hours numeric DEFAULT 0,
  program_id uuid,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT subjects_pkey PRIMARY KEY (id),
  CONSTRAINT subjects_program_id_fkey FOREIGN KEY (program_id) REFERENCES public.academic_programs(id) ON DELETE SET NULL
);

CREATE TABLE public.students (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  student_number text,
  name text NOT NULL,
  email text,
  phone text,
  date_of_birth date,
  gender text,
  guardian_name text,
  guardian_phone text,
  guardian_email text,
  address text,
  program_id uuid,
  status text DEFAULT 'enrolled'::text,  -- applicant | enrolled | graduated | withdrawn | suspended
  enrolled_date date DEFAULT CURRENT_DATE,
  photo_url text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT students_pkey PRIMARY KEY (id),
  CONSTRAINT students_program_id_fkey FOREIGN KEY (program_id) REFERENCES public.academic_programs(id) ON DELETE SET NULL,
  CONSTRAINT students_status_check CHECK (status = ANY (ARRAY['applicant','enrolled','graduated','withdrawn','suspended']))
);

-- A scheduled offering of a subject in a term (class / course section).
CREATE TABLE public.class_sections (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  subject_id uuid,
  term_id uuid,
  teacher_id uuid,
  name text,                             -- section label, e.g. "10A", "Section 2"
  room text,
  schedule_days text,                    -- "Mon,Wed,Fri"
  start_time text,
  end_time text,
  capacity integer DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT class_sections_pkey PRIMARY KEY (id),
  CONSTRAINT class_sections_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.subjects(id) ON DELETE CASCADE,
  CONSTRAINT class_sections_term_id_fkey FOREIGN KEY (term_id) REFERENCES public.academic_terms(id) ON DELETE SET NULL,
  CONSTRAINT class_sections_teacher_id_fkey FOREIGN KEY (teacher_id) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE TABLE public.section_enrollments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  section_id uuid,
  student_id uuid,
  status text DEFAULT 'active'::text,    -- active | dropped | completed
  final_score numeric,
  final_grade text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT section_enrollments_pkey PRIMARY KEY (id),
  CONSTRAINT section_enrollments_section_id_fkey FOREIGN KEY (section_id) REFERENCES public.class_sections(id) ON DELETE CASCADE,
  CONSTRAINT section_enrollments_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE,
  CONSTRAINT section_enrollments_unique UNIQUE (section_id, student_id)
);

CREATE TABLE public.assessments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  section_id uuid,
  name text NOT NULL,
  type text DEFAULT 'assignment'::text,  -- assignment | quiz | midterm | final | exam | project
  max_score numeric DEFAULT 100,
  weight numeric DEFAULT 1,
  due_date date,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT assessments_pkey PRIMARY KEY (id),
  CONSTRAINT assessments_section_id_fkey FOREIGN KEY (section_id) REFERENCES public.class_sections(id) ON DELETE CASCADE
);

CREATE TABLE public.assessment_grades (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  assessment_id uuid,
  student_id uuid,
  score numeric,
  feedback text,
  CONSTRAINT assessment_grades_pkey PRIMARY KEY (id),
  CONSTRAINT assessment_grades_assessment_id_fkey FOREIGN KEY (assessment_id) REFERENCES public.assessments(id) ON DELETE CASCADE,
  CONSTRAINT assessment_grades_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE,
  CONSTRAINT assessment_grades_unique UNIQUE (assessment_id, student_id)
);

CREATE TABLE public.student_attendance (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  section_id uuid,
  student_id uuid,
  date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'present'::text,   -- present | absent | late | excused
  CONSTRAINT student_attendance_pkey PRIMARY KEY (id),
  CONSTRAINT student_attendance_section_id_fkey FOREIGN KEY (section_id) REFERENCES public.class_sections(id) ON DELETE CASCADE,
  CONSTRAINT student_attendance_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE,
  CONSTRAINT student_attendance_unique UNIQUE (section_id, student_id, date)
);

CREATE TABLE public.fee_structures (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  program_id uuid,
  term_id uuid,
  amount numeric DEFAULT 0,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT fee_structures_pkey PRIMARY KEY (id),
  CONSTRAINT fee_structures_program_id_fkey FOREIGN KEY (program_id) REFERENCES public.academic_programs(id) ON DELETE SET NULL,
  CONSTRAINT fee_structures_term_id_fkey FOREIGN KEY (term_id) REFERENCES public.academic_terms(id) ON DELETE SET NULL
);

CREATE TABLE public.student_invoices (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_number text,
  student_id uuid,
  term_id uuid,
  fee_structure_id uuid,
  description text,
  amount numeric DEFAULT 0,
  amount_paid numeric DEFAULT 0,
  status text DEFAULT 'unpaid'::text,    -- unpaid | partial | paid
  due_date date,
  issued_date date DEFAULT CURRENT_DATE,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT student_invoices_pkey PRIMARY KEY (id),
  CONSTRAINT student_invoices_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE,
  CONSTRAINT student_invoices_term_id_fkey FOREIGN KEY (term_id) REFERENCES public.academic_terms(id) ON DELETE SET NULL,
  CONSTRAINT student_invoices_fee_structure_id_fkey FOREIGN KEY (fee_structure_id) REFERENCES public.fee_structures(id) ON DELETE SET NULL,
  CONSTRAINT student_invoices_status_check CHECK (status = ANY (ARRAY['unpaid','partial','paid']))
);

CREATE INDEX IF NOT EXISTS idx_students_program_id ON public.students (program_id);
CREATE INDEX IF NOT EXISTS idx_class_sections_term_id ON public.class_sections (term_id);
CREATE INDEX IF NOT EXISTS idx_section_enrollments_section_id ON public.section_enrollments (section_id);
CREATE INDEX IF NOT EXISTS idx_assessments_section_id ON public.assessments (section_id);
CREATE INDEX IF NOT EXISTS idx_assessment_grades_assessment_id ON public.assessment_grades (assessment_id);
CREATE INDEX IF NOT EXISTS idx_student_attendance_section_id ON public.student_attendance (section_id);
CREATE INDEX IF NOT EXISTS idx_student_invoices_student_id ON public.student_invoices (student_id);

-- =====================================================================
-- LIMS (Laboratory Information Management System)
-- Test catalog -> sample accessioning -> test orders -> result entry
-- (auto-flagged vs reference range) -> verification -> report.
-- Plus instruments (calibration) and quality-control runs.
-- =====================================================================
CREATE TABLE public.lab_tests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  code text,
  category text,
  method text,
  specimen_type text,                    -- blood | urine | swab | water | food ...
  unit text,
  ref_low numeric,
  ref_high numeric,
  ref_text text,                         -- for qualitative tests (e.g. "Negative")
  price numeric DEFAULT 0,
  tat_hours integer DEFAULT 24,          -- turnaround target
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lab_tests_pkey PRIMARY KEY (id)
);

CREATE TABLE public.lab_samples (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  accession_number text NOT NULL,
  patient_name text,
  patient_ref text,                      -- MRN / external id
  client_id uuid,
  sample_type text,
  source text,
  priority text DEFAULT 'routine'::text, -- routine | urgent | stat
  status text DEFAULT 'received'::text,  -- received | in_progress | completed | reported | rejected
  collected_at timestamp with time zone,
  received_at timestamp with time zone DEFAULT now(),
  reported_at timestamp with time zone,
  storage_location text,
  ordered_by text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lab_samples_pkey PRIMARY KEY (id),
  CONSTRAINT lab_samples_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT lab_samples_priority_check CHECK (priority = ANY (ARRAY['routine','urgent','stat'])),
  CONSTRAINT lab_samples_status_check CHECK (status = ANY (ARRAY['received','in_progress','completed','reported','rejected']))
);

CREATE TABLE public.lab_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sample_id uuid,
  test_id uuid,
  status text DEFAULT 'pending'::text,   -- pending | in_progress | resulted | verified | rejected
  result_value numeric,
  result_flag text,                      -- normal | high | low | abnormal | positive | negative
  result_text text,
  resulted_by uuid,
  resulted_at timestamp with time zone,
  verified_by uuid,
  verified_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lab_orders_pkey PRIMARY KEY (id),
  CONSTRAINT lab_orders_sample_id_fkey FOREIGN KEY (sample_id) REFERENCES public.lab_samples(id) ON DELETE CASCADE,
  CONSTRAINT lab_orders_test_id_fkey FOREIGN KEY (test_id) REFERENCES public.lab_tests(id) ON DELETE SET NULL,
  CONSTRAINT lab_orders_resulted_by_fkey FOREIGN KEY (resulted_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT lab_orders_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT lab_orders_status_check CHECK (status = ANY (ARRAY['pending','in_progress','resulted','verified','rejected']))
);

CREATE TABLE public.lab_instruments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  type text,
  serial text,
  manufacturer text,
  status text DEFAULT 'active'::text,    -- active | maintenance | retired
  last_calibration date,
  next_calibration date,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lab_instruments_pkey PRIMARY KEY (id),
  CONSTRAINT lab_instruments_status_check CHECK (status = ANY (ARRAY['active','maintenance','retired']))
);

CREATE TABLE public.lab_qc_runs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  instrument_id uuid,
  test_id uuid,
  level text DEFAULT 'normal'::text,     -- low | normal | high
  run_date date DEFAULT CURRENT_DATE,
  expected numeric,
  measured numeric,
  status text DEFAULT 'pass'::text,      -- pass | warning | fail
  performed_by uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT lab_qc_runs_pkey PRIMARY KEY (id),
  CONSTRAINT lab_qc_runs_instrument_id_fkey FOREIGN KEY (instrument_id) REFERENCES public.lab_instruments(id) ON DELETE SET NULL,
  CONSTRAINT lab_qc_runs_test_id_fkey FOREIGN KEY (test_id) REFERENCES public.lab_tests(id) ON DELETE SET NULL,
  CONSTRAINT lab_qc_runs_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT lab_qc_runs_status_check CHECK (status = ANY (ARRAY['pass','warning','fail']))
);

CREATE INDEX IF NOT EXISTS idx_lab_orders_sample_id ON public.lab_orders (sample_id);
CREATE INDEX IF NOT EXISTS idx_lab_samples_status ON public.lab_samples (status);
CREATE INDEX IF NOT EXISTS idx_lab_qc_runs_run_date ON public.lab_qc_runs (run_date);

-- =====================================================================
-- GRANTS / RESEARCH MANAGEMENT (RMS)
-- Handles both directions: grants RECEIVED from funders (incoming) and
-- grants a foundation AWARDS to grantees (outgoing). Tracks budget lines,
-- milestones/deliverables, disbursement tranches and expenditure.
-- =====================================================================
CREATE TABLE public.funders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  type text DEFAULT 'foundation'::text,  -- government | foundation | corporate | individual | multilateral | academic
  contact_name text,
  email text,
  phone text,
  country text,
  website text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT funders_pkey PRIMARY KEY (id)
);

CREATE TABLE public.grants (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  code text,
  funder_id uuid,
  direction text DEFAULT 'incoming'::text, -- incoming (we receive) | outgoing (we award)
  program text,
  pi_id uuid,                              -- principal investigator / lead (employee)
  status text DEFAULT 'draft'::text,       -- draft | submitted | awarded | active | closed | rejected
  amount numeric DEFAULT 0,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  indirect_rate numeric DEFAULT 0,         -- overhead %
  start_date date,
  end_date date,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT grants_pkey PRIMARY KEY (id),
  CONSTRAINT grants_funder_id_fkey FOREIGN KEY (funder_id) REFERENCES public.funders(id) ON DELETE SET NULL,
  CONSTRAINT grants_pi_id_fkey FOREIGN KEY (pi_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT grants_direction_check CHECK (direction = ANY (ARRAY['incoming','outgoing'])),
  CONSTRAINT grants_status_check CHECK (status = ANY (ARRAY['draft','submitted','awarded','active','closed','rejected']))
);

CREATE TABLE public.grant_budget_lines (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  grant_id uuid,
  category text DEFAULT 'other'::text,     -- personnel | equipment | travel | supplies | subcontract | indirect | other
  description text,
  budgeted numeric DEFAULT 0,
  CONSTRAINT grant_budget_lines_pkey PRIMARY KEY (id),
  CONSTRAINT grant_budget_lines_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE CASCADE
);

CREATE TABLE public.grant_milestones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  grant_id uuid,
  title text NOT NULL,
  type text DEFAULT 'milestone'::text,     -- report | deliverable | milestone | payment
  due_date date,
  status text DEFAULT 'pending'::text,     -- pending | submitted | approved
  completed_at timestamp with time zone,
  notes text,
  CONSTRAINT grant_milestones_pkey PRIMARY KEY (id),
  CONSTRAINT grant_milestones_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE CASCADE,
  CONSTRAINT grant_milestones_status_check CHECK (status = ANY (ARRAY['pending','submitted','approved']))
);

CREATE TABLE public.grant_disbursements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  grant_id uuid,
  amount numeric DEFAULT 0,
  date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'scheduled'::text,   -- scheduled | received | paid
  reference text,
  notes text,
  CONSTRAINT grant_disbursements_pkey PRIMARY KEY (id),
  CONSTRAINT grant_disbursements_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE CASCADE,
  CONSTRAINT grant_disbursements_status_check CHECK (status = ANY (ARRAY['scheduled','received','paid']))
);

CREATE TABLE public.grant_expenses (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  grant_id uuid,
  budget_line_id uuid,
  date date DEFAULT CURRENT_DATE,
  description text,
  amount numeric DEFAULT 0,
  vendor text,
  reference text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT grant_expenses_pkey PRIMARY KEY (id),
  CONSTRAINT grant_expenses_grant_id_fkey FOREIGN KEY (grant_id) REFERENCES public.grants(id) ON DELETE CASCADE,
  CONSTRAINT grant_expenses_budget_line_id_fkey FOREIGN KEY (budget_line_id) REFERENCES public.grant_budget_lines(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_grants_funder_id ON public.grants (funder_id);
CREATE INDEX IF NOT EXISTS idx_grant_budget_lines_grant_id ON public.grant_budget_lines (grant_id);
CREATE INDEX IF NOT EXISTS idx_grant_milestones_grant_id ON public.grant_milestones (grant_id);
CREATE INDEX IF NOT EXISTS idx_grant_disbursements_grant_id ON public.grant_disbursements (grant_id);
CREATE INDEX IF NOT EXISTS idx_grant_expenses_grant_id ON public.grant_expenses (grant_id);

-- =====================================================================
-- CLINIC EMR (Electronic Medical Records)
-- Patient registry, appointments, clinical encounters (SOAP + vitals),
-- prescriptions and patient billing. Sensitive PHI — access is limited
-- to clinical roles via RLS.
-- =====================================================================
CREATE TABLE public.patients (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  mrn text,                                  -- medical record number
  first_name text NOT NULL,
  last_name text,
  dob date,
  sex text,                                  -- male | female | other
  phone text,
  email text,
  address text,
  blood_type text,
  allergies text,
  chronic_conditions text,
  emergency_contact text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT patients_pkey PRIMARY KEY (id)
);

CREATE TABLE public.clinic_appointments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid,
  provider_id uuid,                          -- attending employee
  scheduled_at timestamp with time zone NOT NULL,
  duration_min integer DEFAULT 30,
  reason text,
  status text DEFAULT 'scheduled'::text,     -- scheduled | arrived | in_progress | completed | cancelled | no_show
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT clinic_appointments_pkey PRIMARY KEY (id),
  CONSTRAINT clinic_appointments_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT clinic_appointments_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT clinic_appointments_status_check CHECK (status = ANY (ARRAY['scheduled','arrived','in_progress','completed','cancelled','no_show']))
);

CREATE TABLE public.encounters (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid,
  provider_id uuid,
  appointment_id uuid,
  date date DEFAULT CURRENT_DATE,
  chief_complaint text,
  subjective text,                           -- S
  objective text,                            -- O
  assessment text,                           -- A
  plan text,                                 -- P
  diagnosis text,                            -- ICD-10 codes / free text
  -- vitals
  temp_c numeric,
  pulse integer,
  resp_rate integer,
  systolic integer,
  diastolic integer,
  spo2 integer,
  weight_kg numeric,
  height_cm numeric,
  status text DEFAULT 'open'::text,          -- open | signed
  signed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT encounters_pkey PRIMARY KEY (id),
  CONSTRAINT encounters_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT encounters_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT encounters_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.clinic_appointments(id) ON DELETE SET NULL,
  CONSTRAINT encounters_status_check CHECK (status = ANY (ARRAY['open','signed']))
);

CREATE TABLE public.prescriptions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid,
  encounter_id uuid,
  provider_id uuid,
  drug text NOT NULL,
  dose text,
  frequency text,
  duration text,
  quantity numeric,
  refills integer DEFAULT 0,
  instructions text,
  status text DEFAULT 'active'::text,        -- active | completed | cancelled
  date date DEFAULT CURRENT_DATE,
  CONSTRAINT prescriptions_pkey PRIMARY KEY (id),
  CONSTRAINT prescriptions_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT prescriptions_encounter_id_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT prescriptions_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT prescriptions_status_check CHECK (status = ANY (ARRAY['active','completed','cancelled']))
);

CREATE TABLE public.clinic_invoices (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid,
  encounter_id uuid,
  date date DEFAULT CURRENT_DATE,
  status text DEFAULT 'draft'::text,         -- draft | billed | paid
  subtotal numeric DEFAULT 0,
  tax numeric DEFAULT 0,
  total numeric DEFAULT 0,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  paid_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT clinic_invoices_pkey PRIMARY KEY (id),
  CONSTRAINT clinic_invoices_patient_id_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT clinic_invoices_encounter_id_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT clinic_invoices_status_check CHECK (status = ANY (ARRAY['draft','billed','paid']))
);

CREATE TABLE public.clinic_invoice_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_id uuid,
  description text NOT NULL,
  kind text DEFAULT 'service'::text,         -- consultation | procedure | lab | medication | service
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  CONSTRAINT clinic_invoice_items_pkey PRIMARY KEY (id),
  CONSTRAINT clinic_invoice_items_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.clinic_invoices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_clinic_appointments_patient_id ON public.clinic_appointments (patient_id);
CREATE INDEX IF NOT EXISTS idx_clinic_appointments_scheduled_at ON public.clinic_appointments (scheduled_at);
CREATE INDEX IF NOT EXISTS idx_encounters_patient_id ON public.encounters (patient_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_patient_id ON public.prescriptions (patient_id);
CREATE INDEX IF NOT EXISTS idx_clinic_invoices_patient_id ON public.clinic_invoices (patient_id);
CREATE INDEX IF NOT EXISTS idx_clinic_invoice_items_invoice_id ON public.clinic_invoice_items (invoice_id);

-- =====================================================================
-- HOTEL PMS (Property Management System)
-- Room inventory & types, guest profiles, reservations, guest folios
-- (charges & payments) and housekeeping.
-- =====================================================================
CREATE TABLE public.room_types (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  base_rate numeric DEFAULT 0,
  capacity integer DEFAULT 2,
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT room_types_pkey PRIMARY KEY (id)
);

CREATE TABLE public.rooms (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  number text NOT NULL,
  room_type_id uuid,
  floor text,
  status text DEFAULT 'available'::text,     -- available | occupied | dirty | maintenance
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rooms_pkey PRIMARY KEY (id),
  CONSTRAINT rooms_room_type_id_fkey FOREIGN KEY (room_type_id) REFERENCES public.room_types(id) ON DELETE SET NULL,
  CONSTRAINT rooms_status_check CHECK (status = ANY (ARRAY['available','occupied','dirty','maintenance']))
);

CREATE TABLE public.hotel_guests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  first_name text NOT NULL,
  last_name text,
  phone text,
  email text,
  id_number text,                            -- passport / national ID
  nationality text,
  address text,
  vip boolean DEFAULT false,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hotel_guests_pkey PRIMARY KEY (id)
);

CREATE TABLE public.reservations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  code text,
  guest_id uuid,
  room_id uuid,
  room_type_id uuid,
  check_in date NOT NULL,
  check_out date NOT NULL,
  status text DEFAULT 'booked'::text,        -- booked | checked_in | checked_out | cancelled | no_show
  adults integer DEFAULT 1,
  children integer DEFAULT 0,
  rate numeric DEFAULT 0,                     -- nightly rate
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  source text,                               -- walk_in | phone | ota | website | agent
  checked_in_at timestamp with time zone,
  checked_out_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT reservations_pkey PRIMARY KEY (id),
  CONSTRAINT reservations_guest_id_fkey FOREIGN KEY (guest_id) REFERENCES public.hotel_guests(id) ON DELETE SET NULL,
  CONSTRAINT reservations_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE SET NULL,
  CONSTRAINT reservations_room_type_id_fkey FOREIGN KEY (room_type_id) REFERENCES public.room_types(id) ON DELETE SET NULL,
  CONSTRAINT reservations_status_check CHECK (status = ANY (ARRAY['booked','checked_in','checked_out','cancelled','no_show']))
);

CREATE TABLE public.folio_charges (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  reservation_id uuid,
  date date DEFAULT CURRENT_DATE,
  type text DEFAULT 'room'::text,            -- room | food | minibar | laundry | service | tax | payment
  description text,
  amount numeric DEFAULT 0,                  -- positive = charge, positive payment rows use type='payment'
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT folio_charges_pkey PRIMARY KEY (id),
  CONSTRAINT folio_charges_reservation_id_fkey FOREIGN KEY (reservation_id) REFERENCES public.reservations(id) ON DELETE CASCADE
);

CREATE TABLE public.housekeeping_tasks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  room_id uuid,
  date date DEFAULT CURRENT_DATE,
  type text DEFAULT 'cleaning'::text,        -- cleaning | inspection | maintenance | turndown
  status text DEFAULT 'pending'::text,       -- pending | in_progress | done
  assigned_to uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT housekeeping_tasks_pkey PRIMARY KEY (id),
  CONSTRAINT housekeeping_tasks_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.rooms(id) ON DELETE CASCADE,
  CONSTRAINT housekeeping_tasks_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT housekeeping_tasks_status_check CHECK (status = ANY (ARRAY['pending','in_progress','done']))
);

CREATE INDEX IF NOT EXISTS idx_rooms_room_type_id ON public.rooms (room_type_id);
CREATE INDEX IF NOT EXISTS idx_reservations_guest_id ON public.reservations (guest_id);
CREATE INDEX IF NOT EXISTS idx_reservations_check_in ON public.reservations (check_in);
CREATE INDEX IF NOT EXISTS idx_folio_charges_reservation_id ON public.folio_charges (reservation_id);
CREATE INDEX IF NOT EXISTS idx_housekeeping_tasks_room_id ON public.housekeeping_tasks (room_id);

-- =====================================================================
-- RESTAURANT POS + KDS (Kitchen Display System)
-- Menu catalog, dining tables, orders and per-item kitchen routing so
-- the kitchen display can track ticket items from queued -> ready.
-- =====================================================================
CREATE TABLE public.menu_categories (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  sort integer DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT menu_categories_pkey PRIMARY KEY (id)
);

CREATE TABLE public.menu_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  category_id uuid,
  name text NOT NULL,
  price numeric DEFAULT 0,
  description text,
  station text DEFAULT 'kitchen'::text,      -- kitchen | bar | dessert
  available boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT menu_items_pkey PRIMARY KEY (id),
  CONSTRAINT menu_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.menu_categories(id) ON DELETE SET NULL
);

CREATE TABLE public.restaurant_tables (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                        -- e.g. "T1"
  seats integer DEFAULT 4,
  area text,                                 -- indoor | patio | bar | private
  status text DEFAULT 'available'::text,     -- available | seated | billed
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT restaurant_tables_pkey PRIMARY KEY (id),
  CONSTRAINT restaurant_tables_status_check CHECK (status = ANY (ARRAY['available','seated','billed']))
);

CREATE TABLE public.restaurant_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  order_no text,
  table_id uuid,
  type text DEFAULT 'dine_in'::text,         -- dine_in | takeaway | delivery
  status text DEFAULT 'open'::text,          -- open | sent | preparing | ready | served | paid | cancelled
  server_id uuid,
  guests integer DEFAULT 1,
  subtotal numeric DEFAULT 0,
  tax numeric DEFAULT 0,
  total numeric DEFAULT 0,
  currency text DEFAULT 'USD',
  exchange_rate numeric DEFAULT 1,
  payment_method text,                       -- cash | card | qr | wallet
  opened_at timestamp with time zone DEFAULT now(),
  closed_at timestamp with time zone,
  notes text,
  CONSTRAINT restaurant_orders_pkey PRIMARY KEY (id),
  CONSTRAINT restaurant_orders_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.restaurant_tables(id) ON DELETE SET NULL,
  CONSTRAINT restaurant_orders_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT restaurant_orders_status_check CHECK (status = ANY (ARRAY['open','sent','preparing','ready','served','paid','cancelled']))
);

CREATE TABLE public.order_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  order_id uuid,
  menu_item_id uuid,
  name text NOT NULL,
  station text DEFAULT 'kitchen'::text,
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  status text DEFAULT 'queued'::text,        -- queued | preparing | ready | served | void
  notes text,
  sent_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT order_items_pkey PRIMARY KEY (id),
  CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.restaurant_orders(id) ON DELETE CASCADE,
  CONSTRAINT order_items_menu_item_id_fkey FOREIGN KEY (menu_item_id) REFERENCES public.menu_items(id) ON DELETE SET NULL,
  CONSTRAINT order_items_status_check CHECK (status = ANY (ARRAY['queued','preparing','ready','served','void']))
);

CREATE INDEX IF NOT EXISTS idx_menu_items_category_id ON public.menu_items (category_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_orders_table_id ON public.restaurant_orders (table_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_orders_status ON public.restaurant_orders (status);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON public.order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_status ON public.order_items (status);

-- =====================================================================
-- PHARMACY (drug catalog, batch/expiry stock, dispensing/POS)
-- =====================================================================
CREATE TABLE public.pharmacy_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  generic_name text,
  form text DEFAULT 'tablet'::text,          -- tablet | capsule | syrup | injection | cream | drops | other
  strength text,                             -- e.g. '500mg'
  unit text DEFAULT 'unit'::text,            -- selling unit: box | strip | bottle | unit
  category text,
  barcode text,
  requires_rx boolean DEFAULT false,         -- prescription-only medicine
  reorder_level numeric DEFAULT 0,
  sale_price numeric DEFAULT 0,
  cost_price numeric DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pharmacy_products_pkey PRIMARY KEY (id)
);

-- Stock is held per batch so expiry is tracked (FEFO dispensing).
CREATE TABLE public.pharmacy_batches (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  product_id uuid NOT NULL,
  batch_number text,
  expiry_date date,
  quantity numeric DEFAULT 0,
  cost_price numeric DEFAULT 0,
  supplier text,
  received_date date DEFAULT CURRENT_DATE,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pharmacy_batches_pkey PRIMARY KEY (id),
  CONSTRAINT pharmacy_batches_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.pharmacy_products(id) ON DELETE CASCADE
);

CREATE TABLE public.pharmacy_sales (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_number text,
  customer_name text,                        -- walk-in allowed (nullable)
  prescriber text,                           -- prescribing clinician (for Rx items)
  rx_reference text,
  subtotal numeric DEFAULT 0,
  discount numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  payment_method text DEFAULT 'cash'::text,  -- cash | card | qr | transfer
  status text DEFAULT 'completed'::text,     -- completed | void
  sold_by uuid,
  currency text DEFAULT 'USD'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pharmacy_sales_pkey PRIMARY KEY (id),
  CONSTRAINT pharmacy_sales_sold_by_fkey FOREIGN KEY (sold_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT pharmacy_sales_status_check CHECK (status = ANY (ARRAY['completed','void']))
);

CREATE TABLE public.pharmacy_sale_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_id uuid NOT NULL,
  product_id uuid,
  batch_id uuid,
  description text,
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  line_total numeric DEFAULT 0,
  CONSTRAINT pharmacy_sale_items_pkey PRIMARY KEY (id),
  CONSTRAINT pharmacy_sale_items_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.pharmacy_sales(id) ON DELETE CASCADE,
  CONSTRAINT pharmacy_sale_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.pharmacy_products(id) ON DELETE SET NULL,
  CONSTRAINT pharmacy_sale_items_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.pharmacy_batches(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_pharmacy_batches_product_id ON public.pharmacy_batches (product_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_batches_expiry ON public.pharmacy_batches (expiry_date);
CREATE INDEX IF NOT EXISTS idx_pharmacy_sale_items_sale_id ON public.pharmacy_sale_items (sale_id);

-- =====================================================================
-- RETAIL POS (barcode retail, cashier shifts / Z-reports)
-- =====================================================================
CREATE TABLE public.retail_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  sku text,
  barcode text,
  category text,
  price numeric DEFAULT 0,
  cost numeric DEFAULT 0,
  tax_rate numeric DEFAULT 0,
  quantity numeric DEFAULT 0,
  reorder_level numeric DEFAULT 0,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT retail_products_pkey PRIMARY KEY (id)
);

-- A cashier session. Closing it produces the Z-report (expected vs counted cash).
CREATE TABLE public.retail_shifts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  opened_by uuid,
  opened_at timestamp with time zone DEFAULT now(),
  opening_float numeric DEFAULT 0,
  closed_at timestamp with time zone,
  counted_cash numeric,
  expected_cash numeric,
  variance numeric,
  status text DEFAULT 'open'::text,          -- open | closed
  note text,
  CONSTRAINT retail_shifts_pkey PRIMARY KEY (id),
  CONSTRAINT retail_shifts_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT retail_shifts_status_check CHECK (status = ANY (ARRAY['open','closed']))
);

CREATE TABLE public.retail_sales (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_number text,
  shift_id uuid,
  subtotal numeric DEFAULT 0,
  discount numeric DEFAULT 0,
  tax_amount numeric DEFAULT 0,
  total numeric DEFAULT 0,
  payment_method text DEFAULT 'cash'::text,  -- cash | card | qr | transfer
  tendered numeric DEFAULT 0,
  change_due numeric DEFAULT 0,
  customer_name text,
  sold_by uuid,
  status text DEFAULT 'completed'::text,     -- completed | void
  currency text DEFAULT 'USD'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT retail_sales_pkey PRIMARY KEY (id),
  CONSTRAINT retail_sales_shift_id_fkey FOREIGN KEY (shift_id) REFERENCES public.retail_shifts(id) ON DELETE SET NULL,
  CONSTRAINT retail_sales_sold_by_fkey FOREIGN KEY (sold_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT retail_sales_status_check CHECK (status = ANY (ARRAY['completed','void']))
);

CREATE TABLE public.retail_sale_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sale_id uuid NOT NULL,
  product_id uuid,
  name text,
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  line_total numeric DEFAULT 0,
  CONSTRAINT retail_sale_items_pkey PRIMARY KEY (id),
  CONSTRAINT retail_sale_items_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.retail_sales(id) ON DELETE CASCADE,
  CONSTRAINT retail_sale_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.retail_products(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_retail_products_barcode ON public.retail_products (barcode);
CREATE INDEX IF NOT EXISTS idx_retail_sales_shift_id ON public.retail_sales (shift_id);
CREATE INDEX IF NOT EXISTS idx_retail_sale_items_sale_id ON public.retail_sale_items (sale_id);

-- =====================================================================
-- MICROFINANCE / LENDING (loan products, borrowers, loans, schedules)
-- =====================================================================
CREATE TABLE public.loan_products (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  interest_rate numeric DEFAULT 0,           -- ANNUAL %, e.g. 18
  interest_method text DEFAULT 'declining'::text, -- flat | declining
  default_term_months integer DEFAULT 12,
  fee_flat numeric DEFAULT 0,
  fee_percent numeric DEFAULT 0,
  currency text DEFAULT 'USD'::text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT loan_products_pkey PRIMARY KEY (id),
  CONSTRAINT loan_products_method_check CHECK (interest_method = ANY (ARRAY['flat','declining']))
);

CREATE TABLE public.borrowers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  phone text,
  national_id text,
  address text,
  occupation text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT borrowers_pkey PRIMARY KEY (id)
);

CREATE TABLE public.loans (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  loan_number text,
  borrower_id uuid,
  product_id uuid,
  principal numeric DEFAULT 0,
  interest_rate numeric DEFAULT 0,
  term_months integer DEFAULT 12,
  method text DEFAULT 'declining'::text,     -- flat | declining
  purpose text,
  officer_id uuid,
  disbursed_date date,
  status text DEFAULT 'pending'::text,       -- pending | active | closed | rejected | defaulted
  currency text DEFAULT 'USD'::text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT loans_pkey PRIMARY KEY (id),
  CONSTRAINT loans_borrower_id_fkey FOREIGN KEY (borrower_id) REFERENCES public.borrowers(id) ON DELETE SET NULL,
  CONSTRAINT loans_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.loan_products(id) ON DELETE SET NULL,
  CONSTRAINT loans_officer_id_fkey FOREIGN KEY (officer_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT loans_status_check CHECK (status = ANY (ARRAY['pending','active','closed','rejected','defaulted']))
);

CREATE TABLE public.loan_schedule (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  loan_id uuid NOT NULL,
  installment_no integer NOT NULL,
  due_date date,
  principal_due numeric DEFAULT 0,
  interest_due numeric DEFAULT 0,
  total_due numeric DEFAULT 0,
  paid_amount numeric DEFAULT 0,
  status text DEFAULT 'pending'::text,       -- pending | partial | paid
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT loan_schedule_pkey PRIMARY KEY (id),
  CONSTRAINT loan_schedule_loan_id_fkey FOREIGN KEY (loan_id) REFERENCES public.loans(id) ON DELETE CASCADE,
  CONSTRAINT loan_schedule_status_check CHECK (status = ANY (ARRAY['pending','partial','paid']))
);

CREATE TABLE public.loan_repayments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  loan_id uuid NOT NULL,
  date date DEFAULT CURRENT_DATE,
  amount numeric DEFAULT 0,
  method text DEFAULT 'cash'::text,
  received_by uuid,
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT loan_repayments_pkey PRIMARY KEY (id),
  CONSTRAINT loan_repayments_loan_id_fkey FOREIGN KEY (loan_id) REFERENCES public.loans(id) ON DELETE CASCADE,
  CONSTRAINT loan_repayments_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_loans_borrower_id ON public.loans (borrower_id);
CREATE INDEX IF NOT EXISTS idx_loan_schedule_loan_id ON public.loan_schedule (loan_id);
CREATE INDEX IF NOT EXISTS idx_loan_repayments_loan_id ON public.loan_repayments (loan_id);

-- =====================================================================
-- PROPERTY / RENTAL MANAGEMENT (units, tenants, leases, rent billing)
-- =====================================================================
CREATE TABLE public.rental_units (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,                        -- e.g. 'Apt 2B'
  building text,                             -- building / property name
  type text DEFAULT 'apartment'::text,       -- apartment | house | room | shop | office | land
  address text,
  bedrooms integer DEFAULT 0,
  bathrooms integer DEFAULT 0,
  size_sqm numeric,
  rent_amount numeric DEFAULT 0,
  deposit_amount numeric DEFAULT 0,
  currency text DEFAULT 'USD'::text,
  status text DEFAULT 'available'::text,     -- available | occupied | maintenance
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rental_units_pkey PRIMARY KEY (id),
  CONSTRAINT rental_units_status_check CHECK (status = ANY (ARRAY['available','occupied','maintenance']))
);

CREATE TABLE public.tenants (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  phone text,
  email text,
  national_id text,
  address text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT tenants_pkey PRIMARY KEY (id)
);

CREATE TABLE public.leases (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  lease_number text,
  unit_id uuid,
  tenant_id uuid,
  start_date date,
  end_date date,
  rent_amount numeric DEFAULT 0,
  deposit_amount numeric DEFAULT 0,
  billing_day integer DEFAULT 1,             -- day of month rent is due
  currency text DEFAULT 'USD'::text,
  status text DEFAULT 'active'::text,        -- active | ended | terminated
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT leases_pkey PRIMARY KEY (id),
  CONSTRAINT leases_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.rental_units(id) ON DELETE SET NULL,
  CONSTRAINT leases_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE SET NULL,
  CONSTRAINT leases_status_check CHECK (status = ANY (ARRAY['active','ended','terminated']))
);

CREATE TABLE public.rental_invoices (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_number text,
  lease_id uuid,
  period_month text,                         -- 'YYYY-MM'
  due_date date,
  amount numeric DEFAULT 0,
  amount_paid numeric DEFAULT 0,
  status text DEFAULT 'unpaid'::text,        -- unpaid | partial | paid
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rental_invoices_pkey PRIMARY KEY (id),
  CONSTRAINT rental_invoices_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES public.leases(id) ON DELETE CASCADE,
  CONSTRAINT rental_invoices_status_check CHECK (status = ANY (ARRAY['unpaid','partial','paid']))
);

CREATE TABLE public.rental_payments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_id uuid,
  lease_id uuid,
  date date DEFAULT CURRENT_DATE,
  amount numeric DEFAULT 0,
  method text DEFAULT 'cash'::text,
  received_by uuid,
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rental_payments_pkey PRIMARY KEY (id),
  CONSTRAINT rental_payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.rental_invoices(id) ON DELETE SET NULL,
  CONSTRAINT rental_payments_lease_id_fkey FOREIGN KEY (lease_id) REFERENCES public.leases(id) ON DELETE CASCADE,
  CONSTRAINT rental_payments_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.employees(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_leases_unit_id ON public.leases (unit_id);
CREATE INDEX IF NOT EXISTS idx_rental_invoices_lease_id ON public.rental_invoices (lease_id);
CREATE INDEX IF NOT EXISTS idx_rental_payments_invoice_id ON public.rental_payments (invoice_id);

-- =====================================================================
-- AI ASSISTANT + RAG  (per-silo, owner-configured)
-- The silo OWNER (Admin/Founder) picks a chat provider (Claude / OpenAI /
-- Gemini) and supplies API keys. Keys are NEVER stored in a readable column —
-- they live in Supabase Vault and are referenced by uuid. RAG embeddings are
-- ALWAYS produced by Gemini (Anthropic has no embeddings API, and a vector
-- store must use one embedding model), so a Gemini key is required for RAG
-- regardless of the chosen chat provider. All AI compute runs in the silo's
-- own edge functions; nothing lives at the Hub.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS supabase_vault;

-- Singleton configuration row (id is always true).
CREATE TABLE public.ai_config (
  id boolean NOT NULL DEFAULT true,
  enabled boolean DEFAULT false,               -- chat assistant on/off
  rag_enabled boolean DEFAULT false,           -- knowledge retrieval on/off
  tools_write_enabled boolean DEFAULT false,   -- allow assistant write actions (opt-in)
  chat_provider text DEFAULT 'claude',         -- claude | openai | gemini
  chat_model text,                             -- e.g. claude-opus-4-8 / gpt-4o / gemini-3-flash
  system_prompt text,
  temperature numeric DEFAULT 0.4,
  chat_key_id uuid,                            -- vault secret id (chat provider key)
  embedding_key_id uuid,                       -- vault secret id (Gemini key for RAG)
  embedding_model text DEFAULT 'text-embedding-004',  -- Gemini, 768-dim
  updated_by uuid,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ai_config_pkey PRIMARY KEY (id),
  CONSTRAINT ai_config_singleton CHECK (id = true),
  CONSTRAINT ai_config_provider_check CHECK (chat_provider = ANY (ARRAY['claude','openai','gemini']))
);

-- ---------------------------------------------------------------------
-- E-invoice configuration (per-silo). Jurisdiction/registration values for
-- the UBL 2.1 export (Cambodia CamInvoice / GDT by default). Singleton row.
-- ---------------------------------------------------------------------
CREATE TABLE public.einvoice_config (
  id boolean NOT NULL DEFAULT true,
  enabled boolean DEFAULT true,                        -- show the UBL export
  customization_id text DEFAULT 'KH-UBL-2.1',          -- GDT CustomizationID
  profile_id text DEFAULT 'CamInvoice:1.0',            -- GDT ProfileID
  tax_scheme text DEFAULT 'VAT',
  default_vat_rate numeric DEFAULT 10,
  tax_currency text,                                   -- null = same as document currency
  default_invoice_type text DEFAULT '388',             -- 388 tax / 380 commercial / 381 CN / 383 DN
  country_code text DEFAULT 'KH',
  supplier_tin text,                                   -- override; else the default business profile Tax ID
  updated_by uuid,
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT einvoice_config_pkey PRIMARY KEY (id),
  CONSTRAINT einvoice_config_singleton CHECK (id = true)
);

-- Owner-only secret management. Raw keys go straight into Vault; only the
-- opaque secret uuid is stored on ai_config. p_kind is 'chat' or 'embedding'.
CREATE OR REPLACE FUNCTION public.ai_set_secret(p_kind text, p_value text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin_or_founder() THEN RAISE EXCEPTION 'Only the workspace owner can configure AI'; END IF;
  IF p_value IS NULL OR length(trim(p_value)) = 0 THEN RAISE EXCEPTION 'Key value required'; END IF;
  INSERT INTO ai_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

  IF p_kind = 'chat' THEN
    SELECT chat_key_id INTO v_id FROM ai_config WHERE id;
    IF v_id IS NULL THEN
      v_id := vault.create_secret(p_value, 'ai_chat_key', 'Silo AI chat provider key');
      UPDATE ai_config SET chat_key_id = v_id, updated_by = current_employee_id(), updated_at = now() WHERE id;
    ELSE
      PERFORM vault.update_secret(v_id, p_value);
      UPDATE ai_config SET updated_by = current_employee_id(), updated_at = now() WHERE id;
    END IF;
  ELSIF p_kind = 'embedding' THEN
    SELECT embedding_key_id INTO v_id FROM ai_config WHERE id;
    IF v_id IS NULL THEN
      v_id := vault.create_secret(p_value, 'ai_embedding_key', 'Silo Gemini embedding key');
      UPDATE ai_config SET embedding_key_id = v_id, updated_by = current_employee_id(), updated_at = now() WHERE id;
    ELSE
      PERFORM vault.update_secret(v_id, p_value);
      UPDATE ai_config SET updated_by = current_employee_id(), updated_at = now() WHERE id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown secret kind: %', p_kind;
  END IF;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.ai_set_secret(text, text) TO authenticated;

-- Owner-only: clear a key (removes the vault secret and the reference).
CREATE OR REPLACE FUNCTION public.ai_clear_secret(p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF NOT is_admin_or_founder() THEN RAISE EXCEPTION 'Only the workspace owner can configure AI'; END IF;
  IF p_kind = 'chat' THEN
    SELECT chat_key_id INTO v_id FROM ai_config WHERE id;
    UPDATE ai_config SET chat_key_id = NULL, updated_by = current_employee_id(), updated_at = now() WHERE id;
  ELSIF p_kind = 'embedding' THEN
    SELECT embedding_key_id INTO v_id FROM ai_config WHERE id;
    UPDATE ai_config SET embedding_key_id = NULL, updated_by = current_employee_id(), updated_at = now() WHERE id;
  ELSE
    RAISE EXCEPTION 'Unknown secret kind: %', p_kind;
  END IF;
  IF v_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id = v_id; END IF;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.ai_clear_secret(text) TO authenticated;

-- ---- Knowledge base (RAG) ----
-- Source documents (articles, the user manual, or files uploaded to Storage).
CREATE TABLE public.kb_documents (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text,
  source_type text DEFAULT 'article'::text,    -- article | manual | file | note
  source_ref text,                             -- storage object path, or source row id
  mime_type text,
  status text DEFAULT 'pending'::text,         -- pending | processing | indexed | failed
  chunk_count integer DEFAULT 0,
  error text,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now(),
  indexed_at timestamp with time zone,
  CONSTRAINT kb_documents_pkey PRIMARY KEY (id),
  CONSTRAINT kb_documents_status_check CHECK (status = ANY (ARRAY['pending','processing','indexed','failed']))
);

-- Embedded chunks. vector(768) matches Gemini text-embedding-004.
CREATE TABLE public.kb_chunks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  document_id uuid,
  chunk_index integer DEFAULT 0,
  content text NOT NULL,
  token_count integer,
  embedding vector(768),
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT kb_chunks_pkey PRIMARY KEY (id),
  CONSTRAINT kb_chunks_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.kb_documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_document_id ON public.kb_chunks (document_id);
CREATE INDEX IF NOT EXISTS idx_kb_chunks_embedding ON public.kb_chunks USING hnsw (embedding vector_cosine_ops);

-- Similarity search, gated by is_employee(). Called by the ai-chat edge
-- function (which passes the caller's identity) to retrieve context.
CREATE OR REPLACE FUNCTION public.match_kb_chunks(query_embedding vector(768), match_count integer DEFAULT 6, min_similarity double precision DEFAULT 0.5)
 RETURNS TABLE(id uuid, document_id uuid, title text, content text, similarity double precision)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT c.id, c.document_id, d.title, c.content,
         1 - (c.embedding <=> query_embedding) AS similarity
  FROM kb_chunks c
  JOIN kb_documents d ON d.id = c.document_id
  WHERE is_employee()
    AND c.embedding IS NOT NULL
    AND 1 - (c.embedding <=> query_embedding) >= min_similarity
  ORDER BY c.embedding <=> query_embedding
  LIMIT match_count;
$function$;
GRANT EXECUTE ON FUNCTION public.match_kb_chunks(vector, integer, double precision) TO authenticated;

-- Private bucket for documents the owner feeds the assistant. Existing media
-- buckets can also be ingested; this one is dedicated to AI source material.
INSERT INTO storage.buckets (id, name, public)
VALUES ('kb-sources', 'kb-sources', false)
ON CONFLICT (id) DO NOTHING;

-- Service-role-only bridge for edge functions to read a decrypted key from
-- Vault. NOT callable by authenticated/anon — only the ai-* edge functions
-- (which run with the service role) may decrypt. p_kind is 'chat' or 'embedding'.
CREATE OR REPLACE FUNCTION public.ai_get_secret(p_kind text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_val text;
BEGIN
  IF p_kind = 'chat' THEN
    SELECT chat_key_id INTO v_id FROM ai_config WHERE id;
  ELSIF p_kind = 'embedding' THEN
    SELECT embedding_key_id INTO v_id FROM ai_config WHERE id;
  ELSE
    RAISE EXCEPTION 'Unknown secret kind: %', p_kind;
  END IF;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  SELECT decrypted_secret INTO v_val FROM vault.decrypted_secrets WHERE id = v_id;
  RETURN v_val;
END;
$function$;
REVOKE ALL ON FUNCTION public.ai_get_secret(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_get_secret(text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_get_secret(text) TO service_role;
