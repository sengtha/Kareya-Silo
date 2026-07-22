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
    ('1500', 'Accumulated Depreciation', 'asset', 'contra', false),
    ('2000', 'Accounts Payable', 'liability', 'payable', true),
    ('2100', 'Tax Payable', 'liability', 'tax', true),
    ('3000', 'Owner Equity', 'equity', 'equity', true),
    ('3100', 'Retained Earnings', 'equity', 'retained', true),
    ('4000', 'Sales Revenue', 'income', 'sales', true),
    ('4100', 'Other Income', 'income', 'other', false),
    ('5000', 'Cost of Goods Sold', 'expense', 'cogs', false),
    ('5100', 'Salaries & Wages', 'expense', 'payroll', true),
    ('5200', 'Rent', 'expense', 'operating', false),
    ('5300', 'Utilities', 'expense', 'operating', false),
    ('5400', 'Office Supplies', 'expense', 'operating', false),
    ('5500', 'Depreciation Expense', 'expense', 'operating', false),
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
