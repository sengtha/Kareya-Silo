-- =====================================================================
-- KAREYA SILO — EVALUATION EVIDENCE & KPI TEMPLATES (evaluation)
-- ---------------------------------------------------------------------
-- Performance reviews are hard because a manager sits in front of a blank
-- form and writes from memory of the last three weeks. That produces
-- recency bias, two managers rating the same work differently, and no
-- evidence to point at when somebody disagrees.
--
-- So this automates the EVIDENCE, not the judgement. Kareya assembles
-- what the modules already recorded about a person over a period, and a
-- human still decides what it means.
--
-- WHAT THIS DELIBERATELY DOES NOT DO, and should not be extended to do:
--
--   * It does not rate anybody. Where a KPI has a target it computes a
--     SUGGESTED band, and the review stores the suggestion and the
--     manager's actual rating separately, with a note when they differ.
--     A number that looks objective but was never examined is worse than
--     an honest opinion, and a rating that supports discipline has to be
--     defensible by a person, not by a formula.
--   * It does not read messages. No chat, no sentiment. Evaluating people
--     on their conversations teaches them to stop having them.
--   * It does not rank staff against each other or trigger any action.
--
-- Every indicator here is something the business already records as a
-- by-product of work: attendance, tasks, tickets, hours, deals, training.
-- Nothing new has to be captured for a review to have evidence.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.performance_reviews,
--             public.has_any_role(text[]), public.is_employee().
-- Reads, where present: attendance_records, leave_requests, tasks,
--             tickets, time_entries, deals, quotes, commission_entries,
--             course_enrollments.
-- =====================================================================

-- ---- the indicators Kareya can measure ---------------------------------
-- A fixed catalogue, not free-form SQL: an indicator whose query could be
-- typed in would let anyone who can edit a template read the whole
-- database through the review screen.
CREATE TABLE IF NOT EXISTS public.kpi_definitions (
  code text NOT NULL,
  name text NOT NULL,
  name_kh text,
  category text,                                 -- attendance | delivery | quality | commercial | development
  unit text,                                     -- days | percent | hours | count | amount | rating
  higher_is_better boolean DEFAULT true,
  description text,
  source_module text,                            -- which screen the number comes from, for "where did this come from?"
  is_active boolean DEFAULT true,
  CONSTRAINT kpi_definitions_pkey PRIMARY KEY (code)
);

INSERT INTO public.kpi_definitions (code, name, name_kh, category, unit, higher_is_better, description, source_module)
SELECT v.* FROM (VALUES
  ('days_present','Days present','ថ្ងៃមកធ្វើការ','attendance','days',true,
    'Days with an attendance record marked present or late','Attendance'),
  ('days_late','Days late','ថ្ងៃមកយឺត','attendance','days',false,
    'Days checked in with a late status','Attendance'),
  ('punctuality_rate','Punctuality','ភាពទាន់ពេល','attendance','percent',true,
    'Share of attended days that were on time','Attendance'),
  ('days_absent','Days absent','ថ្ងៃអវត្តមាន','attendance','days',false,
    'Days marked absent. Approved leave is counted separately, not here','Attendance'),
  ('leave_days','Approved leave taken','ច្បាប់ឈប់សម្រាក','attendance','days',true,
    'Approved leave days. Shown for context — taking entitled leave is not a fault','Leave'),

  ('tasks_completed','Tasks completed','កិច្ចការបានបញ្ចប់','delivery','count',true,
    'Tasks assigned to this person and marked done in the period','Projects'),
  ('tasks_on_time_rate','Tasks on time','បញ្ចប់ទាន់កាលកំណត់','delivery','percent',true,
    'Share of completed tasks finished on or before their due date','Projects'),
  ('tasks_overdue','Tasks still overdue','កិច្ចការហួសកាលកំណត់','delivery','count',false,
    'Assigned tasks past their due date and still not done at period end','Projects'),
  ('hours_logged','Hours logged','ម៉ោងធ្វើការ','delivery','hours',true,
    'Time entries recorded in the period','Projects'),
  ('billable_hours','Billable hours','ម៉ោងគិតលុយ','delivery','hours',true,
    'Time entries marked billable','Projects'),

  ('tickets_resolved','Tickets resolved','សំណើបានដោះស្រាយ','quality','count',true,
    'Support tickets this person resolved in the period','Support'),
  ('ticket_sla_rate','Resolved within SLA','ទាន់ SLA','quality','percent',true,
    'Share of resolved tickets closed before their due time','Support'),
  ('ticket_csat','Customer satisfaction','ការពេញចិត្តអតិថិជន','quality','rating',true,
    'Average customer rating out of 5 on this person''s tickets','Support'),

  ('deals_won','Deals won','កិច្ចព្រមព្រៀងជោគជ័យ','commercial','count',true,
    'Deals owned by this person that reached won','Sales'),
  ('deals_value','Value won','ទឹកប្រាក់','commercial','amount',true,
    'Total value of deals won','Sales'),
  ('quotes_sent','Quotes sent','សម្រង់តម្លៃបានផ្ញើ','commercial','count',true,
    'Quotes issued by this person','Sales'),
  ('quote_win_rate','Quote acceptance','អត្រាទទួលយក','commercial','percent',true,
    'Share of decided quotes that were accepted','Sales'),
  ('commission_earned','Commission earned','កំរៃជើងសារ','commercial','amount',true,
    'Commission entries raised in the period','Commission'),

  ('courses_completed','Training completed','វគ្គបណ្តុះបណ្តាល','development','count',true,
    'Courses finished in the period','Learning')
) AS v(code, name, name_kh, category, unit, higher_is_better, description, source_module)
WHERE NOT EXISTS (SELECT 1 FROM public.kpi_definitions x WHERE x.code = v.code);

