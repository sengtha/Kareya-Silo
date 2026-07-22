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
-- Self-insert fallback: a user may create only their OWN row, tied to their
-- JWT email, and only as Staff. Elevated roles must come from the service-role
-- edge function or an admin — this closes the self-escalation-to-Admin hole.
CREATE POLICY "Insert own employee row" ON public.employees FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id AND email = (auth.jwt() ->> 'email') AND (roles IS NULL OR roles <@ ARRAY['Staff']::text[]));
CREATE POLICY "View co-workers" ON public.employees FOR SELECT TO authenticated USING (is_employee());
-- Admins/Founders have full control over employee rows including role grants.
CREATE POLICY "Admins manage employees" ON public.employees FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());
-- HR may manage employees but may NEVER create or leave a row holding Admin/Founder
-- (separation of duties — HR cannot mint admins or self-promote).
CREATE POLICY "HR manage non-privileged employees" ON public.employees FOR ALL TO authenticated
  USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin() AND roles_are_unprivileged(roles));

-- ---- departments / roles ----------------------------------------------
CREATE POLICY "View departments" ON public.departments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage departments" ON public.departments FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

CREATE POLICY "View roles" ON public.roles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage roles" ON public.roles FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- ---- attendance --------------------------------------------------------
CREATE POLICY "View attendance" ON public.attendance_records FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
-- Employees do NOT insert/update attendance directly. Check-in/out go through
-- the clock_in()/clock_out() SECURITY DEFINER RPCs (server time + computed
-- status, one open record/day). Only HR/Admin may edit rows (corrections);
-- everyone else files a correction via the document-request workflow.
CREATE POLICY "Update attendance" ON public.attendance_records FOR UPDATE TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
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
-- Employees may file only their OWN request. All approval/reject/return/resubmit
-- state transitions are performed exclusively by process_document() (SECURITY
-- DEFINER), which enforces the approver's role and separation of duties. Direct
-- table UPDATEs are reserved for admins (manual rescue of stuck documents).
CREATE POLICY "Create own document" ON public.document_requests FOR INSERT TO authenticated WITH CHECK (requester_id = current_employee_id());
CREATE POLICY "Admins update documents" ON public.document_requests FOR UPDATE TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());
CREATE POLICY "Delete own or admin documents" ON public.document_requests FOR DELETE TO authenticated USING (requester_id = current_employee_id() OR is_admin_or_founder());

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

-- ---- careers & announcements ------------------------------------------
ALTER TABLE public.job_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_announcements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View jobs" ON public.job_postings FOR SELECT TO authenticated USING (is_employee() OR is_public = true);
CREATE POLICY "Manage jobs" ON public.job_postings FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

CREATE POLICY "View candidates" ON public.candidates FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage candidates" ON public.candidates FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

CREATE POLICY "View announcements" ON public.market_announcements FOR SELECT TO authenticated USING (is_employee() OR is_public = true);
CREATE POLICY "Manage announcements" ON public.market_announcements FOR ALL TO authenticated USING (has_any_role(ARRAY['Marketing'])) WITH CHECK (has_any_role(ARRAY['Marketing']));

-- =====================================================================
-- Double-entry accounting — sensitive; gated to Accountant/Admin/Founder.
-- has_any_role(['Accountant']) returns true for Admin/Founder too.
-- =====================================================================
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View accounts" ON public.chart_of_accounts FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage accounts" ON public.chart_of_accounts FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View tax rates" ON public.tax_rates FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tax rates" ON public.tax_rates FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View vendors" ON public.vendors FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage vendors" ON public.vendors FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View bills" ON public.bills FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage bills" ON public.bills FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View payments" ON public.payments FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage payments" ON public.payments FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View journal" ON public.journal_entries FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage journal" ON public.journal_entries FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View journal lines" ON public.journal_lines FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage journal lines" ON public.journal_lines FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

-- ---- leave management --------------------------------------------------
ALTER TABLE public.leave_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View leave types" ON public.leave_types FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage leave types" ON public.leave_types FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

