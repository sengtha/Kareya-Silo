-- =====================================================================
-- TIMETABLE AND ENROLMENT INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The module already worked out which classes collided. It did it in the
-- browser, from React state, and then drew a small red chip saying
-- "Clash". Nothing refused the save. These assertions are about the
-- difference between noticing something and preventing it.
--
-- The second group is about the clash that was never checked by anything
-- at all: one student timetabled into two classes at the same hour.
--
-- The rest guard capacity that nothing read, marks that could be any
-- number at all, and a fee payment computed in the browser as
-- amount_paid + amount and written back whole.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/academy.test.sql
--
-- Any failure aborts the run: ON_ERROR_STOP is deliberate.
-- =====================================================================

\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

CREATE OR REPLACE FUNCTION ok(cond boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF cond THEN RAISE NOTICE '  ok   %', label;
  ELSE RAISE EXCEPTION 'FAIL: %', label; END IF;
END $$;

CREATE OR REPLACE FUNCTION raises(sql text, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE sql;
  EXCEPTION WHEN others THEN RAISE NOTICE '  ok   % (refused: %)', label, left(SQLERRM, 70); RETURN;
  END;
  RAISE EXCEPTION 'FAIL: % — it was ALLOWED', label;
END $$;

CREATE OR REPLACE FUNCTION act_as(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT user_id INTO v_uid FROM employees WHERE email = p_email;
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_email)::text, false);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('a1000000-0000-0000-0000-000000000001', 'registrar@school.kh'),
  ('a1000000-0000-0000-0000-000000000002', 'sopheak@school.kh'),
  ('a1000000-0000-0000-0000-000000000003', 'vanna@school.kh'),
  ('a1000000-0000-0000-0000-000000000004', 'bopha@school.kh'),
  ('a1000000-0000-0000-0000-000000000005', 'kosal@school.kh'),
  ('a1000000-0000-0000-0000-000000000006', 'chan@school.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('b1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'Registrar',      'registrar@school.kh', ARRAY['Registrar']),
  ('b1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000002', 'Sopheak (maths)','sopheak@school.kh',   ARRAY['Teacher']),
  ('b1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000003', 'Vanna (khmer)',  'vanna@school.kh',     ARRAY['Teacher']),
  ('b1000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000004', 'Bopha (bursar)', 'bopha@school.kh',     ARRAY['Accountant']),
  ('b1000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000005', 'Kosal (driver)', 'kosal@school.kh',     ARRAY['Driver']),
  ('b1000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000006', 'Chan (science)', 'chan@school.kh',      ARRAY['Teacher'])
ON CONFLICT DO NOTHING;

INSERT INTO academic_terms (id, name, type, start_date, end_date) VALUES
  ('c1000000-0000-0000-0000-000000000001', 'Semester 1 2026', 'semester', '2026-01-06', '2026-05-29'),
  ('c1000000-0000-0000-0000-000000000002', 'Semester 2 2026', 'semester', '2026-08-03', '2026-12-18')
ON CONFLICT DO NOTHING;

INSERT INTO academic_programs (id, name, code) VALUES
  ('d1000000-0000-0000-0000-000000000001', 'Lower Secondary', 'LS')
ON CONFLICT DO NOTHING;

INSERT INTO subjects (id, name, code, program_id) VALUES
  ('e1000000-0000-0000-0000-000000000001', 'Mathematics', 'MATH', 'd1000000-0000-0000-0000-000000000001'),
  ('e1000000-0000-0000-0000-000000000002', 'Khmer',       'KHM',  'd1000000-0000-0000-0000-000000000001'),
  ('e1000000-0000-0000-0000-000000000003', 'Science',     'SCI',  'd1000000-0000-0000-0000-000000000001')
ON CONFLICT DO NOTHING;

INSERT INTO students (id, student_number, name, program_id, status) VALUES
  ('f1000000-0000-0000-0000-000000000001', 'S-001', 'Sreypov', 'd1000000-0000-0000-0000-000000000001', 'enrolled'),
  ('f1000000-0000-0000-0000-000000000002', 'S-002', 'Ratana',  'd1000000-0000-0000-0000-000000000001', 'enrolled'),
  ('f1000000-0000-0000-0000-000000000003', 'S-003', 'Mealea',  'd1000000-0000-0000-0000-000000000001', 'enrolled'),
  ('f1000000-0000-0000-0000-000000000004', 'S-004', 'Sokun',   'd1000000-0000-0000-0000-000000000001', 'graduated')
ON CONFLICT DO NOTHING;

SELECT act_as('registrar@school.kh');

\echo ''
\echo '== 1. reading a timetable the same way the browser does'

SELECT ok(academy_parse_days('Mon,Wed,Fri') = ARRAY['fri', 'mon', 'wed'],
  'a comma-separated days field is read');
SELECT ok(academy_parse_days('mon wed') = ARRAY['mon', 'wed'],
  'so is a space-separated one, in any case');
SELECT ok(academy_parse_days('Monday/Thursday') = ARRAY['mon', 'thu'],
  'and full day names separated by a slash');
SELECT ok(academy_parse_days('nonsense') = ARRAY[]::text[],
  'anything that is not a day is ignored rather than guessed at');
SELECT ok(academy_minutes('09:30') = 570, '09:30 is 570 minutes');
SELECT ok(academy_minutes('') IS NULL, 'an empty time is nothing, not midnight');

SELECT ok(academy_slots_overlap('Mon,Wed', '09:00', '10:00', 'Wed,Fri', '09:30', '10:30') = true,
  'two classes sharing Wednesday and overlapping by half an hour collide');
SELECT ok(academy_slots_overlap('Mon', '09:00', '10:00', 'Tue', '09:00', '10:00') = false,
  'the same hour on different days does not');
SELECT ok(academy_slots_overlap('Mon', '09:00', '10:00', 'Mon', '10:00', '11:00') = false,
  'back-to-back classes do not collide — one ends as the other starts');
SELECT ok(academy_slots_overlap('Mon', NULL, NULL, 'Mon', '09:00', '10:00') = true,
  'a class with a day but no times is treated as a possible collision, so somebody looks');

\echo ''
\echo '== 2. THE HEADLINE: a clash is refused, not badged'

INSERT INTO class_sections (id, subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time, capacity)
VALUES ('01000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001',
        'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002',
        '7A', 'Room 1', 'Mon,Wed,Fri', '09:00', '10:00', 2);

SELECT ok((SELECT count(*) FROM class_sections) = 1, 'the first class is created');

-- Same teacher, different room, overlapping hour. The old version drew a
-- red chip and saved it anyway.
SELECT raises($$
  INSERT INTO class_sections (subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time)
  VALUES ('e1000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001',
          'b1000000-0000-0000-0000-000000000002', '7B', 'Room 9', 'Mon', '09:30', '10:30')
$$, 'A TEACHER CANNOT BE PUT IN TWO CLASSES AT ONCE — this is the defect this file exists for');

-- Same room, different teacher, overlapping hour.
SELECT raises($$
  INSERT INTO class_sections (subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time)
  VALUES ('e1000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001',
          'b1000000-0000-0000-0000-000000000003', '7C', 'room 1', 'Wed', '09:15', '09:45')
$$, 'and one room cannot hold two classes at once, whatever case it is typed in');

SELECT ok((SELECT count(*) FROM class_sections) = 1,
  'neither of the refused classes was created');

-- The same teacher in a different term is not a clash: it is next year.
INSERT INTO class_sections (id, subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time)
VALUES ('01000000-0000-0000-0000-000000000009', 'e1000000-0000-0000-0000-000000000001',
        'c1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000002',
        '7A next term', 'Room 1', 'Mon,Wed,Fri', '09:00', '10:00');
SELECT ok((SELECT count(*) FROM class_sections) = 2,
  'the same teacher in the same room in a DIFFERENT term is fine — it is next semester');

-- Non-overlapping is fine.
INSERT INTO class_sections (id, subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time, capacity)
VALUES ('01000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000002',
        'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000003',
        '7A Khmer', 'Room 2', 'Mon,Wed,Fri', '10:00', '11:00', 30);
SELECT ok((SELECT count(*) FROM class_sections) = 3,
  'a class in the next hour, another room, another teacher, is created');

\echo ''
\echo '== 3. moving a class into a clash is refused too'

-- Moving it earlier AND into the room maths is already using.
SELECT raises($$
  UPDATE class_sections SET start_time = '09:15', room = 'Room 1'
   WHERE id = '01000000-0000-0000-0000-000000000002'
$$, 'dragging a class back into an hour and a room another class already has is refused');

-- Moving it earlier on its own is not a clash: different room, different
-- teacher. The check refuses collisions, not rescheduling.
UPDATE class_sections SET start_time = '09:15', end_time = '09:45'
 WHERE id = '01000000-0000-0000-0000-000000000002';
SELECT ok((SELECT start_time FROM class_sections WHERE id = '01000000-0000-0000-0000-000000000002') = '09:15',
  'but moving it earlier in its own room with its own teacher is allowed');

UPDATE class_sections SET start_time = '10:00', end_time = '11:00'
 WHERE id = '01000000-0000-0000-0000-000000000002';

-- Renaming is not a scheduling change, so a school with a timetable that
-- already collides can still tidy up while it sorts the collisions out.
UPDATE class_sections SET name = '7A Khmer (main)' WHERE id = '01000000-0000-0000-0000-000000000002';
SELECT ok((SELECT name FROM class_sections WHERE id = '01000000-0000-0000-0000-000000000002') = '7A Khmer (main)',
  'renaming a class is not a scheduling change and goes through');

SELECT ok((SELECT count(*) FROM section_clashes('01000000-0000-0000-0000-000000000001')) = 0,
  'no class collides with the maths class');

\echo ''
\echo '== 4. THE CLASH NOBODY EVER CHECKED: a student in two places at once'

-- The browser compared teachers and rooms. It never looked at students.
SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001');
SELECT ok((SELECT count(*) FROM section_enrollments WHERE status = 'active') = 1,
  'a student is put in the maths class');

-- Science at the same hour, taught by somebody else in another room: no
-- teacher clash, no room clash, so the old check saw nothing wrong.
INSERT INTO class_sections (id, subject_id, term_id, teacher_id, name, room, schedule_days, start_time, end_time, capacity)
-- Chan, not Vanna: Vanna already has Khmer at 10:00 on Monday, and the
-- trigger refuses that. The point here is a clash with no teacher and no
-- room involved at all.
VALUES ('01000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000003',
        'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000006',
        '7A Science', 'Lab', 'Mon', '09:30', '10:30', 30);

SELECT ok((SELECT count(*) FROM section_clashes('01000000-0000-0000-0000-000000000003')) = 0,
  'the science class collides with no teacher and no room');
SELECT ok((SELECT count(*) FROM student_timetable_clash(
             'f1000000-0000-0000-0000-000000000001', '01000000-0000-0000-0000-000000000003')) = 1,
  'but it collides with what that student is already sitting in');
SELECT raises($$SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000001')$$,
  'SO THE ENROLMENT IS REFUSED — nothing checked this before, anywhere');

SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000002');
SELECT ok((SELECT count(*) FROM section_enrollments
            WHERE section_id = '01000000-0000-0000-0000-000000000003' AND status = 'active') = 1,
  'a student who is free at that hour is enrolled');

-- The Khmer class runs 10:00-11:00, after maths. No clash.
SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001');
SELECT ok((SELECT count(*) FROM section_enrollments
            WHERE student_id = 'f1000000-0000-0000-0000-000000000001' AND status = 'active') = 2,
  'and the same student takes the class in the next hour');

\echo ''
\echo '== 5. capacity was decoration'

-- The maths class has room for 2 and one place is taken.
SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000003');
SELECT ok((SELECT count(*) FROM section_enrollments
            WHERE section_id = '01000000-0000-0000-0000-000000000001' AND status = 'active') = 2,
  'the second of two places is taken');
SELECT raises($$SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002')$$,
  'a third student is refused a class with two places');

SELECT raises($$SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000004')$$,
  'a student who has graduated cannot be put in a class');
SELECT raises($$SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001')$$,
  'and enrolling somebody twice in the same class is refused');

\echo ''
\echo '== 6. a mark is checked against what the paper was out of'

INSERT INTO assessments (id, section_id, name, type, max_score, weight)
VALUES ('02000000-0000-0000-0000-000000000001', '01000000-0000-0000-0000-000000000001',
        'Midterm', 'midterm', 50, 1);

SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 42);
SELECT ok((SELECT score FROM assessment_grades WHERE student_id = 'f1000000-0000-0000-0000-000000000001') = 42,
  'a mark within range is recorded');