-- ---- what "good" means for a given role --------------------------------
-- Defined once per role, so two managers reviewing the same job use the
-- same yardstick. Inconsistency between reviewers is the biggest fairness
-- problem in appraisal and the one nobody notices until somebody complains.
CREATE TABLE IF NOT EXISTS public.review_templates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  role text,                                     -- matches an employees.roles entry
  description text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT review_templates_pkey PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_review_templates_name ON public.review_templates (lower(name));

CREATE TABLE IF NOT EXISTS public.review_template_kpis (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  template_id uuid NOT NULL,
  kpi_code text NOT NULL,
  target numeric,                                -- optional: without one the KPI is shown as context only
  weight numeric DEFAULT 1,
  sort_order integer DEFAULT 0,
  CONSTRAINT review_template_kpis_pkey PRIMARY KEY (id),
  CONSTRAINT review_template_kpis_template_fkey FOREIGN KEY (template_id) REFERENCES public.review_templates(id) ON DELETE CASCADE,
  CONSTRAINT review_template_kpis_kpi_fkey FOREIGN KEY (kpi_code) REFERENCES public.kpi_definitions(code) ON DELETE CASCADE,
  CONSTRAINT review_template_kpis_weight_check CHECK (weight >= 0)
);
-- The same indicator twice in one template would count double and nobody
-- would see why the score moved.
CREATE UNIQUE INDEX IF NOT EXISTS uq_review_template_kpis
  ON public.review_template_kpis (template_id, kpi_code);

-- ---- the review gains its evidence -------------------------------------
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS template_id uuid;
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS period_start date;
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS period_end date;
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS suggested_rating numeric;
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS rating_override_note text;
-- Frozen at finalisation. If a rating is queried in six months the numbers
-- shown must be the ones it was based on, not recomputed against data that
-- has moved on.
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS evidence jsonb;
ALTER TABLE public.performance_reviews ADD COLUMN IF NOT EXISTS evidence_captured_at timestamp with time zone;

DO $c$ BEGIN
  ALTER TABLE public.performance_reviews ADD CONSTRAINT performance_reviews_template_fkey
    FOREIGN KEY (template_id) REFERENCES public.review_templates(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
DO $c$ BEGIN
  ALTER TABLE public.performance_reviews ADD CONSTRAINT performance_reviews_period_check
    CHECK (period_start IS NULL OR period_end IS NULL OR period_end >= period_start);
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
-- Departing from the suggestion is fine and often right — but it has to be
-- said out loud, because the pattern of departures is management
-- information in itself.
DO $c$ BEGIN
  ALTER TABLE public.performance_reviews ADD CONSTRAINT performance_reviews_override_check
    CHECK (suggested_rating IS NULL OR status <> 'finalized'
        OR abs(suggested_rating - rating) < 0.5
        OR (rating_override_note IS NOT NULL AND btrim(rating_override_note) <> ''));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_performance_reviews_employee ON public.performance_reviews (employee_id, period_end DESC);

-- A finalised review has been discussed with the person. Silently editing
-- it afterwards destroys the only record of what was actually said.
CREATE OR REPLACE FUNCTION public.protect_finalized_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.status = 'finalized' AND NEW.status = 'finalized'
     AND (NEW.rating IS DISTINCT FROM OLD.rating
       OR NEW.evidence IS DISTINCT FROM OLD.evidence
       OR NEW.suggested_rating IS DISTINCT FROM OLD.suggested_rating) THEN
    RAISE EXCEPTION 'This review is finalised. Reopen it before changing the rating or its evidence.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_finalized_review ON public.performance_reviews;
CREATE TRIGGER trg_protect_finalized_review
  BEFORE UPDATE ON public.performance_reviews
  FOR EACH ROW EXECUTE FUNCTION public.protect_finalized_review();

-- ---- on-time completion needs the real finish date ---------------------
-- tasks has no completed_at, so "on time" cannot be measured honestly yet.
-- Adding the column here means it starts being true from now on rather
-- than being faked from due dates.
ALTER TABLE public.tasks ADD COLUMN IF NOT EXISTS completed_at timestamp with time zone;

CREATE OR REPLACE FUNCTION public.stamp_task_completion()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = 'done' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'done') THEN
    NEW.completed_at := COALESCE(NEW.completed_at, now());
  ELSIF NEW.status <> 'done' THEN
    NEW.completed_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stamp_task_completion ON public.tasks;