CREATE POLICY "View leave requests" ON public.leave_requests FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Create own leave request" ON public.leave_requests FOR INSERT TO authenticated WITH CHECK (employee_id = current_employee_id());
CREATE POLICY "Update leave requests" ON public.leave_requests FOR UPDATE TO authenticated USING (is_hr_or_admin() OR employee_id = current_employee_id());
CREATE POLICY "Delete own leave request" ON public.leave_requests FOR DELETE TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());

-- ---- HR: payslips / performance / documents ---------------------------
ALTER TABLE public.payslips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.performance_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View payslips" ON public.payslips FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Accountant','HR']));
CREATE POLICY "Manage payslips" ON public.payslips FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

CREATE POLICY "View reviews" ON public.performance_reviews FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Manage reviews" ON public.performance_reviews FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

CREATE POLICY "View emp documents" ON public.employee_documents FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Manage emp documents" ON public.employee_documents FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

-- ---- sales: quotes -----------------------------------------------------
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View quotes" ON public.quotes FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage quotes" ON public.quotes FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());
CREATE POLICY "View quote items" ON public.quote_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage quote items" ON public.quote_items FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- inventory: stock items / movements -------------------------------
ALTER TABLE public.stock_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View stock items" ON public.stock_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage stock items" ON public.stock_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

CREATE POLICY "View stock movements" ON public.stock_movements FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage stock movements" ON public.stock_movements FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

-- ---- support: knowledge base ------------------------------------------
ALTER TABLE public.kb_articles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View kb articles" ON public.kb_articles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage kb articles" ON public.kb_articles FOR ALL TO authenticated USING (has_any_role(ARRAY['Support'])) WITH CHECK (has_any_role(ARRAY['Support']));

-- ---- projects: milestones / time entries ------------------------------
ALTER TABLE public.project_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.time_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View milestones" ON public.project_milestones FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage milestones" ON public.project_milestones FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- Employees see/log their own time; managers & admins see all
CREATE POLICY "View time entries" ON public.time_entries FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "Log own time" ON public.time_entries FOR INSERT TO authenticated WITH CHECK (employee_id = current_employee_id() OR has_any_role(ARRAY['Manager']));
CREATE POLICY "Update time entries" ON public.time_entries FOR UPDATE TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Manager']));
CREATE POLICY "Delete time entries" ON public.time_entries FOR DELETE TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Manager']));

-- ---- marketing: campaigns ---------------------------------------------
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View campaigns" ON public.campaigns FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage campaigns" ON public.campaigns FOR ALL TO authenticated USING (has_any_role(ARRAY['Marketing'])) WITH CHECK (has_any_role(ARRAY['Marketing']));

-- ---- procurement: purchase orders -------------------------------------
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View purchase orders" ON public.purchase_orders FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage purchase orders" ON public.purchase_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "View PO items" ON public.purchase_order_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage PO items" ON public.purchase_order_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

-- ---- expense claims ---------------------------------------------------
ALTER TABLE public.expense_claims ENABLE ROW LEVEL SECURITY;

-- Employees see and file their own claims; Accountant/Manager see & manage all
CREATE POLICY "View expense claims" ON public.expense_claims FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "File own expense claim" ON public.expense_claims FOR INSERT TO authenticated WITH CHECK (employee_id = current_employee_id() OR has_any_role(ARRAY['Accountant','Manager']));
CREATE POLICY "Update expense claims" ON public.expense_claims FOR UPDATE TO authenticated USING (has_any_role(ARRAY['Accountant','Manager']) OR (employee_id = current_employee_id() AND status = 'pending'));
CREATE POLICY "Delete own expense claim" ON public.expense_claims FOR DELETE TO authenticated USING ((employee_id = current_employee_id() AND status = 'pending') OR has_any_role(ARRAY['Accountant']));

-- ---- recurring invoices -----------------------------------------------
ALTER TABLE public.recurring_invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View recurring" ON public.recurring_invoices FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant','Sales Lead']));
CREATE POLICY "Manage recurring" ON public.recurring_invoices FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

-- ---- fixed-asset depreciation -----------------------------------------
ALTER TABLE public.depreciation_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View depreciation" ON public.depreciation_entries FOR SELECT TO authenticated USING (has_any_role(ARRAY['Accountant']));
CREATE POLICY "Manage depreciation" ON public.depreciation_entries FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