SELECT raises($$SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 500)$$,
  '500 out of 50 is refused — it used to be accepted and the average went over 100%');
SELECT raises($$SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', -1)$$,
  'and so is a mark below zero');
SELECT raises($$SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', 30)$$,
  'a student who is not in the class cannot be marked for it');

SELECT ok((SELECT score FROM assessment_grades WHERE student_id = 'f1000000-0000-0000-0000-000000000001') = 42,
  'the refusals left the mark alone');

\echo ''
\echo '== 7. a mark that changed is the thing that gets disputed'

SELECT ok((SELECT count(*) FROM assessment_grade_history) = 1,
  'recording the first mark left a record');
SELECT ok((SELECT graded_by FROM assessment_grades WHERE student_id = 'f1000000-0000-0000-0000-000000000001')
          = 'b1000000-0000-0000-0000-000000000001',
  'and who marked it is taken from the session');

SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 46,
                            'Question 4 was marked wrong on the first pass');

SELECT ok((SELECT count(*) FROM assessment_grade_history) = 2,
  'changing it left a second record');
SELECT ok((SELECT old_score FROM assessment_grade_history WHERE new_score = 46) = 42,
  'which says what the mark used to be');
SELECT ok((SELECT reason FROM assessment_grade_history WHERE new_score = 46)
          = 'Question 4 was marked wrong on the first pass',
  'and why it moved');
