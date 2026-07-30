-- =====================================================================
-- CONSTRUCTION PROGRAMME — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A bar chart draws what somebody already worked out. A programme works
-- it out. The difference is the critical path, and the assertions below
-- are about the four ways a critical path is got wrong.
--
-- THE ARITHMETIC. A forward pass, a backward pass, and float as the gap
-- between them. Every figure here was worked out on paper first and is
-- asserted as a number, not as "looks about right".
--
-- WORKING DAYS, NOT CALENDAR DAYS. Nobody pours concrete on a Sunday. A
-- programme counted in calendar days quietly promises a handover on a
-- rest day, and the error compounds over every activity after it.
--
-- A LOOP IS NOT A SCHEDULING PROBLEM. A waiting for B while B waits for A
-- cannot be built. It is refused as it is drawn.
--
-- AND A BASELINE, because a plan that follows reality is always on time.
--
-- The programme below is five activities laid out so the answer can be
-- checked by hand:
--
--   Setup (2d) ─┬─ Foundations (5d) ── Slab (3d) ─┬─ Handover (milestone)
--               └─ Fencing (4d) ─────────────────┘
--
-- Setup 0→2, Foundations 2→7, Slab 7→10, Fencing 2→6, Handover at 10.
-- The job is 10 working days. Fencing has 4 days of float; everything
-- else is critical.
--
-- Durations are invented for the arithmetic. They are not output rates
-- and nothing here is a suggestion about how long anything takes.
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
  ('f1100000-0000-0000-0000-000000000001', 'boss@build.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles, status) VALUES
  ('f1200000-0000-0000-0000-000000000001', 'f1100000-0000-0000-0000-000000000001',
   'Rithy (site manager)', 'boss@build.kh', ARRAY['Site Manager','Manager'], 'active')
ON CONFLICT DO NOTHING;

SELECT act_as('boss@build.kh');

-- 1 June 2026 is a Monday. A six-day week, which is ordinary here.
INSERT INTO construction_projects (id, name, code, start_date, status, work_days, observes_holidays)
VALUES ('f1300000-0000-0000-0000-000000000001', 'Toul Kork villa', 'TK-01',
        '2026-06-01', 'active', ARRAY[1,2,3,4,5,6], true)
ON CONFLICT DO NOTHING;

\set PROJ '''f1300000-0000-0000-0000-000000000001'''

INSERT INTO programme_activities (id, project_id, code, name, duration_days, is_milestone, sort_order) VALUES
  ('f1400000-0000-0000-0000-000000000001', :PROJ, 'A', 'Site setup',  2, false, 1),
  ('f1400000-0000-0000-0000-000000000002', :PROJ, 'B', 'Foundations', 5, false, 2),
  ('f1400000-0000-0000-0000-000000000003', :PROJ, 'C', 'Slab',        3, false, 3),
  ('f1400000-0000-0000-0000-000000000004', :PROJ, 'D', 'Fencing',     4, false, 4),
  ('f1400000-0000-0000-0000-000000000005', :PROJ, 'E', 'Handover',    0, true,  5);

INSERT INTO activity_links (predecessor_id, successor_id) VALUES
  ('f1400000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000002'),
  ('f1400000-0000-0000-0000-000000000002', 'f1400000-0000-0000-0000-000000000003'),
  ('f1400000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000004'),
  ('f1400000-0000-0000-0000-000000000003', 'f1400000-0000-0000-0000-000000000005'),
  ('f1400000-0000-0000-0000-000000000004', 'f1400000-0000-0000-0000-000000000005');

\echo ''
\echo '== 1. nothing is worked out until somebody asks'

SELECT ok((SELECT count(*) FROM programme_activities WHERE early_start IS NOT NULL) = 0,
  'an activity has no dates until the programme is worked out');
SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_issue ILIKE '%never been worked out%'),
  'and that is reported rather than left looking finished');

\echo ''
\echo '== 2. the forward pass'

SELECT ok((SELECT out_activities FROM schedule_programme(:PROJ)) = 5,
  'five activities are scheduled');
