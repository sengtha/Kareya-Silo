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
    SELECT 1 FROM employees
    WHERE (user_id = auth.uid() OR email = (auth.jwt() ->> 'email'))
      AND (roles @> ARRAY['Admin']::text[] OR roles @> ARRAY['Founder']::text[])
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_hr_or_admin()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM employees
    WHERE (user_id = auth.uid() OR email = (auth.jwt() ->> 'email'))
      AND (
        roles @> ARRAY['Admin']::text[] OR
        roles @> ARRAY['Founder']::text[] OR
        roles @> ARRAY['HR']::text[] OR
        roles @> ARRAY['HR Manager']::text[]
      )
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
    SELECT 1 FROM employees
    WHERE (user_id = auth.uid() OR email = (auth.jwt() ->> 'email'))
      AND (
        roles @> ARRAY['Admin']::text[] OR
        roles @> ARRAY['Founder']::text[] OR
        roles && required_roles
      )
  );
$function$;

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

CREATE TABLE public.market_announcements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  title text NOT NULL,
  type text DEFAULT 'news'::text,
  content text,
  date date DEFAULT CURRENT_DATE,
  is_public boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT market_announcements_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_candidates_job_id ON public.candidates (job_id);