CREATE TRIGGER trg_stamp_task_completion
  BEFORE INSERT OR UPDATE OF status ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.stamp_task_completion();

-- ---- the evidence pack --------------------------------------------------
/** Everything the modules already recorded about one person over one
 *  period. Facts only — no score, no verdict.
 *
 *  Deliberately NOT security definer: a manager sees exactly what their
 *  own row-level access allows, so this cannot become a way to read data
 *  the caller could not otherwise reach.
 *
 *  Indicators whose source module is not installed simply do not appear,
 *  rather than erroring or, worse, reporting a confident zero. */
DROP FUNCTION IF EXISTS public.employee_evidence(uuid, date, date);
CREATE OR REPLACE FUNCTION public.employee_evidence(p_employee_id uuid, p_from date, p_to date)
 RETURNS TABLE (out_kpi_code text, out_value numeric, out_detail text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_present numeric; v_late numeric; v_absent numeric;
  v_done numeric; v_ontime numeric; v_dated numeric;
  v_decided numeric; v_accepted numeric;
  v_resolved numeric; v_sla numeric;
BEGIN
  -- attendance
  IF to_regclass('public.attendance_records') IS NOT NULL THEN
    SELECT COUNT(*) FILTER (WHERE status IN ('present','late')),
           COUNT(*) FILTER (WHERE status = 'late'),
           COUNT(*) FILTER (WHERE status = 'absent')
      INTO v_present, v_late, v_absent
      FROM attendance_records
     WHERE employee_id = p_employee_id AND date BETWEEN p_from AND p_to;

    RETURN QUERY SELECT 'days_present', v_present, NULL::text;
    RETURN QUERY SELECT 'days_late', v_late, NULL::text;
    RETURN QUERY SELECT 'days_absent', v_absent, NULL::text;
    IF v_present > 0 THEN
      RETURN QUERY SELECT 'punctuality_rate', ROUND((v_present - v_late) * 100.0 / v_present, 1),
                          (v_present - v_late)::text || ' of ' || v_present::text || ' days on time';
    END IF;
  END IF;

  IF to_regclass('public.leave_requests') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'leave_days', COALESCE(SUM(days), 0), NULL::text
        FROM leave_requests
       WHERE employee_id = p_employee_id AND status = 'approved'
         AND start_date <= p_to AND end_date >= p_from;
  END IF;

  -- delivery
  IF to_regclass('public.tasks') IS NOT NULL THEN
    -- Completed tasks are dated by when they were actually finished. Tasks
    -- closed before completed_at existed have no finish date, so they count
    -- towards the total but cannot be judged on-time either way.
    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE completed_at IS NOT NULL AND due_date IS NOT NULL),
           COUNT(*) FILTER (WHERE completed_at IS NOT NULL AND due_date IS NOT NULL
                              AND completed_at::date <= due_date)
      INTO v_done, v_dated, v_ontime
      FROM tasks
     WHERE assignee_id = p_employee_id AND status = 'done'
       AND COALESCE(completed_at::date, due_date, start_date) BETWEEN p_from AND p_to;
    RETURN QUERY SELECT 'tasks_completed', v_done, NULL::text;

    IF v_dated > 0 THEN
      RETURN QUERY SELECT 'tasks_on_time_rate', ROUND(v_ontime * 100.0 / v_dated, 1),
                          v_ontime::text || ' of ' || v_dated::text || ' with a due date';
    END IF;

    RETURN QUERY
      SELECT 'tasks_overdue', COUNT(*)::numeric, NULL::text
        FROM tasks
       WHERE assignee_id = p_employee_id AND status <> 'done'
         AND due_date IS NOT NULL AND due_date < p_to;
  END IF;

  IF to_regclass('public.time_entries') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'hours_logged', COALESCE(SUM(hours), 0), NULL::text
        FROM time_entries WHERE employee_id = p_employee_id AND date BETWEEN p_from AND p_to;
    RETURN QUERY
      SELECT 'billable_hours', COALESCE(SUM(hours) FILTER (WHERE billable), 0), NULL::text
        FROM time_entries WHERE employee_id = p_employee_id AND date BETWEEN p_from AND p_to;
  END IF;

  -- quality
  IF to_regclass('public.tickets') IS NOT NULL THEN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE due_at IS NULL OR resolved_at <= due_at)
      INTO v_resolved, v_sla
      FROM tickets
     WHERE assignee_id = p_employee_id AND resolved_at IS NOT NULL
       AND resolved_at::date BETWEEN p_from AND p_to;
    RETURN QUERY SELECT 'tickets_resolved', v_resolved, NULL::text;
    IF v_resolved > 0 THEN
      RETURN QUERY SELECT 'ticket_sla_rate', ROUND(v_sla * 100.0 / v_resolved, 1),
                          v_sla::text || ' of ' || v_resolved::text || ' within SLA';
    END IF;

    -- Only report satisfaction when somebody actually rated something. An
    -- average of nothing shown as 0 would look like the worst possible
    -- score for a person no customer happened to rate.
    RETURN QUERY
      SELECT 'ticket_csat', ROUND(AVG(csat_rating)::numeric, 2),
             COUNT(*)::text || ' rating(s)'
        FROM tickets
       WHERE assignee_id = p_employee_id AND csat_rating IS NOT NULL
         AND COALESCE(resolved_at, created_at)::date BETWEEN p_from AND p_to
      HAVING COUNT(*) > 0;
  END IF;

  -- commercial
  IF to_regclass('public.deals') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'deals_won', COUNT(*)::numeric, NULL::text FROM deals
       WHERE owner_id = p_employee_id AND stage = 'won'
         AND COALESCE(expected_close_date, created_at::date) BETWEEN p_from AND p_to;
    RETURN QUERY
      SELECT 'deals_value', COALESCE(SUM(amount), 0), NULL::text FROM deals
       WHERE owner_id = p_employee_id AND stage = 'won'
         AND COALESCE(expected_close_date, created_at::date) BETWEEN p_from AND p_to;
  END IF;

  IF to_regclass('public.quotes') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'quotes_sent', COUNT(*)::numeric, NULL::text FROM quotes
       WHERE owner_id = p_employee_id AND status <> 'draft' AND date BETWEEN p_from AND p_to;

    -- Win rate over DECIDED quotes only: counting ones still open would
    -- punish somebody for quotes the customer has not answered yet.
    SELECT COUNT(*) FILTER (WHERE status IN ('accepted','declined','invoiced')),
           COUNT(*) FILTER (WHERE status IN ('accepted','invoiced'))
      INTO v_decided, v_accepted
      FROM quotes WHERE owner_id = p_employee_id AND date BETWEEN p_from AND p_to;
    IF v_decided > 0 THEN
      RETURN QUERY SELECT 'quote_win_rate', ROUND(v_accepted * 100.0 / v_decided, 1),
                          v_accepted::text || ' of ' || v_decided::text || ' decided';
    END IF;
  END IF;

  IF to_regclass('public.commission_entries') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'commission_earned', COALESCE(SUM(amount), 0), NULL::text
        FROM commission_entries
       WHERE employee_id = p_employee_id AND status <> 'cancelled'
         AND date BETWEEN p_from AND p_to;
  END IF;

  -- development
  IF to_regclass('public.course_enrollments') IS NOT NULL THEN
    RETURN QUERY
      SELECT 'courses_completed', COUNT(*)::numeric, NULL::text
        FROM course_enrollments
       WHERE employee_id = p_employee_id AND completed_at IS NOT NULL
         AND completed_at::date BETWEEN p_from AND p_to;
  END IF;

  RETURN;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.employee_evidence(uuid, date, date) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.kpi_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_template_kpis ENABLE ROW LEVEL SECURITY;

-- Staff may read the indicators and the templates: being measured against
-- a yardstick you are not allowed to see is not an appraisal.
DROP POLICY IF EXISTS "View kpi definitions" ON public.kpi_definitions;
DROP POLICY IF EXISTS "Manage kpi definitions" ON public.kpi_definitions;
CREATE POLICY "View kpi definitions" ON public.kpi_definitions FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage kpi definitions" ON public.kpi_definitions FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Manager']));

DROP POLICY IF EXISTS "View review templates" ON public.review_templates;
DROP POLICY IF EXISTS "Manage review templates" ON public.review_templates;
CREATE POLICY "View review templates" ON public.review_templates FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage review templates" ON public.review_templates FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Manager']));

DROP POLICY IF EXISTS "View review template kpis" ON public.review_template_kpis;
DROP POLICY IF EXISTS "Manage review template kpis" ON public.review_template_kpis;
CREATE POLICY "View review template kpis" ON public.review_template_kpis FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage review template kpis" ON public.review_template_kpis FOR ALL TO authenticated
  USING (has_any_role(ARRAY['HR','HR Manager','Manager'])) WITH CHECK (has_any_role(ARRAY['HR','HR Manager','Manager']));
