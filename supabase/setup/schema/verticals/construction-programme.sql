-- =====================================================================
-- KAREYA SILO — CONSTRUCTION PROGRAMME: ACTIVITIES, LINKS, CRITICAL PATH
-- ---------------------------------------------------------------------
-- Kareya could already price a job and value it. `construction-estimating`
-- holds the bill of quantities and the rate build-ups; `construction-
-- valuation` certifies what has been done and holds the retention. What
-- was missing was WHEN.
--
-- Nothing connected the money to the calendar. There was no programme, so
-- there was no way to answer the only question a contractor is actually
-- asked on site:
--
--   The slab slipped three days. What does that do to handover?
--
-- Projects has a timeline, and it is honest work, but it is a BAR CHART:
-- `tasks` carries a start and a due date and nothing else. Without
-- dependencies there is no critical path, and without a critical path a
-- Gantt cannot answer that question — it can only draw the answer once
-- somebody has worked it out on paper.
--
-- THREE DECISIONS THIS FILE EXISTS TO ENFORCE:
--
-- 1. THE SCHEDULE IS ARITHMETIC, SO THE DATABASE DOES IT. Forward pass,
--    backward pass, float, critical path. A browser that computes a
--    critical path computes a different one from the next browser.
--
-- 2. A PROGRAMME IS COUNTED IN WORKING DAYS, NOT CALENDAR DAYS. Nobody
--    pours concrete on Khmer New Year. So the passes run on WORKING-DAY
--    OFFSETS — plain integers, which is where the maths belongs — and a
--    separate step turns an offset into a date by walking the site's own
--    working week and the holiday register. Doing it the other way round
--    is how a programme quietly promises a handover on a public holiday.
--
-- 3. A LOOP IS REFUSED AT THE POINT SOMEBODY DRAWS IT. "A cannot follow B
--    when B already follows A" said while the mouse is still moving is
--    worth more than a scheduler that hangs, or silently gives up, three
--    hundred activities later.
--
-- AND A BASELINE, because a programme without one only ever shows today's
-- plan. Slippage is the difference between what you said and what is
-- happening, and it cannot be seen if the plan quietly follows reality.
--
-- NO DURATIONS, NO OUTPUT RATES, NO STANDARD ACTIVITIES SHIP. How long a
-- blockwall takes depends on the gang, the access and the weather, and a
-- plausible default here would become somebody's programme.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.construction_projects, public.employees,
--             public.holidays, public.has_any_role(text[]).
-- Reads, where present: public.boq_items, public.valuation_items
--             (linked when the estimating and valuation verticals are in).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE SITE'S WORKING WEEK
-- Six-day weeks are ordinary in Cambodian construction and Sunday-only
-- rest is common, so this is not a detail that can be assumed. NULL means
-- "not said", and the scheduler then treats every day as workable rather
-- than inventing a week nobody agreed to.
-- ---------------------------------------------------------------------
ALTER TABLE public.construction_projects
  ADD COLUMN IF NOT EXISTS work_days integer[];        -- 0 = Sunday … 6 = Saturday
ALTER TABLE public.construction_projects
  ADD COLUMN IF NOT EXISTS observes_holidays boolean DEFAULT true;

/** The next workable day on or after a date. */
CREATE OR REPLACE FUNCTION public.next_work_day(p_project uuid, p_date date)
 RETURNS date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_days integer[]; v_hol boolean; v_d date; v_guard integer := 0;
BEGIN
  SELECT work_days, coalesce(observes_holidays, true)
    INTO v_days, v_hol
    FROM construction_projects WHERE id = p_project;

  v_d := p_date;
  LOOP
    EXIT WHEN v_days IS NULL OR array_length(v_days, 1) IS NULL
           OR extract(dow FROM v_d)::integer = ANY (v_days);
    v_d := v_d + 1;
    v_guard := v_guard + 1;
    -- A working week of no days would spin forever. Say so instead.
    IF v_guard > 14 THEN
      RAISE EXCEPTION 'This project has no working days set that fall in a week.';
    END IF;
  END LOOP;

  IF v_hol THEN
    v_guard := 0;
    WHILE EXISTS (SELECT 1 FROM holidays h WHERE h.date = v_d) LOOP
      v_d := v_d + 1;
      -- Land back on a working day after stepping over the holiday.
      WHILE v_days IS NOT NULL AND array_length(v_days, 1) IS NOT NULL
            AND NOT (extract(dow FROM v_d)::integer = ANY (v_days)) LOOP
        v_d := v_d + 1;
      END LOOP;
      v_guard := v_guard + 1;
      IF v_guard > 60 THEN
        RAISE EXCEPTION 'Two months of holidays in a row — check the holiday register.';
      END IF;
    END LOOP;
  END IF;

  RETURN v_d;