SELECT ok((SELECT changed_by FROM assessment_grade_history WHERE new_score = 46)
          = 'b1000000-0000-0000-0000-000000000001',
  'and who moved it');

SELECT raises($$UPDATE assessment_grade_history SET old_score = 46$$,
  'a mark-change record cannot be edited');
SELECT raises($$DELETE FROM assessment_grade_history$$,
  'nor removed');

\echo ''
\echo '== 8. fees: a payment is a row, not a running total in a browser'

INSERT INTO fee_structures (id, name, program_id, term_id, amount) VALUES
  ('03000000-0000-0000-0000-000000000001', 'Semester 1 tuition',
   'd1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 200);

INSERT INTO student_invoices (id, student_id, term_id, fee_structure_id, description, amount)
VALUES ('04000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
        'c1000000-0000-0000-0000-000000000001', '03000000-0000-0000-0000-000000000001',
        'Semester 1 tuition', 200);

SELECT ok((SELECT invoice_number FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001')
            LIKE 'SIN-' || to_char(CURRENT_DATE, 'YYYY') || '-%',
  'the invoice number comes from the database, not from Date.now()');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_student_invoices_number'),
  'and a unique index makes a duplicate impossible');

SELECT act_as('bopha@school.kh');
SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 80, 'cash', 'Receipt 001');