SELECT ok((SELECT out_duration FROM schedule_programme(:PROJ)) = 10,
  'and the job is ten working days end to end');

SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'A') = 0,
  'setup starts on day nought, because nothing comes before it');
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'B') = 2,
  'foundations start the day setup finishes — that is what finish-to-start means');
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'C') = 7,
  'the slab waits for five days of foundations: 2 + 5');
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'D') = 2,
  'fencing also follows setup, and does NOT wait for the foundations');
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'E') = 10,
  'handover waits for the LONGER of the two branches, not the first one to finish');
SELECT ok((SELECT early_finish FROM programme_activities WHERE code = 'E') = 10,
  'and a milestone finishes the moment it starts, which is what zero duration is');

\echo ''
\echo '== 3. the backward pass, and float'

SELECT ok((SELECT late_start FROM programme_activities WHERE code = 'D') = 6,
  'fencing could start as late as day six and still not delay handover');
SELECT ok((SELECT total_float FROM programme_activities WHERE code = 'D') = 4,
  'so it has four days of float');
SELECT ok((SELECT is_critical FROM programme_activities WHERE code = 'D') = false,
  'and it is not on the critical path');

SELECT ok((SELECT total_float FROM programme_activities WHERE code = 'A') = 0,
  'setup has no float at all');
SELECT ok((SELECT total_float FROM programme_activities WHERE code = 'B') = 0,
  'nor foundations');
SELECT ok((SELECT total_float FROM programme_activities WHERE code = 'C') = 0,
  'nor the slab');
SELECT ok((SELECT out_critical FROM schedule_programme(:PROJ)) = 4,
  'four of the five are critical — everything except the fencing');

\echo ''
\echo '== 4. working days, not calendar days'

-- Day 0 is Monday 1 June. A six-day week, so Sunday the 7th is skipped:
-- offset 5 is Saturday the 6th and offset 6 is Monday the 8th.
SELECT ok(work_day_at(:PROJ, 0) = '2026-06-01',
  'day nought is the first working day of the job');
SELECT ok(work_day_at(:PROJ, 5) = '2026-06-06',
  'five working days on is the Saturday, because Saturday is worked here');
SELECT ok(work_day_at(:PROJ, 6) = '2026-06-08',
  'and the next one steps over the Sunday');
SELECT ok((SELECT out_finish FROM programme_dates(:PROJ) WHERE out_name = 'Handover') = '2026-06-12',
  'so a ten-day job starting Monday the 1st hands over on Friday the 12th');

SELECT ok((SELECT out_finish FROM programme_dates(:PROJ) WHERE out_code = 'A') = '2026-06-02',
  'a two-day activity ends on its LAST working day, not the day after it');

-- Khmer New Year is the obvious case, but any registered holiday counts.
INSERT INTO holidays (name, date) VALUES ('Test holiday', '2026-06-03');
SELECT ok(work_day_at(:PROJ, 2) = '2026-06-04',
  'a public holiday is not a working day, so the programme steps over it');
SELECT ok((SELECT out_finish FROM programme_dates(:PROJ) WHERE out_name = 'Handover') = '2026-06-13',
  'and the whole job moves out a day with it');
DELETE FROM holidays WHERE name = 'Test holiday';

UPDATE construction_projects SET work_days = NULL WHERE id = :PROJ;
SELECT ok(work_day_at(:PROJ, 6) = '2026-06-07',
  'with no working week set, every day counts — including the Sunday');
SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_issue ILIKE '%seven-day week%'),
  'which is reported, because nobody meant to say that');
UPDATE construction_projects SET work_days = ARRAY[1,2,3,4,5,6] WHERE id = :PROJ;

\echo ''
\echo '== 5. a loop cannot be built'

SELECT raises($$INSERT INTO activity_links (predecessor_id, successor_id)
  VALUES ('f1400000-0000-0000-0000-000000000005', 'f1400000-0000-0000-0000-000000000001')$$,
  'handover cannot come before setup when setup already leads to handover');