END;
$$;

/** `p_offset` working days after the project start. Offset 0 is the first
 *  working day of the job, which is what a programme means by "day 1". */
CREATE OR REPLACE FUNCTION public.work_day_at(p_project uuid, p_offset integer)
 RETURNS date
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_start date; v_d date; i integer;
BEGIN
  SELECT start_date INTO v_start FROM construction_projects WHERE id = p_project;
  IF v_start IS NULL THEN
    RAISE EXCEPTION 'This project has no start date, so a programme has nothing to count from.';
  END IF;

  v_d := next_work_day(p_project, v_start);
  FOR i IN 1..greatest(coalesce(p_offset, 0), 0) LOOP
    v_d := next_work_day(p_project, v_d + 1);
  END LOOP;
  RETURN v_d;
END;
$$;

-- ---------------------------------------------------------------------
-- 2. THE ACTIVITIES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.programme_activities (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  project_id    uuid NOT NULL,
  parent_id     uuid,                          -- work breakdown, purely for reading
  code          text,
  name          text NOT NULL,
  -- In WORKING days. A milestone is zero, which is what makes it a
  -- milestone rather than a very short activity.
  duration_days integer DEFAULT 1 NOT NULL,
  is_milestone  boolean DEFAULT false,

  -- A date somebody insists on, whatever the logic says. Used as a floor
  -- in the forward pass, never as a substitute for it.
  constraint_start date,

  -- ---- what actually happened ----
  actual_start  date,
  actual_finish date,
  percent_complete numeric DEFAULT 0 NOT NULL,

  -- ---- worked out by schedule_programme(); never set by hand ----
  early_start   integer,                       -- working-day offsets
  early_finish  integer,
  late_start    integer,
  late_finish   integer,
  total_float   integer,
  is_critical   boolean DEFAULT false,
  scheduled_at  timestamp with time zone,

  -- ---- frozen by baseline_programme() ----
  baseline_start  integer,
  baseline_finish integer,
  baselined_at    timestamp with time zone,

  responsible_id uuid,
  notes         text,
  sort_order    integer DEFAULT 0 NOT NULL,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT programme_activities_pkey PRIMARY KEY (id),
  CONSTRAINT programme_activities_project_fkey FOREIGN KEY (project_id)
    REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  CONSTRAINT programme_activities_parent_fkey FOREIGN KEY (parent_id)
    REFERENCES public.programme_activities(id) ON DELETE SET NULL,
  CONSTRAINT programme_activities_responsible_fkey FOREIGN KEY (responsible_id)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT programme_activities_duration_check CHECK (duration_days >= 0),
  CONSTRAINT programme_activities_milestone_check
    CHECK (NOT is_milestone OR duration_days = 0),
  CONSTRAINT programme_activities_percent_check
    CHECK (percent_complete BETWEEN 0 AND 100),
  -- Finished on a date it had not started is not a typo worth keeping.
  CONSTRAINT programme_activities_actual_check
    CHECK (actual_finish IS NULL OR actual_start IS NULL OR actual_finish >= actual_start)
);

COMMENT ON TABLE public.programme_activities IS
  'One bar on the construction programme. Durations are WORKING days; early/late offsets are working days from the project start.';