SELECT ok((SELECT amount_paid FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 80,
  'a part payment is recorded');
SELECT ok((SELECT status FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 'partial',
  'and the invoice reads partial');
SELECT ok((SELECT received_by FROM student_payments WHERE reference = 'Receipt 001')
          = 'b1000000-0000-0000-0000-000000000004',
  'with who took the money');

-- Two windows open at once. Under the old code each read amount_paid = 80,
-- added its own figure and wrote the whole number back, so one payment
-- disappeared. These are two rows and they both count.
SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 60, 'cash', 'Receipt 002');
SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 60, 'cash', 'Receipt 003');

SELECT ok((SELECT amount_paid FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 200,
  'THREE PAYMENTS ADD UP — none of them overwrote another');
SELECT ok((SELECT status FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 'paid',
  'and the invoice is settled');
SELECT ok((SELECT count(*) FROM student_payments WHERE invoice_id = '04000000-0000-0000-0000-000000000001') = 3,
  'each payment is its own receipt');

\echo ''
\echo '== 9. what a payment cannot be'

SELECT raises($$SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 10)$$,
  'paying more than is owed is refused');
SELECT raises($$SELECT record_student_payment('04000000-0000-0000-0000-000000000001', -50)$$,
  'a negative payment is refused — it used to be a way to un-pay an invoice');
SELECT raises($$SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 0)$$,
  'and so is a payment of nothing');

SELECT raises($$UPDATE student_invoices SET amount_paid = 0 WHERE id = '04000000-0000-0000-0000-000000000001'$$,
  'what has been paid cannot be edited onto the invoice by hand');
SELECT raises($$UPDATE student_invoices SET status = 'unpaid' WHERE id = '04000000-0000-0000-0000-000000000001'$$,
  'nor can the status');
SELECT raises($$UPDATE student_invoices SET amount = 5000 WHERE id = '04000000-0000-0000-0000-000000000001'$$,
  'nor the amount, once money has been taken against it');
SELECT raises($$DELETE FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001'$$,
  'and an invoice with payments cannot be deleted');
SELECT raises($$UPDATE student_payments SET amount = 1 WHERE reference = 'Receipt 001'$$,
  'a receipt cannot be edited');
