-- =====================================================================
-- KAREYA SILO — TIMETABLE AND ENROLMENT INTEGRITY (academy-integrity)
-- ---------------------------------------------------------------------
--  1. THE TIMETABLE CLASH WAS A BADGE. lib/timetable.ts worked out which
--     classes collided, in the browser, from React state — and then drew a
--     red chip saying "Clash". Nothing refused the save. A teacher could be
--     put in two rooms at nine on Monday and the only consequence was a
--     small red label somebody could ignore, or never scroll to.
--
--  2. AND IT NEVER LOOKED AT STUDENTS AT ALL. detectConflicts compared
--     teachers and rooms. The clash that actually costs somebody a lesson —
--     one student timetabled into two classes at the same hour — was not
--     checked anywhere, by anything, ever.
--
--  3. CAPACITY WAS DECORATION. class_sections.capacity existed and nothing
--     read it, so a room for thirty took as many as were typed in.
--
--  4. A MARK COULD BE ANY NUMBER. Nothing compared a score against the
--     assessment's max_score, so 500 out of 100 was accepted and the
--     weighted average quietly went over 100%. A student who was not in the
--     class could be graded for it. And a changed mark left no trace of
--     what it had been or who changed it — which is exactly what gets
--     disputed.
--
--  5. TAKING A FEE PAYMENT WAS A READ-MODIFY-WRITE FROM REACT STATE:
--     amount_paid = invoice.amountPaid + amount, computed in the browser
--     and written back whole. Two clerks at two windows, and one family's
--     payment disappears. Nothing refused a negative amount, so a payment
--     of -500 was a way to un-pay an invoice, and nothing refused paying
--     more than was owed.
--
--  6. INVOICE NUMBERS CAME FROM A CLOCK, with no unique index.
--
--  7. NOTHING SAID WHICH TERM WAS CURRENT. Setting it was two round-trips —
--     clear every other, then set this one — so a failure between them left
--     a school with no current term, and nothing stopped two.
--
-- Idempotent and order-independent. Depends on tables in the core schema:
-- academic_terms, class_sections, section_enrollments, assessments,
-- assessment_grades, students, student_invoices.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. READING A TIMETABLE
-- schedule_days is free text ("Mon,Wed,Fri", "mon wed"), and start_time /
-- end_time are text rather than time. These mirror lib/timetable.ts so the
-- browser and the database read the same row the same way — the point of
-- moving the check here is lost if they disagree about what it says.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.academy_parse_days(p_days text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(array_agg(DISTINCT d ORDER BY d), ARRAY[]::text[])
    FROM (
      SELECT lower(left(trim(t), 3)) AS d
        FROM regexp_split_to_table(coalesce(p_days, ''), '[,\s/]+') t
    ) x
   WHERE d IN ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun');
$function$;

CREATE OR REPLACE FUNCTION public.academy_minutes(p_time text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN p_time ~ '^\s*\d{1,2}:\d{2}'
      THEN (split_part(trim(p_time), ':', 1))::integer * 60
           + (left(split_part(trim(p_time), ':', 2), 2))::integer
    ELSE NULL
  END;
$function$;

-- Two sections collide if they share a day and their windows overlap.
-- A section with a day but no times is treated as a possible collision
-- rather than a definite miss: a half-filled timetable row should make
-- somebody look, not quietly pass.
CREATE OR REPLACE FUNCTION public.academy_slots_overlap(
  p_days_a text, p_start_a text, p_end_a text,
  p_days_b text, p_start_b text, p_end_b text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE a_s integer; a_e integer; b_s integer; b_e integer;
BEGIN
  IF NOT (academy_parse_days(p_days_a) && academy_parse_days(p_days_b)) THEN
    RETURN false;
  END IF;
  a_s := academy_minutes(p_start_a); a_e := academy_minutes(p_end_a);
  b_s := academy_minutes(p_start_b); b_e := academy_minutes(p_end_b);
  IF a_s IS NULL OR a_e IS NULL OR b_s IS NULL OR b_e IS NULL THEN RETURN true; END IF;
  RETURN a_s < b_e AND b_s < a_e;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.academy_parse_days(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.academy_minutes(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.academy_slots_overlap(text, text, text, text, text, text) TO authenticated;

-- Everything that collides with one section: same teacher, or same room, in
-- the same term. Reported whether or not it was allowed to happen, because
-- a school applying this file to a timetable it already has needs to see
-- what is already broken.
DROP FUNCTION IF EXISTS public.section_clashes(uuid);
CREATE OR REPLACE FUNCTION public.section_clashes(p_section_id uuid)
 RETURNS TABLE (out_other_id uuid, out_kind text, out_detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT b.id,
         CASE WHEN a.teacher_id IS NOT NULL AND a.teacher_id = b.teacher_id THEN 'teacher' ELSE 'room' END,
         coalesce(sb.name, 'a class') || ' ' || coalesce(b.name, '')
           || ' (' || coalesce(b.schedule_days, '?') || ' '
           || coalesce(b.start_time, '?') || '-' || coalesce(b.end_time, '?') || ')'
    FROM class_sections a
    JOIN class_sections b
      ON b.id <> a.id
     AND b.term_id IS NOT DISTINCT FROM a.term_id
    LEFT JOIN subjects sb ON sb.id = b.subject_id
   WHERE a.id = p_section_id
     AND academy_slots_overlap(a.schedule_days, a.start_time, a.end_time,
                               b.schedule_days, b.start_time, b.end_time)
     AND ((a.teacher_id IS NOT NULL AND a.teacher_id = b.teacher_id)
       OR (coalesce(trim(a.room), '') <> '' AND lower(trim(a.room)) = lower(trim(b.room))));
$function$;

GRANT EXECUTE ON FUNCTION public.section_clashes(uuid) TO authenticated;

-- The refusal. Only scheduling changes are checked, so a school that
-- applies this to a timetable that already collides can still rename a
-- class while it sorts the collisions out — but it cannot move anything
-- into a collision, and any change to a day, a time, a room or a teacher
-- has to land clean.
CREATE OR REPLACE FUNCTION public.class_section_no_clash()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_clash record;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.schedule_days IS NOT DISTINCT FROM OLD.schedule_days
     AND NEW.start_time    IS NOT DISTINCT FROM OLD.start_time
     AND NEW.end_time      IS NOT DISTINCT FROM OLD.end_time
     AND NEW.room          IS NOT DISTINCT FROM OLD.room
     AND NEW.teacher_id    IS NOT DISTINCT FROM OLD.teacher_id
     AND NEW.term_id       IS NOT DISTINCT FROM OLD.term_id THEN
    RETURN NEW;
  END IF;

  SELECT b.id,
         CASE WHEN NEW.teacher_id IS NOT NULL AND NEW.teacher_id = b.teacher_id
              THEN 'teacher' ELSE 'room' END AS kind,
         coalesce(b.name, 'another class') AS label,
         coalesce(b.schedule_days, '?') AS days,
         coalesce(b.start_time, '?') AS st,
         coalesce(b.end_time, '?') AS en
    INTO v_clash
    FROM class_sections b
   WHERE b.id <> NEW.id
     AND b.term_id IS NOT DISTINCT FROM NEW.term_id
     AND academy_slots_overlap(NEW.schedule_days, NEW.start_time, NEW.end_time,
                               b.schedule_days, b.start_time, b.end_time)
     AND ((NEW.teacher_id IS NOT NULL AND NEW.teacher_id = b.teacher_id)
       OR (coalesce(trim(NEW.room), '') <> '' AND lower(trim(NEW.room)) = lower(trim(b.room))))
   LIMIT 1;

  IF v_clash.id IS NOT NULL THEN
    IF v_clash.kind = 'teacher' THEN
      RAISE EXCEPTION 'That teacher is already taking % on % %-%. Nobody teaches two classes at once.',
        v_clash.label, v_clash.days, v_clash.st, v_clash.en;
    ELSE
      RAISE EXCEPTION 'Room % is already used by % on % %-%.',
        NEW.room, v_clash.label, v_clash.days, v_clash.st, v_clash.en;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_class_section_no_clash ON public.class_sections;
CREATE TRIGGER trg_class_section_no_clash
  BEFORE INSERT OR UPDATE ON public.class_sections
  FOR EACH ROW EXECUTE FUNCTION public.class_section_no_clash();

-- ---------------------------------------------------------------------
-- 2. ENROLMENT
-- The clash nobody checked: one student in two classes at the same hour.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.student_timetable_clash(uuid, uuid);
CREATE OR REPLACE FUNCTION public.student_timetable_clash(p_student_id uuid, p_section_id uuid)
 RETURNS TABLE (out_section_id uuid, out_label text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT b.id,
         coalesce(sb.name, 'a class') || ' ' || coalesce(b.name, '')
           || ' (' || coalesce(b.schedule_days, '?') || ' '
           || coalesce(b.start_time, '?') || '-' || coalesce(b.end_time, '?') || ')'
    FROM section_enrollments e
    JOIN class_sections b ON b.id = e.section_id
    JOIN class_sections a ON a.id = p_section_id
    LEFT JOIN subjects sb ON sb.id = b.subject_id
   WHERE e.student_id = p_student_id
     AND e.status = 'active'
     AND b.id <> p_section_id
     AND b.term_id IS NOT DISTINCT FROM a.term_id
     AND academy_slots_overlap(a.schedule_days, a.start_time, a.end_time,
                               b.schedule_days, b.start_time, b.end_time);
$function$;

GRANT EXECUTE ON FUNCTION public.student_timetable_clash(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.academy_staff_id()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('teacher', 'registrar', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot change enrolment or marks';
  END IF;
  RETURN v_emp.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.enroll_student_in_section(p_section_id uuid, p_student_id uuid)
 RETURNS public.section_enrollments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff   uuid := academy_staff_id();
  v_section class_sections;
  v_student students;
  v_taken   integer;
  v_clash   text;
  v_row     section_enrollments;
BEGIN
  SELECT * INTO v_section FROM class_sections WHERE id = p_section_id FOR UPDATE;
  IF v_section.id IS NULL THEN RAISE EXCEPTION 'That class does not exist'; END IF;

  SELECT * INTO v_student FROM students WHERE id = p_student_id;
  IF v_student.id IS NULL THEN RAISE EXCEPTION 'That student is not registered'; END IF;
  IF coalesce(v_student.status, 'enrolled') <> 'enrolled' THEN
    RAISE EXCEPTION '% is % and cannot be put in a class', v_student.name, v_student.status;
  END IF;

  IF EXISTS (SELECT 1 FROM section_enrollments
              WHERE section_id = p_section_id AND student_id = p_student_id AND status = 'active') THEN
    RAISE EXCEPTION '% is already in this class', v_student.name;
  END IF;

  -- Counted here, under the lock taken above. Capacity existed and nothing
  -- had ever read it.
  IF coalesce(v_section.capacity, 0) > 0 THEN
    SELECT count(*) INTO v_taken FROM section_enrollments
     WHERE section_id = p_section_id AND status = 'active';
    IF v_taken >= v_section.capacity THEN
      RAISE EXCEPTION 'This class is full: % of % places taken', v_taken, v_section.capacity;
    END IF;
  END IF;

  -- The clash that costs a student a lesson.
  SELECT out_label INTO v_clash FROM student_timetable_clash(p_student_id, p_section_id) LIMIT 1;
  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION '% is already in % at that time', v_student.name, v_clash;
  END IF;

  INSERT INTO section_enrollments (section_id, student_id, status)
  VALUES (p_section_id, p_student_id, 'active')
  ON CONFLICT (section_id, student_id) DO UPDATE SET status = 'active'
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.enroll_student_in_section(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. MARKS
-- A mark is a claim about a person that follows them. It is checked
-- against what the paper was out of, it is only recorded for somebody who
-- was in the class, and every change to one is kept.
-- ---------------------------------------------------------------------
ALTER TABLE public.assessment_grades ADD COLUMN IF NOT EXISTS graded_by uuid;
ALTER TABLE public.assessment_grades ADD COLUMN IF NOT EXISTS graded_at timestamp with time zone;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'assessment_grades_graded_by_fkey') THEN
    ALTER TABLE public.assessment_grades ADD CONSTRAINT assessment_grades_graded_by_fkey
      FOREIGN KEY (graded_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.assessment_grade_history (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  grade_id      uuid NOT NULL,
  assessment_id uuid,
  student_id    uuid,
  old_score     numeric,
  new_score     numeric,
  reason        text,
  changed_by    uuid,
  changed_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT assessment_grade_history_pkey PRIMARY KEY (id),
  CONSTRAINT assessment_grade_history_grade_fkey FOREIGN KEY (grade_id)
    REFERENCES public.assessment_grades(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_assessment_grade_history_grade
  ON public.assessment_grade_history (grade_id, changed_at);

CREATE OR REPLACE FUNCTION public.assessment_grade_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_max numeric; v_section uuid; v_emp uuid;
BEGIN
  SELECT a.max_score, a.section_id INTO v_max, v_section
    FROM assessments a WHERE a.id = NEW.assessment_id;
  IF v_section IS NULL THEN RAISE EXCEPTION 'That assessment does not exist'; END IF;

  IF NEW.score IS NOT NULL THEN
    IF NEW.score < 0 THEN
      RAISE EXCEPTION 'A mark cannot be below zero';
    END IF;
    IF coalesce(v_max, 0) > 0 AND NEW.score > v_max THEN
      RAISE EXCEPTION 'A mark of % is more than this assessment is out of (%)', NEW.score, v_max;
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM section_enrollments
                  WHERE section_id = v_section AND student_id = NEW.student_id AND status = 'active') THEN
    RAISE EXCEPTION 'That student is not in this class, so there is nothing to mark';
  END IF;

  BEGIN
    SELECT id INTO v_emp FROM employees
      WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
      ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  EXCEPTION WHEN OTHERS THEN v_emp := NULL;
  END;
  NEW.graded_by := v_emp;
  NEW.graded_at := now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_assessment_grade_guard ON public.assessment_grades;
CREATE TRIGGER trg_assessment_grade_guard
  BEFORE INSERT OR UPDATE OF score ON public.assessment_grades
  FOR EACH ROW EXECUTE FUNCTION public.assessment_grade_guard();

-- A mark that changed is the thing that gets disputed. What it was, what it
-- became, and who moved it are kept.
CREATE OR REPLACE FUNCTION public.assessment_grade_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.score IS NOT DISTINCT FROM OLD.score THEN RETURN NEW; END IF;
  INSERT INTO assessment_grade_history (grade_id, assessment_id, student_id, old_score, new_score, reason, changed_by)
  VALUES (NEW.id, NEW.assessment_id, NEW.student_id,
          CASE WHEN TG_OP = 'UPDATE' THEN OLD.score ELSE NULL END,
          NEW.score,
          nullif(current_setting('kareya.grade_reason', true), ''),
          NEW.graded_by);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_assessment_grade_log ON public.assessment_grades;
CREATE TRIGGER trg_assessment_grade_log
  AFTER INSERT OR UPDATE OF score ON public.assessment_grades
  FOR EACH ROW EXECUTE FUNCTION public.assessment_grade_log();

CREATE OR REPLACE FUNCTION public.grade_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'A mark change is a record of something that happened. It cannot be edited or removed.';
END;
$function$;

DROP TRIGGER IF EXISTS trg_grade_history_append_only ON public.assessment_grade_history;
CREATE TRIGGER trg_grade_history_append_only
  BEFORE UPDATE OR DELETE ON public.assessment_grade_history
  FOR EACH ROW EXECUTE FUNCTION public.grade_history_append_only();

CREATE OR REPLACE FUNCTION public.set_assessment_grade(
  p_assessment_id uuid, p_student_id uuid, p_score numeric, p_reason text DEFAULT NULL)
 RETURNS public.assessment_grades
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := academy_staff_id(); v_row assessment_grades;
BEGIN
  PERFORM set_config('kareya.grade_reason', coalesce(p_reason, ''), true);
  INSERT INTO assessment_grades (assessment_id, student_id, score)
  VALUES (p_assessment_id, p_student_id, p_score)
  ON CONFLICT (assessment_id, student_id) DO UPDATE SET score = EXCLUDED.score
  RETURNING * INTO v_row;
  PERFORM set_config('kareya.grade_reason', '', true);
  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.set_assessment_grade(uuid, uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. FEES
-- amount_paid was computed in the browser and written back whole. Payments
-- are rows now, and amount_paid is their sum — so two clerks at two
-- windows add two payments instead of overwriting one another.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.student_payments (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  invoice_id     uuid NOT NULL,
  amount         numeric NOT NULL,
  method         text DEFAULT 'cash',
  reference      text,
  received_by    uuid,
  received_at    timestamp with time zone DEFAULT now(),
  void_reason    text,
  voided_at      timestamp with time zone,
  voided_by      uuid,
  CONSTRAINT student_payments_pkey PRIMARY KEY (id),
  CONSTRAINT student_payments_invoice_fkey FOREIGN KEY (invoice_id)
    REFERENCES public.student_invoices(id) ON DELETE RESTRICT,
  CONSTRAINT student_payments_received_by_fkey FOREIGN KEY (received_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT student_payments_voided_by_fkey FOREIGN KEY (voided_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT student_payments_amount_check CHECK (amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_student_payments_invoice ON public.student_payments (invoice_id);

CREATE TABLE IF NOT EXISTS public.student_invoice_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'SIN-',
  width   integer DEFAULT 5,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT student_invoice_series_pkey PRIMARY KEY (id),
  CONSTRAINT student_invoice_series_singleton CHECK (id = true)
);
INSERT INTO public.student_invoice_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_student_invoice_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_s student_invoice_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('student_invoice_series'));
  SELECT * INTO v_s FROM student_invoice_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO student_invoice_series (id) VALUES (true) RETURNING * INTO v_s; END IF;

  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE student_invoice_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE student_invoice_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;
  RETURN coalesce(v_s.prefix, 'SIN-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 5), 1), '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.student_invoice_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.invoice_number := allocate_student_invoice_no(coalesce(NEW.issued_date, CURRENT_DATE));
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_student_invoice_number ON public.student_invoices;
CREATE TRIGGER trg_student_invoice_number
  BEFORE INSERT ON public.student_invoices
  FOR EACH ROW EXECUTE FUNCTION public.student_invoice_number();

DO $$
DECLARE r record; s record; n integer;
BEGIN
  FOR r IN SELECT invoice_number FROM public.student_invoices
            WHERE invoice_number IS NOT NULL
            GROUP BY invoice_number HAVING count(*) > 1 LOOP
    n := 0;
    FOR s IN SELECT id FROM public.student_invoices WHERE invoice_number = r.invoice_number ORDER BY created_at LOOP
      n := n + 1;
      IF n > 1 THEN UPDATE public.student_invoices SET invoice_number = invoice_number || '-' || n WHERE id = s.id; END IF;
    END LOOP;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_student_invoices_number
  ON public.student_invoices (invoice_number) WHERE invoice_number IS NOT NULL;

-- amount_paid and status are now derived. Nothing writes them by hand.
CREATE OR REPLACE FUNCTION public.student_invoice_recalc(p_invoice_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_paid numeric; v_amount numeric;
BEGIN
  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM student_payments WHERE invoice_id = p_invoice_id AND voided_at IS NULL;
  SELECT coalesce(amount, 0) INTO v_amount FROM student_invoices WHERE id = p_invoice_id;

  PERFORM set_config('kareya.academy_apply', 'on', true);
  UPDATE student_invoices
     SET amount_paid = v_paid,
         status = CASE WHEN v_paid + 0.001 >= v_amount AND v_amount > 0 THEN 'paid'
                       WHEN v_paid > 0 THEN 'partial'
                       ELSE 'unpaid' END
   WHERE id = p_invoice_id;
  PERFORM set_config('kareya.academy_apply', '', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.student_invoice_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF EXISTS (SELECT 1 FROM student_payments WHERE invoice_id = OLD.id) THEN
      RAISE EXCEPTION 'Money has been taken against this invoice. It cannot be deleted.';
    END IF;
    RETURN OLD;
  END IF;
  IF coalesce(current_setting('kareya.academy_apply', true), '') = 'on' THEN RETURN NEW; END IF;
  IF NEW.amount_paid IS DISTINCT FROM OLD.amount_paid OR NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'What has been paid is the sum of the payments taken. Record a payment rather than editing the invoice.';
  END IF;
  IF NEW.invoice_number IS DISTINCT FROM OLD.invoice_number THEN
    RAISE EXCEPTION 'An invoice number cannot be changed';
  END IF;
  IF NEW.amount IS DISTINCT FROM OLD.amount
     AND EXISTS (SELECT 1 FROM student_payments WHERE invoice_id = OLD.id AND voided_at IS NULL) THEN
    RAISE EXCEPTION 'Money has been taken against this invoice, so the amount cannot be changed.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_student_invoice_guard ON public.student_invoices;
CREATE TRIGGER trg_student_invoice_guard
  BEFORE UPDATE OR DELETE ON public.student_invoices
  FOR EACH ROW EXECUTE FUNCTION public.student_invoice_guard();

CREATE OR REPLACE FUNCTION public.record_student_payment(
  p_invoice_id uuid, p_amount numeric,
  p_method text DEFAULT 'cash', p_reference text DEFAULT NULL)
 RETURNS public.student_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp employees; v_inv student_invoices; v_paid numeric; v_row student_payments;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('registrar', 'cashier', 'accountant', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot take fee payments';
  END IF;

  -- The lock is the whole point: this is where one family's payment used
  -- to disappear when two windows were open at once.
  SELECT * INTO v_inv FROM student_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Invoice not found'; END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'A payment has to be for an amount greater than zero. To reverse one, void it.';
  END IF;

  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM student_payments WHERE invoice_id = p_invoice_id AND voided_at IS NULL;

  IF v_paid + p_amount > coalesce(v_inv.amount, 0) + 0.001 THEN
    RAISE EXCEPTION 'That is more than is outstanding: % of % has been paid, so % is left',
      v_paid, v_inv.amount, round(coalesce(v_inv.amount, 0) - v_paid, 2);
  END IF;

  INSERT INTO student_payments (invoice_id, amount, method, reference, received_by)
  VALUES (p_invoice_id, p_amount, coalesce(p_method, 'cash'), p_reference, v_emp.id)
  RETURNING * INTO v_row;

  PERFORM student_invoice_recalc(p_invoice_id);
  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.record_student_payment(uuid, numeric, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.void_student_payment(p_payment_id uuid, p_reason text)
 RETURNS public.student_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_row student_payments;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('accountant', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an accountant or a manager may void a payment';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a payment requires a reason';
  END IF;

  SELECT * INTO v_row FROM student_payments WHERE id = p_payment_id FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF v_row.voided_at IS NOT NULL THEN RAISE EXCEPTION 'That payment is already void'; END IF;

  PERFORM set_config('kareya.academy_apply', 'on', true);
  UPDATE student_payments
     SET voided_at = now(), voided_by = v_emp.id, void_reason = p_reason
   WHERE id = p_payment_id
  RETURNING * INTO v_row;
  PERFORM set_config('kareya.academy_apply', '', true);

  PERFORM student_invoice_recalc(v_row.invoice_id);
  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.void_student_payment(uuid, text) TO authenticated;

-- A receipt is a record of money that changed hands.
CREATE OR REPLACE FUNCTION public.student_payment_is_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A payment cannot be deleted. Void it, with a reason, and the record stays.';
  END IF;
  IF coalesce(current_setting('kareya.academy_apply', true), '') = 'on' THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'A payment cannot be edited. Void it and take the right one.';
END;
$function$;

DROP TRIGGER IF EXISTS trg_student_payment_is_record ON public.student_payments;
CREATE TRIGGER trg_student_payment_is_record
  BEFORE UPDATE OR DELETE ON public.student_payments
  FOR EACH ROW EXECUTE FUNCTION public.student_payment_is_record();

-- Existing invoices carry an amount_paid figure from before payments were
-- rows. It is turned into one opening payment so the two agree, rather
-- than being zeroed and the school losing what it had already collected.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id, amount_paid FROM public.student_invoices
            WHERE coalesce(amount_paid, 0) > 0
              AND NOT EXISTS (SELECT 1 FROM public.student_payments p WHERE p.invoice_id = student_invoices.id)
  LOOP
    INSERT INTO public.student_payments (invoice_id, amount, method, reference)
    VALUES (r.id, r.amount_paid, 'unknown', 'Collected before payments were recorded individually');
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 5. ONE CURRENT TERM
-- Setting it was two round-trips with nothing in between guaranteeing
-- either landed. A school could end up with none, or with two.
-- ---------------------------------------------------------------------
DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.academic_terms WHERE is_current;
  IF n > 1 THEN
    RAISE NOTICE 'More than one academic term is marked current; the constraint was not added. Pick one in Setup.';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS uq_academic_terms_current
      ON public.academic_terms ((is_current)) WHERE is_current;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.set_current_term(p_term_id uuid)
 RETURNS public.academic_terms
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := academy_staff_id(); v_term academic_terms;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM academic_terms WHERE id = p_term_id) THEN
    RAISE EXCEPTION 'That term does not exist';
  END IF;
  -- Still two statements, but one TRANSACTION — which is the whole
  -- difference. The old version sent two requests from the browser, so a
  -- failure between them left a school with no current term at all. Here
  -- either both land or neither does. (They cannot be merged into one
  -- statement: the partial unique index is checked as each row is written,
  -- so setting the new one before clearing the old one collides.)
  UPDATE academic_terms SET is_current = false WHERE is_current AND id <> p_term_id;
  UPDATE academic_terms SET is_current = true WHERE id = p_term_id;
  SELECT * INTO v_term FROM academic_terms WHERE id = p_term_id;
  RETURN v_term;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.set_current_term(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. WHAT IS ALREADY BROKEN
-- A school applying this to a timetable it has been running for a year
-- needs the existing collisions listed, not silently tolerated and not
-- silently changed.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.academy_reconciliation();
CREATE OR REPLACE FUNCTION public.academy_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- Teacher or room double-booked.
  SELECT 'section', a.id,
         coalesce(s.name, 'Class') || ' ' || coalesce(a.name, ''),
         'Collides with ' || c.out_detail || ' (' || c.out_kind || ')'
    FROM class_sections a
    LEFT JOIN subjects s ON s.id = a.subject_id
    CROSS JOIN LATERAL section_clashes(a.id) c

  UNION ALL
  -- A student in two places at once.
  SELECT 'student', st.id, st.name,
         'In two classes at the same time: ' || cs.out_label
    FROM section_enrollments e
    JOIN students st ON st.id = e.student_id
    CROSS JOIN LATERAL student_timetable_clash(e.student_id, e.section_id) cs
   WHERE e.status = 'active'

  UNION ALL
  -- Over capacity, however it got there.
  SELECT 'section', a.id,
         coalesce(s.name, 'Class') || ' ' || coalesce(a.name, ''),
         count(e.id)::text || ' enrolled in a class with ' || a.capacity::text || ' places'
    FROM class_sections a
    LEFT JOIN subjects s ON s.id = a.subject_id
    JOIN section_enrollments e ON e.section_id = a.id AND e.status = 'active'
   WHERE coalesce(a.capacity, 0) > 0
   GROUP BY a.id, s.name, a.name, a.capacity
  HAVING count(e.id) > a.capacity

  UNION ALL
  -- A mark above what the paper was out of.
  SELECT 'grade', g.id, st.name,
         'Marked ' || g.score::text || ' on an assessment out of ' || a.max_score::text
    FROM assessment_grades g
    JOIN assessments a ON a.id = g.assessment_id
    JOIN students st ON st.id = g.student_id
   WHERE g.score IS NOT NULL AND coalesce(a.max_score, 0) > 0 AND g.score > a.max_score

  UNION ALL
  -- The invoice figure and the payments taken disagree.
  SELECT 'invoice', i.id, coalesce(i.invoice_number, '—'),
         'Says ' || coalesce(i.amount_paid, 0)::text || ' paid, but the payments total '
         || coalesce((SELECT sum(p.amount) FROM student_payments p
                       WHERE p.invoice_id = i.id AND p.voided_at IS NULL), 0)::text
    FROM student_invoices i
   WHERE coalesce(i.amount_paid, 0) <> coalesce(
           (SELECT sum(p.amount) FROM student_payments p
             WHERE p.invoice_id = i.id AND p.voided_at IS NULL), 0)

  UNION ALL
  -- No current term, or more than one.
  SELECT 'term', NULL::uuid, 'Academic terms',
         CASE WHEN count(*) = 0 THEN 'No term is marked current.'
              ELSE count(*)::text || ' terms are marked current.' END
    FROM academic_terms WHERE is_current
  HAVING count(*) <> 1;
$function$;

GRANT EXECUTE ON FUNCTION public.academy_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
ALTER TABLE public.student_payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS student_payments_read ON public.student_payments;
CREATE POLICY student_payments_read ON public.student_payments
  FOR SELECT TO authenticated
  USING (public.has_any_role(ARRAY['Registrar', 'Cashier', 'Accountant', 'Manager']));

ALTER TABLE public.assessment_grade_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS assessment_grade_history_read ON public.assessment_grade_history;
CREATE POLICY assessment_grade_history_read ON public.assessment_grade_history
  FOR SELECT TO authenticated
  USING (public.has_any_role(ARRAY['Teacher', 'Registrar', 'Manager']));

ALTER TABLE public.student_invoice_series ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS student_invoice_series_read ON public.student_invoice_series;
CREATE POLICY student_invoice_series_read ON public.student_invoice_series
  FOR SELECT TO authenticated USING (public.is_employee());
DROP POLICY IF EXISTS student_invoice_series_write ON public.student_invoice_series;
CREATE POLICY student_invoice_series_write ON public.student_invoice_series
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_founder()) WITH CHECK (public.is_admin_or_founder());