-- ---- multi-currency ---------------------------------------------------
ALTER TABLE public.currencies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View currencies" ON public.currencies FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage currencies" ON public.currencies FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant'])) WITH CHECK (has_any_role(ARRAY['Accountant']));

-- ---- manufacturing: BOM & work orders ---------------------------------
ALTER TABLE public.bills_of_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bom_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View boms" ON public.bills_of_materials FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage boms" ON public.bills_of_materials FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View bom items" ON public.bom_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage bom items" ON public.bom_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View work orders" ON public.work_orders FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage work orders" ON public.work_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));

-- ---- point of sale ----------------------------------------------------
ALTER TABLE public.pos_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View pos sales" ON public.pos_sales FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Create pos sales" ON public.pos_sales FOR INSERT TO authenticated WITH CHECK (is_employee());
CREATE POLICY "Manage pos sales" ON public.pos_sales FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

-- ---- audit log (append-only; admins read) -----------------------------
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Write audit" ON public.audit_log FOR INSERT TO authenticated WITH CHECK (is_employee());
CREATE POLICY "View audit" ON public.audit_log FOR SELECT TO authenticated USING (is_admin_or_founder() OR has_any_role(ARRAY['Accountant']));

-- ---- fleet management --------------------------------------------------
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fuel_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.maintenance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trips ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View vehicles" ON public.vehicles FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage vehicles" ON public.vehicles FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View fuel" ON public.fuel_logs FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage fuel" ON public.fuel_logs FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());
CREATE POLICY "View maintenance" ON public.maintenance_records FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage maintenance" ON public.maintenance_records FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View trips" ON public.trips FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage trips" ON public.trips FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- sales orders & fulfillment ---------------------------------------
ALTER TABLE public.sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View sales orders" ON public.sales_orders FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage sales orders" ON public.sales_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Lead','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Lead','Accountant','Manager']));
CREATE POLICY "View SO items" ON public.sales_order_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage SO items" ON public.sales_order_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Sales Lead','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Sales Lead','Accountant','Manager']));

-- ---- warehouses & transfers -------------------------------------------
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View warehouses" ON public.warehouses FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage warehouses" ON public.warehouses FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View stock levels" ON public.stock_levels FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage stock levels" ON public.stock_levels FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View stock transfers" ON public.stock_transfers FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage stock transfers" ON public.stock_transfers FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));

-- ---- shipments / deliveries -------------------------------------------
ALTER TABLE public.shipments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View shipments" ON public.shipments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage shipments" ON public.shipments FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());

-- ---- traceability: lots / serials / containers ------------------------
ALTER TABLE public.stock_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.serial_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.containers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.container_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View lots" ON public.stock_lots FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lots" ON public.stock_lots FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View serials" ON public.serial_units FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage serials" ON public.serial_units FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View containers" ON public.containers FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage containers" ON public.containers FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));
CREATE POLICY "View container items" ON public.container_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage container items" ON public.container_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager','Accountant'])) WITH CHECK (has_any_role(ARRAY['Manager','Accountant']));

-- ---- LMS: courses / lessons / enrollments -----------------------------
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_lessons ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_enrollments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View courses" ON public.courses FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage courses" ON public.courses FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View lessons" ON public.course_lessons FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lessons" ON public.course_lessons FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());

-- Employees enroll and drive their own progress; HR sees & manages all.
CREATE POLICY "View enrollments" ON public.course_enrollments FOR SELECT TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Enrol self" ON public.course_enrollments FOR INSERT TO authenticated WITH CHECK (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Update own enrollment" ON public.course_enrollments FOR UPDATE TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());
CREATE POLICY "Delete own enrollment" ON public.course_enrollments FOR DELETE TO authenticated USING (employee_id = current_employee_id() OR is_hr_or_admin());

-- ---- academy (student information system) -----------------------------
ALTER TABLE public.academic_terms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.academic_programs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.class_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.section_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assessment_grades ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.student_attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fee_structures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.student_invoices ENABLE ROW LEVEL SECURITY;

