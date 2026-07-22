-- =====================================================================
-- KAREYA SILO — Row Level Security
-- ---------------------------------------------------------------------
-- One Silo == one business, so access is gated simply on "is the caller
-- an employee of this business?" via the local `employees` roster.
-- `auth.uid()` is the Hub user id carried in the minted JWT.
-- =====================================================================

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.office_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payroll_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_forms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ticket_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- ---- employees ---------------------------------------------------------
-- Bootstrapping: a user may insert their OWN roster row on first entry.
-- The authenticate-hub-user edge function also provisions/updates this
-- row from the authoritative Hub role (service role bypasses RLS), so
-- the self-insert path is a fallback.
CREATE POLICY "Insert own employee row" ON public.employees FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "View co-workers" ON public.employees FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage employees" ON public.employees FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

-- ---- departments / roles ----------------------------------------------
CREATE POLICY "View departments" ON public.departments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage departments" ON public.departments FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

CREATE POLICY "View roles" ON public.roles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage roles" ON public.roles FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- ---- attendance --------------------------------------------------------
CREATE POLICY "View attendance" ON public.attendance_records FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Insert own attendance" ON public.attendance_records FOR INSERT TO authenticated WITH CHECK (employee_id = current_employee_id());
CREATE POLICY "Update attendance" ON public.attendance_records FOR UPDATE TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Delete attendance" ON public.attendance_records FOR DELETE TO authenticated USING (is_hr_or_admin());

-- ---- office config / holidays -----------------------------------------
CREATE POLICY "View office config" ON public.office_configs FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage office config" ON public.office_configs FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

CREATE POLICY "View holidays" ON public.holidays FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage holidays" ON public.holidays FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- ---- business profiles -------------------------------------------------
CREATE POLICY "View business profiles" ON public.business_profiles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage business profiles" ON public.business_profiles FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- ---- projects / tasks --------------------------------------------------
CREATE POLICY "View projects" ON public.projects FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage projects" ON public.projects FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View tasks" ON public.tasks FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tasks" ON public.tasks FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- documents ---------------------------------------------------------
CREATE POLICY "View templates" ON public.document_templates FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage templates" ON public.document_templates FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

CREATE POLICY "View documents" ON public.document_requests FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage documents" ON public.document_requests FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- calendar ----------------------------------------------------------
CREATE POLICY "View events" ON public.calendar_events FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Create events" ON public.calendar_events FOR INSERT TO authenticated WITH CHECK (is_employee());
CREATE POLICY "Update events" ON public.calendar_events FOR UPDATE TO authenticated USING (creator_id = current_employee_id() OR is_admin_or_founder());
CREATE POLICY "Delete events" ON public.calendar_events FOR DELETE TO authenticated USING (creator_id = current_employee_id() OR is_admin_or_founder());

-- ---- accounting --------------------------------------------------------
CREATE POLICY "View products" ON public.products_services FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage products" ON public.products_services FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Sales Lead'])) WITH CHECK (has_any_role(ARRAY['Accountant','Sales Lead']));

CREATE POLICY "View clients" ON public.clients FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage clients" ON public.clients FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View client activities" ON public.client_activities FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage client activities" ON public.client_activities FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View invoices" ON public.invoices FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage invoices" ON public.invoices FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View invoice items" ON public.invoice_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage invoice items" ON public.invoice_items FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View payroll" ON public.payroll_records FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage payroll" ON public.payroll_records FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

-- ---- sales -------------------------------------------------------------
CREATE POLICY "View deals" ON public.deals FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage deals" ON public.deals FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- support -----------------------------------------------------------
CREATE POLICY "View support forms" ON public.support_forms FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage support forms" ON public.support_forms FOR ALL TO authenticated USING (has_any_role(ARRAY['Support'])) WITH CHECK (has_any_role(ARRAY['Support']));

CREATE POLICY "View tickets" ON public.tickets FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tickets" ON public.tickets FOR ALL TO authenticated USING (has_any_role(ARRAY['Support'])) WITH CHECK (has_any_role(ARRAY['Support']));

CREATE POLICY "View ticket activities" ON public.ticket_activities FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage ticket activities" ON public.ticket_activities FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- inventory ---------------------------------------------------------
CREATE POLICY "View assets" ON public.assets FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage assets" ON public.assets FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- notifications -----------------------------------------------------
CREATE POLICY "View own notifications" ON public.notifications FOR SELECT TO authenticated USING (auth.uid() = recipient_id);
CREATE POLICY "Insert notifications" ON public.notifications FOR INSERT TO authenticated WITH CHECK (is_employee());
CREATE POLICY "Update own notifications" ON public.notifications FOR UPDATE TO authenticated USING (auth.uid() = recipient_id);