CREATE INDEX IF NOT EXISTS idx_programme_activities_project
  ON public.programme_activities (project_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_programme_activities_critical
  ON public.programme_activities (project_id, is_critical);

-- ---------------------------------------------------------------------
-- 3. THE LOGIC
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.activity_links (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  predecessor_id uuid NOT NULL,
  successor_id   uuid NOT NULL,
  -- FS finish-to-start · SS start-to-start · FF finish-to-finish
  -- SF start-to-finish, which is rare and almost always a mistake, but
  -- refusing it outright would be this file deciding how somebody builds.
  link_type      text DEFAULT 'FS' NOT NULL,
  -- Working days. Negative is a lead: "start the second coat two days
  -- before the first finishes."
  lag_days       integer DEFAULT 0 NOT NULL,
  notes          text,
  created_at     timestamp with time zone DEFAULT now(),
  CONSTRAINT activity_links_pkey PRIMARY KEY (id),
  CONSTRAINT activity_links_pred_fkey FOREIGN KEY (predecessor_id)
    REFERENCES public.programme_activities(id) ON DELETE CASCADE,
  CONSTRAINT activity_links_succ_fkey FOREIGN KEY (successor_id)
    REFERENCES public.programme_activities(id) ON DELETE CASCADE,
  CONSTRAINT activity_links_type_check
    CHECK (link_type = ANY (ARRAY['FS', 'SS', 'FF', 'SF'])),
  CONSTRAINT activity_links_self_check CHECK (predecessor_id <> successor_id),
  CONSTRAINT uq_activity_link UNIQUE (predecessor_id, successor_id)
);

CREATE INDEX IF NOT EXISTS idx_activity_links_pred ON public.activity_links (predecessor_id);
CREATE INDEX IF NOT EXISTS idx_activity_links_succ ON public.activity_links (successor_id);

/** A link that closes a loop is refused as it is drawn.
 *
 *  A cycle is not a scheduling problem to be worked around later — it is
 *  a statement that A waits for B and B waits for A, which cannot be
 *  built. Caught here, the person still has the two activities in front
 *  of them; caught in the scheduler, they have three hundred. */
CREATE OR REPLACE FUNCTION public.activity_link_no_cycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_a programme_activities; v_b programme_activities;
BEGIN
  SELECT * INTO v_a FROM programme_activities WHERE id = NEW.predecessor_id;
  SELECT * INTO v_b FROM programme_activities WHERE id = NEW.successor_id;
  IF v_a.project_id <> v_b.project_id THEN
    RAISE EXCEPTION 'Those two activities are on different projects.';
  END IF;

  -- Does the successor already reach the predecessor?
  IF EXISTS (
    WITH RECURSIVE onward AS (
      SELECT successor_id AS id FROM activity_links WHERE predecessor_id = NEW.successor_id
      UNION
      SELECT l.successor_id FROM activity_links l JOIN onward o ON o.id = l.predecessor_id
    )
    SELECT 1 FROM onward WHERE id = NEW.predecessor_id
  ) THEN
    RAISE EXCEPTION '% cannot follow % — % already follows %.',
      v_b.name, v_a.name, v_a.name, v_b.name;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_activity_link_no_cycle ON public.activity_links;
CREATE TRIGGER trg_activity_link_no_cycle
  BEFORE INSERT OR UPDATE ON public.activity_links
  FOR EACH ROW EXECUTE FUNCTION public.activity_link_no_cycle();

-- ---------------------------------------------------------------------
-- 4. WHAT AN ACTIVITY DELIVERS
-- The seam that makes a programme worth keeping rather than a second
-- diary: the bar on the chart and the money in the bill are the same job.
-- ---------------------------------------------------------------------
DO $t$ BEGIN
  IF to_regclass('public.boq_items') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS public.activity_boq_items (
      id           uuid DEFAULT gen_random_uuid() NOT NULL,
      activity_id  uuid NOT NULL,
      boq_item_id  uuid NOT NULL,
      -- Part of a BOQ line can belong to one activity and part to another
      -- (ground floor blockwork, first floor blockwork). NULL means all
      -- of it.
      portion_pct  numeric,
      CONSTRAINT activity_boq_items_pkey PRIMARY KEY (id),
      CONSTRAINT activity_boq_items_activity_fkey FOREIGN KEY (activity_id)
        REFERENCES public.programme_activities(id) ON DELETE CASCADE,
      CONSTRAINT activity_boq_items_boq_fkey FOREIGN KEY (boq_item_id)
        REFERENCES public.boq_items(id) ON DELETE CASCADE,
      CONSTRAINT activity_boq_items_portion_check
        CHECK (portion_pct IS NULL OR (portion_pct > 0 AND portion_pct <= 100)),
      CONSTRAINT uq_activity_boq_item UNIQUE (activity_id, boq_item_id)
    );
    CREATE INDEX IF NOT EXISTS idx_activity_boq_activity
      ON public.activity_boq_items (activity_id);
  END IF;
END $t$;

-- ---------------------------------------------------------------------
-- 5. THE CRITICAL PATH
-- A forward pass for the earliest anything can happen, a backward pass
-- for the latest it can happen without moving the end, and the difference
-- between them is float. Nothing with float is on the critical path, and
-- nothing without it can move at all.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.schedule_programme(uuid);
CREATE OR REPLACE FUNCTION public.schedule_programme(p_project uuid)
 RETURNS TABLE (out_activities integer, out_duration integer, out_critical integer)
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'public'
AS $$
DECLARE
  v_n integer; v_changed boolean; v_pass integer := 0; v_end integer;
BEGIN
  SELECT count(*) INTO v_n FROM programme_activities WHERE project_id = p_project;
  IF v_n = 0 THEN
    out_activities := 0; out_duration := 0; out_critical := 0;
    RETURN NEXT; RETURN;
  END IF;

  -- ---- forward pass ------------------------------------------------
  -- Everything starts as early as its own constraint allows, then is
  -- pushed out by its predecessors until nothing moves. Relaxation rather
  -- than a topological sort: the cycle trigger already guarantees this
  -- terminates, and it keeps the arithmetic in one readable statement.
  UPDATE programme_activities a
     SET early_start = greatest(
           0,
           coalesce((a.constraint_start - work_day_at(p_project, 0))::integer, 0)),
         early_finish = NULL, late_start = NULL, late_finish = NULL,
         total_float = NULL, is_critical = false
   WHERE a.project_id = p_project;

  UPDATE programme_activities a
     SET early_finish = a.early_start + greatest(a.duration_days - 1, -1) + 1
   WHERE a.project_id = p_project;
  -- early_finish is the offset of the day AFTER the activity ends, so a
  -- one-day activity starting on day 3 finishes at 4 and its FS successor
  -- starts on day 4. A milestone starts and finishes at the same offset,
  -- which is what zero duration means.

  LOOP
    v_pass := v_pass + 1;
    v_changed := false;

    WITH want AS (
      SELECT l.successor_id AS id,
             max(CASE l.link_type
                   WHEN 'FS' THEN p.early_finish + l.lag_days
                   WHEN 'SS' THEN p.early_start  + l.lag_days
                   WHEN 'FF' THEN p.early_finish + l.lag_days - s.duration_days
                   WHEN 'SF' THEN p.early_start  + l.lag_days - s.duration_days
                 END) AS es
        FROM activity_links l
        JOIN programme_activities p ON p.id = l.predecessor_id
        JOIN programme_activities s ON s.id = l.successor_id
       WHERE s.project_id = p_project
       GROUP BY l.successor_id
    ), moved AS (
      UPDATE programme_activities a
         SET early_start  = greatest(a.early_start, w.es),
             early_finish = greatest(a.early_start, w.es) + a.duration_days
        FROM want w
       WHERE a.id = w.id AND w.es > a.early_start
       RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM moved) INTO v_changed;

    EXIT WHEN NOT v_changed;
    -- Belt and braces. The trigger makes a cycle impossible, so this can
    -- only fire if one was created another way — and hanging is a worse
    -- answer than saying so.
    IF v_pass > v_n + 2 THEN
      RAISE EXCEPTION 'The logic never settles. There is a loop in this programme.';
    END IF;
  END LOOP;

  SELECT max(early_finish) INTO v_end
    FROM programme_activities WHERE project_id = p_project;

  -- ---- backward pass -----------------------------------------------
  UPDATE programme_activities a
     SET late_finish = v_end,
         late_start  = v_end - a.duration_days
   WHERE a.project_id = p_project;

  v_pass := 0;
  LOOP
    v_pass := v_pass + 1;

    WITH want AS (
      SELECT l.predecessor_id AS id,
             min(CASE l.link_type
                   WHEN 'FS' THEN s.late_start  - l.lag_days
                   WHEN 'SS' THEN s.late_start  - l.lag_days + p.duration_days
                   WHEN 'FF' THEN s.late_finish - l.lag_days
                   WHEN 'SF' THEN s.late_finish - l.lag_days + p.duration_days
                 END) AS lf
        FROM activity_links l
        JOIN programme_activities p ON p.id = l.predecessor_id
        JOIN programme_activities s ON s.id = l.successor_id
       WHERE p.project_id = p_project
       GROUP BY l.predecessor_id
    ), moved AS (
      UPDATE programme_activities a
         SET late_finish = least(a.late_finish, w.lf),
             late_start  = least(a.late_finish, w.lf) - a.duration_days
        FROM want w
       WHERE a.id = w.id AND w.lf < a.late_finish
       RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM moved) INTO v_changed;

    EXIT WHEN NOT v_changed;
    IF v_pass > v_n + 2 THEN
      RAISE EXCEPTION 'The logic never settles backwards. There is a loop in this programme.';
    END IF;
  END LOOP;

  -- ---- float, and what it means ------------------------------------
  UPDATE programme_activities a
     SET total_float = a.late_start - a.early_start,
         is_critical = (a.late_start - a.early_start) <= 0,
         scheduled_at = now()
   WHERE a.project_id = p_project;

  out_activities := v_n;
  out_duration := coalesce(v_end, 0);
  SELECT count(*) INTO out_critical
    FROM programme_activities WHERE project_id = p_project AND is_critical;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. THE PROGRAMME, AS DATES
-- Offsets are how the maths is done. Dates are what a site manager reads,
-- so the conversion happens here and once.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.programme_dates(uuid);
CREATE OR REPLACE FUNCTION public.programme_dates(p_project uuid)
 RETURNS TABLE (
   out_id           uuid,
   out_code         text,
   out_name         text,
   out_duration     integer,
   out_is_milestone boolean,
   out_start        date,
   out_finish       date,
   out_latest_start date,
   out_float        integer,
   out_critical     boolean,
   out_percent      numeric,
   out_actual_start date,
   out_actual_finish date,
   out_baseline_start  date,
   out_baseline_finish date,
   out_slip_days    integer,
   out_responsible  text,
   out_sort         integer
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT a.*, e.name AS who
      FROM programme_activities a
      LEFT JOIN employees e ON e.id = a.responsible_id
     WHERE a.project_id = p_project
     ORDER BY a.sort_order, coalesce(a.early_start, 0), a.name
  LOOP
    out_id := r.id; out_code := r.code; out_name := r.name;
    out_duration := r.duration_days; out_is_milestone := r.is_milestone;
    out_float := r.total_float; out_critical := coalesce(r.is_critical, false);
    out_percent := r.percent_complete;
    out_actual_start := r.actual_start; out_actual_finish := r.actual_finish;
    out_responsible := r.who; out_sort := r.sort_order;

    out_start  := CASE WHEN r.early_start IS NULL THEN NULL
                       ELSE work_day_at(p_project, r.early_start) END;
    -- The last WORKING day of the activity, not the day after it. A bar
    -- drawn to the day after is a bar that looks a day too long.
    out_finish := CASE WHEN r.early_finish IS NULL THEN NULL
                       WHEN r.duration_days = 0 THEN work_day_at(p_project, r.early_finish)
                       ELSE work_day_at(p_project, r.early_finish - 1) END;
    out_latest_start := CASE WHEN r.late_start IS NULL THEN NULL
                             ELSE work_day_at(p_project, greatest(r.late_start, 0)) END;
    out_baseline_start := CASE WHEN r.baseline_start IS NULL THEN NULL
                               ELSE work_day_at(p_project, r.baseline_start) END;
    out_baseline_finish := CASE WHEN r.baseline_finish IS NULL THEN NULL
                                WHEN r.duration_days = 0 THEN work_day_at(p_project, r.baseline_finish)
                                ELSE work_day_at(p_project, greatest(r.baseline_finish - 1, 0)) END;
    -- Positive is late. Measured in working days, because that is what
    -- the programme is counted in.
    out_slip_days := CASE WHEN r.baseline_finish IS NULL OR r.early_finish IS NULL
                          THEN NULL ELSE r.early_finish - r.baseline_finish END;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. THE BASELINE
-- ---------------------------------------------------------------------
/** Freeze the programme as agreed. Without this, slippage cannot be seen:
 *  a plan that quietly follows reality is always on time. */
CREATE OR REPLACE FUNCTION public.baseline_programme(p_project uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM programme_activities
                  WHERE project_id = p_project AND early_start IS NOT NULL) THEN
    RAISE EXCEPTION 'Work out the programme before freezing it — there is nothing to freeze yet.';
  END IF;

  WITH done AS (
    UPDATE programme_activities
       SET baseline_start = early_start, baseline_finish = early_finish,
           baselined_at = now()
     WHERE project_id = p_project
     RETURNING 1)
  SELECT count(*) INTO v_n FROM done;
  RETURN v_n;
END;
$$;

/** What has moved, and by how much. Only ever the truth about the
 *  difference between two numbers — no opinion about whose fault it is. */
DROP FUNCTION IF EXISTS public.programme_slippage(uuid);
CREATE OR REPLACE FUNCTION public.programme_slippage(p_project uuid)
 RETURNS TABLE (
   out_name      text,
   out_critical  boolean,
   out_slip_days integer,
   out_was       date,
   out_now       date
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT a.name, coalesce(a.is_critical, false),
         a.early_finish - a.baseline_finish,
         work_day_at(a.project_id, greatest(a.baseline_finish - 1, 0)),
         work_day_at(a.project_id, greatest(a.early_finish - 1, 0))
    FROM programme_activities a
   WHERE a.project_id = p_project
     AND a.baseline_finish IS NOT NULL AND a.early_finish IS NOT NULL
     AND a.early_finish <> a.baseline_finish
   ORDER BY (a.early_finish - a.baseline_finish) DESC;
$$;

-- ---------------------------------------------------------------------
-- 8. THE MONEY AGAINST THE CALENDAR
-- What the programme says should have been earned by now, against what
-- has actually been certified. Both numbers already exist; nothing joined
-- them until an activity could say which BOQ lines it delivers.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.programme_value(uuid, date);
CREATE OR REPLACE FUNCTION public.programme_value(p_project uuid, p_as_at date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_planned   numeric,
   out_earned    numeric,
   out_certified numeric,
   out_computed  boolean,
   out_problem   text
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_planned numeric := 0; v_earned numeric := 0; v_certified numeric := 0;
BEGIN
  IF to_regclass('public.activity_boq_items') IS NULL
     OR to_regclass('public.boq_items') IS NULL THEN
    out_planned := NULL; out_earned := NULL; out_certified := NULL;
    out_computed := false;
    out_problem := 'The bill of quantities is not installed, so there is nothing to value against.';
    RETURN NEXT; RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM activity_boq_items ab
                   JOIN programme_activities a ON a.id = ab.activity_id
                  WHERE a.project_id = p_project) THEN
    out_planned := NULL; out_earned := NULL; out_certified := NULL;
    out_computed := false;
    out_problem := 'No activity says which bill items it delivers, so the programme and the money are not joined up yet.';
    RETURN NEXT; RETURN;
  END IF;

  -- Planned: everything the programme says should have finished by now.
  SELECT coalesce(sum(b.amount_sell * coalesce(ab.portion_pct, 100) / 100.0), 0)
    INTO v_planned
    FROM activity_boq_items ab
    JOIN programme_activities a ON a.id = ab.activity_id
    JOIN boq_items b ON b.id = ab.boq_item_id
   WHERE a.project_id = p_project
     AND a.early_finish IS NOT NULL
     AND work_day_at(p_project, greatest(a.early_finish - 1, 0)) <= p_as_at;

  -- Earned: what the site says it has done, at the percentage recorded.
  SELECT coalesce(sum(b.amount_sell * coalesce(ab.portion_pct, 100) / 100.0
                      * a.percent_complete / 100.0), 0)
    INTO v_earned
    FROM activity_boq_items ab
    JOIN programme_activities a ON a.id = ab.activity_id
    JOIN boq_items b ON b.id = ab.boq_item_id
   WHERE a.project_id = p_project;

  -- Certified: what the client's surveyor has actually agreed to pay for.
  IF to_regclass('public.valuation_items') IS NOT NULL THEN
    SELECT coalesce(sum(vi.value_to_date), 0) INTO v_certified
      FROM valuation_items vi
      JOIN interim_valuations v ON v.id = vi.valuation_id
      JOIN boq_items b ON b.id = vi.boq_item_id
      JOIN activity_boq_items ab ON ab.boq_item_id = b.id
      JOIN programme_activities a ON a.id = ab.activity_id
     WHERE a.project_id = p_project
       AND v.status IN ('certified', 'paid')
       AND v.period_to <= p_as_at;
  END IF;

  out_planned := round(v_planned, 2);
  out_earned := round(v_earned, 2);
  out_certified := round(v_certified, 2);
  out_computed := true; out_problem := NULL;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 9. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.programme_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Critical and late. The only combination that moves the end date.
  SELECT 'activity', a.id, a.name,
         'On the critical path and ' || (a.early_finish - a.baseline_finish)::text
         || ' working day(s) later than the baseline — handover moves with it.'
    FROM programme_activities a
   WHERE a.is_critical AND a.baseline_finish IS NOT NULL
     AND a.early_finish > a.baseline_finish

  UNION ALL
  -- Should have started and has not.
  SELECT 'activity', a.id, a.name,
         'Was due to start ' || to_char(work_day_at(a.project_id, a.early_start), 'DD Mon')
         || ' and has not been started.'
    FROM programme_activities a
   WHERE a.actual_start IS NULL AND a.early_start IS NOT NULL
     AND work_day_at(a.project_id, a.early_start) < CURRENT_DATE
     AND coalesce(a.percent_complete, 0) = 0

  UNION ALL
  -- Started, finished, and nobody said so.
  SELECT 'activity', a.id, a.name,
         'Marked 100% complete but has no finish date recorded.'
    FROM programme_activities a
   WHERE a.percent_complete >= 100 AND a.actual_finish IS NULL

  UNION ALL
  -- Recorded as done without ever being recorded as started.
  SELECT 'activity', a.id, a.name,
         'Has a finish date but no start date.'
    FROM programme_activities a
   WHERE a.actual_finish IS NOT NULL AND a.actual_start IS NULL

  UNION ALL
  -- Hanging in space. An activity with no logic either way is not on the
  -- programme; it is a note next to it.
  SELECT 'activity', a.id, a.name,
         'Has nothing before it and nothing after it, so the programme cannot say when it happens.'
    FROM programme_activities a
   WHERE NOT EXISTS (SELECT 1 FROM activity_links l WHERE l.successor_id = a.id)
     AND NOT EXISTS (SELECT 1 FROM activity_links l WHERE l.predecessor_id = a.id)
     AND (SELECT count(*) FROM programme_activities x WHERE x.project_id = a.project_id) > 1

  UNION ALL
  -- Never worked out, or worked out before it was last changed.
  SELECT 'project', p.id, p.name,
         'The programme has never been worked out, so there is no critical path.'
    FROM construction_projects p
   WHERE EXISTS (SELECT 1 FROM programme_activities a
                  WHERE a.project_id = p.id AND a.early_start IS NULL)

  UNION ALL
  -- No baseline, so nothing to slip against.
  SELECT 'project', p.id, p.name,
         'The programme has no baseline. Without one it always looks on time, because the plan follows reality.'
    FROM construction_projects p
   WHERE EXISTS (SELECT 1 FROM programme_activities a WHERE a.project_id = p.id)
     AND NOT EXISTS (SELECT 1 FROM programme_activities a
                      WHERE a.project_id = p.id AND a.baseline_finish IS NOT NULL)

  UNION ALL
  -- A working week nobody set.
  SELECT 'project', p.id, p.name,
         'No working days are set, so the programme is being counted on a seven-day week.'
    FROM construction_projects p
   WHERE (p.work_days IS NULL OR array_length(p.work_days, 1) IS NULL)
     AND EXISTS (SELECT 1 FROM programme_activities a WHERE a.project_id = p.id);
$$;

GRANT EXECUTE ON FUNCTION public.next_work_day(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.work_day_at(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.schedule_programme(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.programme_dates(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.baseline_programme(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.programme_slippage(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.programme_value(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.programme_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY
-- Everyone on site reads the programme — a team that cannot see the plan
-- cannot follow it. Changing it is the site manager's job.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text; tabs text[];
BEGIN
  tabs := ARRAY['programme_activities', 'activity_links'];
  IF to_regclass('public.activity_boq_items') IS NOT NULL THEN
    tabs := tabs || ARRAY['activity_boq_items'];
  END IF;
  FOREACH t IN ARRAY tabs
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Site Manager','Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Site Manager','Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