-- Registrar/admin domain: view for all staff, manage by HR/Admin.
CREATE POLICY "View terms" ON public.academic_terms FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage terms" ON public.academic_terms FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View programs" ON public.academic_programs FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage programs" ON public.academic_programs FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View subjects" ON public.subjects FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage subjects" ON public.subjects FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View students" ON public.students FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage students" ON public.students FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View fee structures" ON public.fee_structures FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage fee structures" ON public.fee_structures FOR ALL TO authenticated USING (is_hr_or_admin()) WITH CHECK (is_hr_or_admin());
CREATE POLICY "View student invoices" ON public.student_invoices FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage student invoices" ON public.student_invoices FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Accountant']) OR is_hr_or_admin());

-- Teaching domain: teachers (and HR/Admin) manage their classes, grades & attendance.
CREATE POLICY "View sections" ON public.class_sections FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage sections" ON public.class_sections FOR ALL TO authenticated USING (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin());
CREATE POLICY "View sec enrollments" ON public.section_enrollments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage sec enrollments" ON public.section_enrollments FOR ALL TO authenticated USING (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin());
CREATE POLICY "View assessments" ON public.assessments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage assessments" ON public.assessments FOR ALL TO authenticated USING (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin());
CREATE POLICY "View grades" ON public.assessment_grades FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grades" ON public.assessment_grades FOR ALL TO authenticated USING (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin());
CREATE POLICY "View student attendance" ON public.student_attendance FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage student attendance" ON public.student_attendance FOR ALL TO authenticated USING (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin()) WITH CHECK (has_any_role(ARRAY['Teacher']) OR is_hr_or_admin());

-- ---- LIMS (laboratory) ------------------------------------------------
ALTER TABLE public.lab_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_instruments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_qc_runs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View lab tests" ON public.lab_tests FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lab tests" ON public.lab_tests FOR ALL TO authenticated USING (has_any_role(ARRAY['Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Lab','Manager']));
CREATE POLICY "View lab samples" ON public.lab_samples FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lab samples" ON public.lab_samples FOR ALL TO authenticated USING (has_any_role(ARRAY['Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Lab','Manager']));
CREATE POLICY "View lab orders" ON public.lab_orders FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lab orders" ON public.lab_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Lab','Manager']));
CREATE POLICY "View lab instruments" ON public.lab_instruments FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lab instruments" ON public.lab_instruments FOR ALL TO authenticated USING (has_any_role(ARRAY['Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Lab','Manager']));
CREATE POLICY "View lab qc" ON public.lab_qc_runs FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage lab qc" ON public.lab_qc_runs FOR ALL TO authenticated USING (has_any_role(ARRAY['Lab','Manager'])) WITH CHECK (has_any_role(ARRAY['Lab','Manager']));

-- ---- grants / research management -------------------------------------
ALTER TABLE public.funders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grant_budget_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grant_milestones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grant_disbursements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grant_expenses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View funders" ON public.funders FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage funders" ON public.funders FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));
CREATE POLICY "View grants" ON public.grants FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grants" ON public.grants FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));
CREATE POLICY "View grant budget" ON public.grant_budget_lines FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grant budget" ON public.grant_budget_lines FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));
CREATE POLICY "View grant milestones" ON public.grant_milestones FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grant milestones" ON public.grant_milestones FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));
CREATE POLICY "View grant disbursements" ON public.grant_disbursements FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grant disbursements" ON public.grant_disbursements FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));
CREATE POLICY "View grant expenses" ON public.grant_expenses FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage grant expenses" ON public.grant_expenses FOR ALL TO authenticated USING (has_any_role(ARRAY['Grants','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Grants','Accountant','Manager']));