SELECT raises($$INSERT INTO activity_links (predecessor_id, successor_id)
  VALUES ('f1400000-0000-0000-0000-000000000003', 'f1400000-0000-0000-0000-000000000002')$$,
  'and neither can the slab come before the foundations it sits on');

SELECT raises($$INSERT INTO activity_links (predecessor_id, successor_id)
  VALUES ('f1400000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000001')$$,
  'nor can an activity follow itself');

SELECT raises($$INSERT INTO activity_links (predecessor_id, successor_id)
  VALUES ('f1400000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000002')$$,
  'the same link twice is refused — logic drawn twice is still one dependency');

INSERT INTO construction_projects (id, name, start_date, work_days)
VALUES ('f1300000-0000-0000-0000-000000000002', 'Another site', '2026-06-01', ARRAY[1,2,3,4,5,6]);
INSERT INTO programme_activities (id, project_id, name, duration_days)
VALUES ('f1400000-0000-0000-0000-000000000009', 'f1300000-0000-0000-0000-000000000002', 'Elsewhere', 3);
SELECT raises($$INSERT INTO activity_links (predecessor_id, successor_id)
  VALUES ('f1400000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000009')$$,
  'and an activity on another site cannot be wired into this programme');

\echo ''
\echo '== 6. lags and leads'

-- Concrete has to cure. The slab cannot start the day the foundations
-- finish; it waits three days.
UPDATE activity_links SET lag_days = 3
 WHERE predecessor_id = 'f1400000-0000-0000-0000-000000000002'
   AND successor_id = 'f1400000-0000-0000-0000-000000000003';
SELECT schedule_programme(:PROJ);
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'C') = 10,
  'a three-day cure pushes the slab from day seven to day ten');
SELECT ok((SELECT out_duration FROM schedule_programme(:PROJ)) = 13,
  'and the job grows by exactly those three days, because the slab is critical');
SELECT ok((SELECT total_float FROM programme_activities WHERE code = 'D') = 7,
  'the fencing gains that float rather than losing it');

-- A lead: start the fencing two days before setup is finished.
UPDATE activity_links SET lag_days = -2
 WHERE predecessor_id = 'f1400000-0000-0000-0000-000000000001'
   AND successor_id = 'f1400000-0000-0000-0000-000000000004';
SELECT schedule_programme(:PROJ);
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'D') = 0,
  'a negative lag is a lead, and the fencing starts alongside the setup');

-- Put it back.
UPDATE activity_links SET lag_days = 0
 WHERE predecessor_id = 'f1400000-0000-0000-0000-000000000001'
   AND successor_id = 'f1400000-0000-0000-0000-000000000004';
UPDATE activity_links SET lag_days = 0
 WHERE predecessor_id = 'f1400000-0000-0000-0000-000000000002'
   AND successor_id = 'f1400000-0000-0000-0000-000000000003';
SELECT schedule_programme(:PROJ);

\echo ''
\echo '== 7. start-to-start'

-- Blockwork can begin once the slab is a couple of days in, rather than
-- waiting for all of it.
INSERT INTO programme_activities (id, project_id, code, name, duration_days, sort_order)
VALUES ('f1400000-0000-0000-0000-000000000006', :PROJ, 'F', 'Blockwork', 4, 6);
INSERT INTO activity_links (predecessor_id, successor_id, link_type, lag_days)
VALUES ('f1400000-0000-0000-0000-000000000003', 'f1400000-0000-0000-0000-000000000006', 'SS', 2);
SELECT schedule_programme(:PROJ);
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'F') = 9,
  'start-to-start with two days lag: blockwork begins two days after the slab starts, not after it ends');

\echo ''
\echo '== 8. the baseline, and slippage'

SELECT raises($$SELECT baseline_programme('f1300000-0000-0000-0000-000000000002')$$,
  'a programme that was never worked out cannot be frozen');

SELECT ok(baseline_programme(:PROJ) = 6,
  'freezing the programme records all six activities');
SELECT ok((SELECT count(*) FROM programme_slippage(:PROJ)) = 0,
  'and nothing has slipped the moment it is frozen');