SELECT raises($$DELETE FROM student_payments WHERE reference = 'Receipt 001'$$,
  'nor deleted');

\echo ''
\echo '== 10. voiding a payment puts the money back on the invoice'

SELECT raises($$SELECT void_student_payment((SELECT id FROM student_payments WHERE reference = 'Receipt 003'), '  ')$$,
  'voiding a payment without a reason is refused');

SELECT void_student_payment((SELECT id FROM student_payments WHERE reference = 'Receipt 003'),
                            'Cheque bounced');

SELECT ok((SELECT amount_paid FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 140,
  'the invoice drops back by the voided amount');
SELECT ok((SELECT status FROM student_invoices WHERE id = '04000000-0000-0000-0000-000000000001') = 'partial',
  'and reads partial again');
SELECT ok((SELECT void_reason FROM student_payments WHERE reference = 'Receipt 003') = 'Cheque bounced',
  'the receipt stays, marked void, with the reason');
SELECT raises($$SELECT void_student_payment((SELECT id FROM student_payments WHERE reference = 'Receipt 003'), 'again')$$,
  'voiding the same payment twice is refused');

SELECT act_as('registrar@school.kh');
SELECT raises($$SELECT void_student_payment((SELECT id FROM student_payments WHERE reference = 'Receipt 002'), 'no')$$,
  'a registrar cannot void a payment — that is an accountant or a manager');

\echo ''
\echo '== 11. exactly one current term'

SELECT act_as('registrar@school.kh');
SELECT set_current_term('c1000000-0000-0000-0000-000000000001');
SELECT ok((SELECT count(*) FROM academic_terms WHERE is_current) = 1,
  'setting the current term leaves exactly one');
SELECT ok((SELECT id FROM academic_terms WHERE is_current) = 'c1000000-0000-0000-0000-000000000001',
  'and it is the right one');

SELECT set_current_term('c1000000-0000-0000-0000-000000000002');
SELECT ok((SELECT count(*) FROM academic_terms WHERE is_current) = 1,
  'moving it to another term still leaves exactly one');
SELECT ok((SELECT id FROM academic_terms WHERE is_current) = 'c1000000-0000-0000-0000-000000000002',
  'the new one');

SELECT raises($$UPDATE academic_terms SET is_current = true WHERE id = 'c1000000-0000-0000-0000-000000000001'$$,
  'marking a second term current is refused by the database, not by convention');

\echo ''
\echo '== 12. who may do what'

SELECT act_as('kosal@school.kh');
SELECT raises($$SELECT enroll_student_in_section('01000000-0000-0000-0000-000000000003', 'f1000000-0000-0000-0000-000000000003')$$,
  'a driver cannot enrol a student');
SELECT raises($$SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 20)$$,
  'nor change a mark');
SELECT raises($$SELECT record_student_payment('04000000-0000-0000-0000-000000000001', 10)$$,
  'nor take a fee payment');
SELECT raises($$SELECT set_current_term('c1000000-0000-0000-0000-000000000001')$$,
  'nor decide which term the school is in');

SELECT act_as('sopheak@school.kh');
SELECT set_assessment_grade('02000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000003', 31);
SELECT ok((SELECT score FROM assessment_grades WHERE student_id = 'f1000000-0000-0000-0000-000000000003') = 31,
  'a teacher can mark');

SELECT act_as('registrar@school.kh');

\echo ''
\echo '== 13. reconciliation names what is already broken'

SELECT ok(NOT EXISTS (SELECT 1 FROM academy_reconciliation() WHERE out_kind = 'section'),
  'no class collides with another');
SELECT ok(NOT EXISTS (SELECT 1 FROM academy_reconciliation() WHERE out_kind = 'student'),
  'no student is in two places at once');
SELECT ok(NOT EXISTS (SELECT 1 FROM academy_reconciliation() WHERE out_kind = 'grade'),
  'no mark is above what its paper was out of');
SELECT ok(NOT EXISTS (SELECT 1 FROM academy_reconciliation() WHERE out_kind = 'invoice'),
  'every invoice agrees with the payments taken against it');
SELECT ok(NOT EXISTS (SELECT 1 FROM academy_reconciliation() WHERE out_kind = 'term'),
  'and exactly one term is current');

\echo ''
\echo '===================================================================='
\echo ' ACADEMY: all assertions passed'
\echo '===================================================================='