-- =====================================================================
-- CLINIC EMR — PHI restricted to clinical + reception + manager roles
-- =====================================================================
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinic_appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinic_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinic_invoice_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View patients" ON public.patients FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Accountant','Manager']));
CREATE POLICY "Manage patients" ON public.patients FOR ALL TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Manager'])) WITH CHECK (has_any_role(ARRAY['Clinician','Nurse','Reception','Manager']));
CREATE POLICY "View clinic appts" ON public.clinic_appointments FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Manager']));
CREATE POLICY "Manage clinic appts" ON public.clinic_appointments FOR ALL TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Manager'])) WITH CHECK (has_any_role(ARRAY['Clinician','Nurse','Reception','Manager']));
CREATE POLICY "View encounters" ON public.encounters FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Manager']));
CREATE POLICY "Manage encounters" ON public.encounters FOR ALL TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Manager'])) WITH CHECK (has_any_role(ARRAY['Clinician','Nurse','Manager']));
CREATE POLICY "View prescriptions" ON public.prescriptions FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Manager']));
CREATE POLICY "Manage prescriptions" ON public.prescriptions FOR ALL TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Manager'])) WITH CHECK (has_any_role(ARRAY['Clinician','Nurse','Manager']));
CREATE POLICY "View clinic invoices" ON public.clinic_invoices FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Accountant','Manager']));
CREATE POLICY "Manage clinic invoices" ON public.clinic_invoices FOR ALL TO authenticated USING (has_any_role(ARRAY['Reception','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Reception','Accountant','Manager']));
CREATE POLICY "View clinic invoice items" ON public.clinic_invoice_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Clinician','Nurse','Reception','Accountant','Manager']));
CREATE POLICY "Manage clinic invoice items" ON public.clinic_invoice_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Reception','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Reception','Accountant','Manager']));

-- =====================================================================
-- HOTEL PMS
-- =====================================================================
ALTER TABLE public.room_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hotel_guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.folio_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.housekeeping_tasks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View room types" ON public.room_types FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage room types" ON public.room_types FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Manager']));
CREATE POLICY "View rooms" ON public.rooms FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage rooms" ON public.rooms FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Housekeeping','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Housekeeping','Manager']));
CREATE POLICY "View hotel guests" ON public.hotel_guests FOR SELECT TO authenticated USING (has_any_role(ARRAY['FrontDesk','Accountant','Manager']));
CREATE POLICY "Manage hotel guests" ON public.hotel_guests FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Manager']));
CREATE POLICY "View reservations" ON public.reservations FOR SELECT TO authenticated USING (has_any_role(ARRAY['FrontDesk','Housekeeping','Accountant','Manager']));
CREATE POLICY "Manage reservations" ON public.reservations FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Manager']));
CREATE POLICY "View folio charges" ON public.folio_charges FOR SELECT TO authenticated USING (has_any_role(ARRAY['FrontDesk','Accountant','Manager']));
CREATE POLICY "Manage folio charges" ON public.folio_charges FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Accountant','Manager']));
CREATE POLICY "View housekeeping" ON public.housekeeping_tasks FOR SELECT TO authenticated USING (has_any_role(ARRAY['FrontDesk','Housekeeping','Manager']));
CREATE POLICY "Manage housekeeping" ON public.housekeeping_tasks FOR ALL TO authenticated USING (has_any_role(ARRAY['FrontDesk','Housekeeping','Manager'])) WITH CHECK (has_any_role(ARRAY['FrontDesk','Housekeeping','Manager']));