-- The foundations take seven days instead of five.
UPDATE programme_activities SET duration_days = 7 WHERE code = 'B';
SELECT schedule_programme(:PROJ);

SELECT ok((SELECT out_slip_days FROM programme_dates(:PROJ) WHERE out_code = 'C') = 2,
  'two extra days on the foundations put the slab two days late');
SELECT ok((SELECT out_slip_days FROM programme_dates(:PROJ) WHERE out_code = 'E') = 2,
  'and handover moves the same two days, because the slab is on the critical path');
SELECT ok((SELECT out_slip_days FROM programme_dates(:PROJ) WHERE out_code = 'D') = 0,
  'the fencing does not move at all — it had float to absorb it');
SELECT ok((SELECT out_slip_days FROM programme_dates(:PROJ) WHERE out_code = 'B') = 2,
  'the activity that caused it is named too');

SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_label = 'Foundations' AND out_issue ILIKE '%critical path%'),
  'a critical activity running late is reported as moving handover with it');
SELECT ok(NOT EXISTS (SELECT 1 FROM programme_reconciliation()
                       WHERE out_label = 'Fencing' AND out_issue ILIKE '%critical path%'),
  'and one with float is not, because it has not moved anything');

-- Absorbing the slip: shorten the slab by the same two days.
UPDATE programme_activities SET duration_days = 1 WHERE code = 'C';
SELECT schedule_programme(:PROJ);
SELECT ok((SELECT out_slip_days FROM programme_dates(:PROJ) WHERE out_code = 'E') = 0,
  'pulling two days back out of the slab puts handover back on the baseline date');

UPDATE programme_activities SET duration_days = 3 WHERE code = 'C';
UPDATE programme_activities SET duration_days = 5 WHERE code = 'B';
SELECT schedule_programme(:PROJ);

\echo ''
\echo '== 9. what an activity is not allowed to be'

SELECT raises($$INSERT INTO programme_activities (project_id, name, duration_days, is_milestone)
  VALUES ('f1300000-0000-0000-0000-000000000001', 'A long milestone', 5, true)$$,
  'a milestone with a duration is refused — that is an activity');

SELECT raises($$INSERT INTO programme_activities (project_id, name, duration_days)
  VALUES ('f1300000-0000-0000-0000-000000000001', 'Negative work', -2)$$,
  'and so is a negative duration');

SELECT raises($$INSERT INTO programme_activities (project_id, name, percent_complete)
  VALUES ('f1300000-0000-0000-0000-000000000001', 'Over-complete', 140)$$,
  'nothing is more than finished');

SELECT raises($$INSERT INTO programme_activities (project_id, name, actual_start, actual_finish)
  VALUES ('f1300000-0000-0000-0000-000000000001', 'Backwards', '2026-06-10', '2026-06-02')$$,
  'and nothing finishes before it started');

\echo ''
\echo '== 10. what needs looking at'

UPDATE programme_activities SET percent_complete = 100 WHERE code = 'A';
SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_label = 'Site setup' AND out_issue ILIKE '%no finish date%'),
  'finished on paper with no finish date is reported');
UPDATE programme_activities SET actual_start = '2026-06-01', actual_finish = '2026-06-02'
 WHERE code = 'A';
SELECT ok(NOT EXISTS (SELECT 1 FROM programme_reconciliation()
                       WHERE out_label = 'Site setup' AND out_issue ILIKE '%no finish date%'),
  'and stops being reported once the date is recorded');

UPDATE programme_activities SET actual_finish = '2026-06-09', actual_start = NULL WHERE code = 'D';
SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_label = 'Fencing' AND out_issue ILIKE '%no start date%'),
  'a finish with no start is reported');
UPDATE programme_activities SET actual_finish = NULL WHERE code = 'D';

INSERT INTO programme_activities (id, project_id, name, duration_days, sort_order)
VALUES ('f1400000-0000-0000-0000-000000000007', :PROJ, 'Landscaping', 3, 9);
SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_label = 'Landscaping' AND out_issue ILIKE '%nothing before it%'),
  'an activity with no logic either way is a note beside the programme, not on it');

SELECT ok(EXISTS (SELECT 1 FROM programme_reconciliation()
                   WHERE out_label = 'Another site' AND out_issue ILIKE '%no baseline%'),
  'and a programme with no baseline is reported, because it always looks on time');

\echo ''
\echo '== 11. the money against the calendar'

SELECT ok((SELECT out_computed FROM programme_value(:PROJ, '2026-06-30')) = false,
  'with no activity saying which bill items it delivers, the value is unknown');
SELECT ok((SELECT out_problem FROM programme_value(:PROJ, '2026-06-30')) ILIKE '%not joined up%',
  'and it says so rather than reporting nought earned');

-- Left as a draft: the estimating vertical refuses edits to an estimate
-- that has already been sent, which is right, and the bill items have to
-- go in before it is issued.
INSERT INTO construction_estimates (id, title, project_id)
VALUES ('f1500000-0000-0000-0000-000000000001', 'Villa BOQ', :PROJ);
-- The rate and the amount are worked out by the estimating vertical from
-- the cost plus the estimate's overhead and margin, which are both nought
-- here. Typing amount_sell would have been overwritten, and the test
-- would have been testing the wrong thing.
INSERT INTO boq_items (id, estimate_id, description, unit, quantity, rate_cost)
VALUES ('f1600000-0000-0000-0000-000000000001', 'f1500000-0000-0000-0000-000000000001',
        'Foundation concrete', 'm3', 20, 100),
       ('f1600000-0000-0000-0000-000000000002', 'f1500000-0000-0000-0000-000000000001',
        'Slab concrete', 'm3', 10, 100);
SELECT ok((SELECT amount_sell FROM boq_items WHERE description = 'Foundation concrete') = 2000,
  'the bill values itself: 20 at 100 is 2,000');
INSERT INTO activity_boq_items (activity_id, boq_item_id) VALUES
  ('f1400000-0000-0000-0000-000000000002', 'f1600000-0000-0000-0000-000000000001'),
  ('f1400000-0000-0000-0000-000000000003', 'f1600000-0000-0000-0000-000000000002');

SELECT schedule_programme(:PROJ);
SELECT ok((SELECT out_computed FROM programme_value(:PROJ, '2026-06-30')) = true,
  'once the bars name their bill items, the programme can be valued');
SELECT ok((SELECT out_planned FROM programme_value(:PROJ, '2026-06-30')) = 3000,
  'by the end of June the programme says both pours should be done — 3,000');
SELECT ok((SELECT out_planned FROM programme_value(:PROJ, '2026-06-05')) = 0,
  'and by the 5th neither has finished, so nothing was planned to be earned yet');

UPDATE programme_activities SET percent_complete = 50 WHERE code = 'B';
SELECT ok((SELECT out_earned FROM programme_value(:PROJ, '2026-06-30')) = 1000,
  'half the foundations done is half its value earned');
SELECT ok((SELECT out_certified FROM programme_value(:PROJ, '2026-06-30')) = 0,
  'but nothing is certified until the surveyor says so — earned and certified are different numbers');

\echo ''
\echo '== 12. a constraint date'

-- The client will not release the site until the 15th, whatever the
-- logic says.
UPDATE programme_activities SET constraint_start = '2026-06-15' WHERE code = 'D';
SELECT schedule_programme(:PROJ);
SELECT ok((SELECT out_start FROM programme_dates(:PROJ) WHERE out_code = 'D') >= '2026-06-15',
  'a date somebody insists on holds the activity back');
SELECT ok((SELECT early_start FROM programme_activities WHERE code = 'D') >
          (SELECT early_start FROM programme_activities WHERE code = 'A'),
  'and it still respects the logic in front of it');
UPDATE programme_activities SET constraint_start = NULL WHERE code = 'D';
SELECT schedule_programme(:PROJ);

\echo ''
\echo '===================================================================='
\echo ' PROGRAMME: all assertions passed'
\echo '===================================================================='