-- =====================================================================
-- RESTAURANT POS + KDS
-- =====================================================================
ALTER TABLE public.menu_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restaurant_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View menu categories" ON public.menu_categories FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage menu categories" ON public.menu_categories FOR ALL TO authenticated USING (has_any_role(ARRAY['Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Cashier','Manager']));
CREATE POLICY "View menu items" ON public.menu_items FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage menu items" ON public.menu_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Cashier','Manager']));
CREATE POLICY "View tables" ON public.restaurant_tables FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage tables" ON public.restaurant_tables FOR ALL TO authenticated USING (has_any_role(ARRAY['Waiter','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Waiter','Cashier','Manager']));
CREATE POLICY "View restaurant orders" ON public.restaurant_orders FOR SELECT TO authenticated USING (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Accountant','Manager']));
CREATE POLICY "Manage restaurant orders" ON public.restaurant_orders FOR ALL TO authenticated USING (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Manager']));
CREATE POLICY "View order items" ON public.order_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Accountant','Manager']));
CREATE POLICY "Manage order items" ON public.order_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Waiter','Kitchen','Cashier','Manager']));

-- ---- pharmacy ----------------------------------------------------------
ALTER TABLE public.pharmacy_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_sale_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View pharmacy products" ON public.pharmacy_products FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage pharmacy products" ON public.pharmacy_products FOR ALL TO authenticated USING (has_any_role(ARRAY['Pharmacist','Manager'])) WITH CHECK (has_any_role(ARRAY['Pharmacist','Manager']));
CREATE POLICY "View pharmacy batches" ON public.pharmacy_batches FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pharmacist','Cashier','Accountant','Manager']));
CREATE POLICY "Manage pharmacy batches" ON public.pharmacy_batches FOR ALL TO authenticated USING (has_any_role(ARRAY['Pharmacist','Manager'])) WITH CHECK (has_any_role(ARRAY['Pharmacist','Manager']));
CREATE POLICY "View pharmacy sales" ON public.pharmacy_sales FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pharmacist','Cashier','Accountant','Manager']));
CREATE POLICY "Manage pharmacy sales" ON public.pharmacy_sales FOR ALL TO authenticated USING (has_any_role(ARRAY['Pharmacist','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pharmacist','Cashier','Manager']));
CREATE POLICY "View pharmacy sale items" ON public.pharmacy_sale_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Pharmacist','Cashier','Accountant','Manager']));
CREATE POLICY "Manage pharmacy sale items" ON public.pharmacy_sale_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Pharmacist','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Pharmacist','Cashier','Manager']));

-- =====================================================================
-- AI ASSISTANT + RAG
-- ai_config: every employee may READ (to know if the assistant is on, which
-- provider/model) — the key columns are opaque vault uuids, not usable secrets.
-- Only the owner (Admin/Founder) may change settings; keys are set exclusively
-- through ai_set_secret()/ai_clear_secret(), never by writing the column.
-- =====================================================================
ALTER TABLE public.ai_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kb_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kb_chunks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View ai config" ON public.ai_config FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Owner manages ai config" ON public.ai_config FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- einvoice_config: employees may read (invoice screens need the values to build
-- the UBL export); only Admin/Founder may change the registration identifiers.
ALTER TABLE public.einvoice_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "View einvoice config" ON public.einvoice_config FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Owner manages einvoice config" ON public.einvoice_config FOR ALL TO authenticated USING (is_admin_or_founder()) WITH CHECK (is_admin_or_founder());

-- Knowledge base: all employees can read; Support/Manager (and owners) curate.
-- Ingestion normally runs via the edge function (service role), which bypasses RLS.
CREATE POLICY "View kb documents" ON public.kb_documents FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage kb documents" ON public.kb_documents FOR ALL TO authenticated USING (has_any_role(ARRAY['Support','Manager'])) WITH CHECK (has_any_role(ARRAY['Support','Manager']));
CREATE POLICY "View kb chunks" ON public.kb_chunks FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage kb chunks" ON public.kb_chunks FOR ALL TO authenticated USING (has_any_role(ARRAY['Support','Manager'])) WITH CHECK (has_any_role(ARRAY['Support','Manager']));

-- =====================================================================
-- STORAGE — per-silo media. Objects are readable/writable only by employees
-- of this silo. 'kb-sources' holds AI source documents (owner-curated);
-- 'silo-media' is the general media bucket (rename to your bucket if different).
-- =====================================================================
CREATE POLICY "Employees read kb-sources" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'kb-sources' AND is_employee());
CREATE POLICY "Owners/curators write kb-sources" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));
CREATE POLICY "Owners/curators update kb-sources" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager'])) WITH CHECK (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));
CREATE POLICY "Owners/curators delete kb-sources" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));

CREATE POLICY "Employees read silo-media" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'silo-media' AND is_employee());
CREATE POLICY "Employees write silo-media" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'silo-media' AND is_employee());
CREATE POLICY "Employees update silo-media" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'silo-media' AND is_employee()) WITH CHECK (bucket_id = 'silo-media' AND is_employee());
CREATE POLICY "Employees delete silo-media" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'silo-media' AND is_employee());
