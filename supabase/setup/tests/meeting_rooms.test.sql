-- =====================================================================
-- MEETING ROOMS — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A meeting room existed twice already and neither was this one:
-- cowork_spaces sells a room to a paying member, equipment_bookings
-- charges an instrument to a grant. Staff booking a room for nothing had
-- nowhere to go, and nor did the three things that decide whether office
-- room booking works at all.
--
-- ONE ROOM, ONE MEETING. Two people booking from two machines in the same
-- second is exactly what happens at five to nine, so the database has to
-- be the one that says no.
--
-- WHETHER THE PEOPLE ARE FREE. The room is rarely the scarce thing.
--
-- AND ROOMS HELD AND NOT USED, which is the commonest complaint about
-- every room booking system ever built.
--
-- Times below are fixed instants so nothing depends on when the suite
-- runs, except where the point is that something has passed.
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
  ('d1100000-0000-0000-0000-000000000001', 'sophea@office.kh'),
  ('d1100000-0000-0000-0000-000000000002', 'ratana@office.kh'),
  ('d1100000-0000-0000-0000-000000000003', 'dara@office.kh'),
  ('d1100000-0000-0000-0000-000000000004', 'leaving@office.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles, status) VALUES
  ('d1200000-0000-0000-0000-000000000001', 'd1100000-0000-0000-0000-000000000001',
   'Sophea', 'sophea@office.kh', ARRAY['Manager'], 'active'),
  ('d1200000-0000-0000-0000-000000000002', 'd1100000-0000-0000-0000-000000000002',
   'Ratana', 'ratana@office.kh', ARRAY['Staff'], 'active'),
  ('d1200000-0000-0000-0000-000000000003', 'd1100000-0000-0000-0000-000000000003',
   'Dara', 'dara@office.kh', ARRAY['Staff'], 'active'),
  ('d1200000-0000-0000-0000-000000000004', 'd1100000-0000-0000-0000-000000000004',
   'Someone who left', 'leaving@office.kh', ARRAY['Staff'], 'active')
ON CONFLICT DO NOTHING;

SELECT act_as('sophea@office.kh');
UPDATE discount_settings SET timezone = 'Asia/Phnom_Penh';

-- A Wednesday. 09:00 Phnom Penh is 02:00 UTC.
\set W0900 '''2026-09-02 02:00:00+00'''
\set W0930 '''2026-09-02 02:30:00+00'''
\set W1000 '''2026-09-02 03:00:00+00'''
\set W1030 '''2026-09-02 03:30:00+00'''
\set W1100 '''2026-09-02 04:00:00+00'''
\set W1200 '''2026-09-02 05:00:00+00'''

INSERT INTO meeting_rooms (id, name, location, capacity, facilities,
                           opens_at, closes_at, days_open, min_minutes, max_minutes)
VALUES ('d1300000-0000-0000-0000-000000000001', 'Small room', '2nd floor', 6,
        ARRAY['whiteboard'], '08:00', '18:00', ARRAY[1,2,3,4,5], 15, 240);

INSERT INTO meeting_rooms (id, name, location, capacity, buffer_minutes)
VALUES ('d1300000-0000-0000-0000-000000000002', 'Big room', '3rd floor', 20, 15);

\echo ''
\echo '== 1. one room, one meeting'

SELECT ok((SELECT title FROM book_room(
             'd1300000-0000-0000-0000-000000000001', 'Design review', :W0900, :W1000))
          = 'Design review',
  'a room is booked');

SELECT ok((SELECT status FROM room_bookings WHERE title = 'Design review') = 'confirmed',
  'and a room that needs no approval is confirmed outright');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Something else', '2026-09-02 02:30:00+00', '2026-09-02 03:30:00+00')$$,
  'a meeting overlapping it is refused');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Exactly the same', '2026-09-02 02:00:00+00', '2026-09-02 03:00:00+00')$$,
  'and so is one at exactly the same time');

-- Butting up against it is fine on a room with no turnaround.
SELECT ok((SELECT title FROM book_room(
             'd1300000-0000-0000-0000-000000000001', 'The next one', :W1000, :W1100))
          = 'The next one',
  'but a meeting starting the moment the last one ends is fine');

\echo ''
\echo '== 2. a room that needs turning around'

SELECT book_room('d1300000-0000-0000-0000-000000000002', 'Board meeting', :W0900, :W1000);

-- The big room carries fifteen minutes of buffer.
SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000002',
  'Straight after', '2026-09-02 03:00:00+00', '2026-09-02 04:00:00+00')$$,
  'a room with fifteen minutes of turnaround cannot be booked the moment the last meeting ends');

SELECT ok((SELECT title FROM book_room(
             'd1300000-0000-0000-0000-000000000002', 'After the gap',
             '2026-09-02 03:15:00+00', '2026-09-02 04:15:00+00')) = 'After the gap',
  'and once the fifteen minutes have passed it can');

\echo ''
\echo '== 3. the rules a room carries'

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Too short', '2026-09-03 02:00:00+00', '2026-09-03 02:05:00+00')$$,
  'five minutes is under the room minimum');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'All day', '2026-09-03 01:00:00+00', '2026-09-03 09:00:00+00')$$,
  'and eight hours is over its maximum');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Before it opens', '2026-09-03 00:00:00+00', '2026-09-03 00:30:00+00')$$,
  'seven in the morning is before the room opens');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'After it closes', '2026-09-03 11:00:00+00', '2026-09-03 11:30:00+00')$$,
  'and six in the evening is after it closes');

-- 2026-09-05 is a Saturday.
SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Weekend', '2026-09-05 02:00:00+00', '2026-09-05 03:00:00+00')$$,
  'a room open weekdays only is refused on Saturday');

-- A room with hours but no maximum length, so the midnight rule is the
-- thing being tested rather than the duration cap.
INSERT INTO meeting_rooms (id, name, capacity, opens_at, closes_at)
VALUES ('d1300000-0000-0000-0000-00000000000a', 'Long room', 10, '08:00', '18:00');

-- Local 17:00 to 09:00 the next morning: it starts after the room opens
-- and ends before it closes, so each check on its own is satisfied, and
-- the room is shut for fourteen of the sixteen hours between.
SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-00000000000a',
  'Overnight', '2026-09-03 10:00:00+00', '2026-09-04 02:00:00+00')$$,
  'a meeting running past midnight is refused rather than passing both hour checks separately');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  'Everyone', '2026-09-03 02:00:00+00', '2026-09-03 03:00:00+00', NULL, 30)$$,
  'thirty people will not fit in a room that seats six');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000001',
  '', '2026-09-03 02:00:00+00', '2026-09-03 03:00:00+00')$$,
  'and a meeting with no title is refused — a wall planner full of "Meeting" tells nobody anything');

\echo ''
\echo '== 4. how far ahead, and how little notice'

INSERT INTO meeting_rooms (id, name, capacity, max_days_ahead, min_notice_minutes)
VALUES ('d1300000-0000-0000-0000-000000000003', 'Popular room', 8, 30, 60);

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000003',
  'Next year', now() + interval '200 days', now() + interval '200 days 1 hour')$$,
  'a room bookable thirty days out refuses a booking two hundred days away');

SELECT raises($$SELECT book_room('d1300000-0000-0000-0000-000000000003',
  'Right now', now() + interval '5 minutes', now() + interval '35 minutes')$$,
  'and a room needing an hour of notice refuses one starting in five minutes');

SELECT ok((SELECT title FROM book_room('d1300000-0000-0000-0000-000000000003',
             'With notice', now() + interval '3 hours', now() + interval '4 hours'))
          = 'With notice',
  'three hours ahead is fine');

\echo ''
\echo '== 5. a room somebody has to ask for'

INSERT INTO meeting_rooms (id, name, capacity, requires_approval, approval_role)
VALUES ('d1300000-0000-0000-0000-000000000004', 'Directors room', 12, true, 'Manager');

SELECT ok((SELECT status FROM book_room('d1300000-0000-0000-0000-000000000004',
             'Quarterly review', '2026-09-04 02:00:00+00', '2026-09-04 03:00:00+00'))
          = 'booked',
  'a room needing approval starts as a request rather than a holding');

SELECT act_as('ratana@office.kh');
SELECT raises($$SELECT approve_room_booking(
  (SELECT id FROM room_bookings WHERE title = 'Quarterly review'))$$,
  'and a member of staff cannot approve it themselves');

SELECT act_as('sophea@office.kh');
SELECT ok((SELECT status FROM approve_room_booking(
             (SELECT id FROM room_bookings WHERE title = 'Quarterly review'))) = 'confirmed',
  'a manager can');
SELECT ok((SELECT approved_by FROM room_bookings WHERE title = 'Quarterly review') IS NOT NULL,
  'and who approved it is recorded');

\echo ''
\echo '== 6. what is free'

SELECT ok((SELECT count(*) FROM free_rooms(:W0900, :W1000)) = 3,
  'two of the five rooms are taken at nine on Wednesday, so three are offered');
SELECT ok((SELECT out_name FROM free_rooms('2026-09-02 06:00:00+00', '2026-09-02 07:00:00+00', 8)
            LIMIT 1) = 'Popular room',
  'asking for eight seats offers the smallest room that fits, not the boardroom');
SELECT ok(NOT EXISTS (SELECT 1 FROM free_rooms('2026-09-02 06:00:00+00', '2026-09-02 07:00:00+00', 8)
                       WHERE out_name = 'Small room'),
  'and the six-seat room is not offered for eight people');

\echo ''
\echo '== 7. whether the people are free'

-- Two meetings at the same hour, with Dara on both.
SELECT book_room('d1300000-0000-0000-0000-000000000002', 'Budget talk',
                 '2026-09-08 02:00:00+00', '2026-09-08 03:00:00+00',
                 ARRAY['d1200000-0000-0000-0000-000000000002'::uuid,
                       'd1200000-0000-0000-0000-000000000003'::uuid]);
SELECT book_room('d1300000-0000-0000-0000-000000000001', 'Client call',
                 '2026-09-08 02:30:00+00', '2026-09-08 03:30:00+00',
                 ARRAY['d1200000-0000-0000-0000-000000000003'::uuid]);

SELECT ok((SELECT count(*) FROM attendee_clashes(
             (SELECT id FROM room_bookings WHERE title = 'Client call'))) = 1,
  'one of the people invited to the client call is already in another meeting');
SELECT ok((SELECT out_name FROM attendee_clashes(
             (SELECT id FROM room_bookings WHERE title = 'Client call'))) = 'Dara',
  'and it says who');
SELECT ok((SELECT out_clash_title FROM attendee_clashes(
             (SELECT id FROM room_bookings WHERE title = 'Client call'))) = 'Budget talk',
  'and what they are already in');

-- Reported, not refused: people are double-booked all the time and choose.
SELECT ok((SELECT status FROM room_bookings WHERE title = 'Client call') = 'confirmed',
  'the booking is allowed anyway, because a person can decide which one to go to');

SELECT act_as('dara@office.kh');
SELECT ok((SELECT response FROM respond_to_meeting(
             (SELECT id FROM room_bookings WHERE title = 'Budget talk'), 'declined'))
          = 'declined',
  'Dara declines the first one');
SELECT ok((SELECT count(*) FROM attendee_clashes(
             (SELECT id FROM room_bookings WHERE title = 'Client call'))) = 0,
  'and the clash goes away, because a declined meeting is not a commitment');

SELECT raises($$SELECT respond_to_meeting(
  (SELECT id FROM room_bookings WHERE title = 'Design review'), 'accepted')$$,
  'somebody not invited cannot answer for a meeting');
SELECT raises($$SELECT respond_to_meeting(
  (SELECT id FROM room_bookings WHERE title = 'Budget talk'), 'maybe')$$,
  'and an answer has to be one of the three');

SELECT act_as('sophea@office.kh');

\echo ''
\echo '== 8. my day'

SELECT ok((SELECT count(*) FROM my_meetings('d1200000-0000-0000-0000-000000000003',
             '2026-09-08', '2026-09-08')) = 2,
  'Dara has two meetings that day, including the one declined');
SELECT ok((SELECT out_response FROM my_meetings('d1200000-0000-0000-0000-000000000003',
             '2026-09-08', '2026-09-08') WHERE out_title = 'Budget talk') = 'declined',
  'and the answer given shows against it');
SELECT ok((SELECT out_organising FROM my_meetings('d1200000-0000-0000-0000-000000000001',
             '2026-09-02', '2026-09-02') WHERE out_title = 'Design review'),
  'the organiser sees the meetings they called');

\echo ''
\echo '== 9. claiming a room, and getting it back'

INSERT INTO meeting_rooms (id, name, capacity, release_after_minutes)
VALUES ('d1300000-0000-0000-0000-000000000005', 'Quick room', 4, 10);

-- Started twenty minutes ago and still running.
INSERT INTO room_bookings (id, room_id, title, organiser_id, starts_at, ends_at, status)
VALUES ('d1400000-0000-0000-0000-000000000001', 'd1300000-0000-0000-0000-000000000005',
        'Nobody came', 'd1200000-0000-0000-0000-000000000001',
        now() - interval '20 minutes', now() + interval '40 minutes', 'confirmed');

-- Started five minutes ago, so still within its grace.
INSERT INTO room_bookings (id, room_id, title, organiser_id, starts_at, ends_at, status)
VALUES ('d1400000-0000-0000-0000-000000000002', 'd1300000-0000-0000-0000-000000000002',
        'Just started', 'd1200000-0000-0000-0000-000000000001',
        now() - interval '5 minutes', now() + interval '55 minutes', 'confirmed');

SELECT ok(release_unclaimed_rooms() = 1,
  'one room is given back: twenty minutes in, nobody claimed it');
SELECT ok((SELECT status FROM room_bookings WHERE id = 'd1400000-0000-0000-0000-000000000001')
          = 'released',
  'and it says released rather than cancelled, because nobody called it off');
SELECT ok((SELECT status FROM room_bookings WHERE id = 'd1400000-0000-0000-0000-000000000002')
          = 'confirmed',
  'the room with no release rule is left alone');

-- A released room is genuinely free.
SELECT ok((SELECT title FROM book_room('d1300000-0000-0000-0000-000000000005',
             'Somebody who needs it', now() - interval '10 minutes', now() + interval '20 minutes'))
          = 'Somebody who needs it',
  'and somebody else can have it straight away');

SELECT raises($$SELECT claim_room('d1400000-0000-0000-0000-000000000001')$$,
  'the person who never turned up cannot claim it afterwards');

SELECT ok((SELECT status FROM claim_room('d1400000-0000-0000-0000-000000000002')) = 'in_use',
  'a room claimed on time is in use');
SELECT ok((SELECT claimed_at FROM room_bookings WHERE id = 'd1400000-0000-0000-0000-000000000002')
          IS NOT NULL,
  'and when it was claimed is recorded');

SELECT raises($$SELECT claim_room(
  (SELECT id FROM room_bookings WHERE title = 'Quarterly review'))$$,
  'a meeting two days away cannot be claimed today');

\echo ''
\echo '== 10. calling it off'

SELECT raises($$SELECT cancel_room_booking(
  (SELECT id FROM room_bookings WHERE title = 'The next one'), '')$$,
  'a cancellation needs a reason — the people who cleared their morning will want one');

SELECT ok((SELECT status FROM cancel_room_booking(
             (SELECT id FROM room_bookings WHERE title = 'The next one'),
             'Moved to a call')) = 'cancelled',
  'with a reason it goes');
SELECT ok((SELECT title FROM book_room('d1300000-0000-0000-0000-000000000001',
             'Taking the slot', :W1000, :W1100)) = 'Taking the slot',
  'and the slot is free the moment it is cancelled');

\echo ''
\echo '== 11. the weekly stand-up'

INSERT INTO meeting_series (id, room_id, title, organiser_id, frequency, days_of_week,
                            start_time, end_time, starts_on, ends_on)
VALUES ('d1500000-0000-0000-0000-000000000001', 'd1300000-0000-0000-0000-000000000002',
        'Monday stand-up', 'd1200000-0000-0000-0000-000000000001',
        'weekly', ARRAY[1], '09:00', '09:30', '2026-10-05', '2026-11-02');

-- Mondays from 5 Oct to 2 Nov: 5, 12, 19, 26 Oct and 2 Nov.
SELECT ok((SELECT count(*) FROM generate_meeting_series('d1500000-0000-0000-0000-000000000001')) = 5,
  'five Mondays are generated between the two dates');
SELECT ok((SELECT count(*) FROM room_bookings
            WHERE series_id = 'd1500000-0000-0000-0000-000000000001') = 5,
  'and five bookings exist');
SELECT ok((SELECT bool_and(extract(dow FROM starts_at AT TIME ZONE 'Asia/Phnom_Penh') = 1)
             FROM room_bookings WHERE series_id = 'd1500000-0000-0000-0000-000000000001'),
  'every one of them is a Monday in the office timezone');

-- One week the room is wanted for something else. Cancelling that
-- occurrence must leave the other four standing.
SELECT cancel_room_booking(
  (SELECT id FROM room_bookings WHERE series_id = 'd1500000-0000-0000-0000-000000000001'
    ORDER BY starts_at OFFSET 1 LIMIT 1), 'Public holiday');
SELECT ok((SELECT count(*) FROM room_bookings
            WHERE series_id = 'd1500000-0000-0000-0000-000000000001'
              AND status = 'confirmed') = 4,
  'cancelling one week leaves the other four alone');
SELECT ok((SELECT is_active FROM meeting_series WHERE id = 'd1500000-0000-0000-0000-000000000001'),
  'and the series itself is untouched');

-- A week the room is already taken should be skipped and SAID, not
-- silently dropped.
INSERT INTO meeting_series (id, room_id, title, organiser_id, frequency, days_of_week,
                            start_time, end_time, starts_on, ends_on)
VALUES ('d1500000-0000-0000-0000-000000000002', 'd1300000-0000-0000-0000-000000000002',
        'Clashing weekly', 'd1200000-0000-0000-0000-000000000001',
        'weekly', ARRAY[1], '09:00', '09:30', '2026-10-05', '2026-10-19');

-- Generating BOOKS rooms, so it is run once and the answer kept. Calling
-- it again would find the rooms it had just taken itself.
CREATE TEMP TABLE gen AS
  SELECT * FROM generate_meeting_series('d1500000-0000-0000-0000-000000000002');

SELECT ok((SELECT count(*) FROM gen WHERE NOT out_booked) = 2,
  'two of the three weeks clash with the stand-up already there');
SELECT ok((SELECT count(*) FROM gen WHERE out_booked) = 1,
  'and the free week — the one whose stand-up was cancelled — is still booked');
SELECT ok((SELECT out_why FROM gen WHERE NOT out_booked LIMIT 1) LIKE '%already taken%',
  'the weeks that could not be booked say why, rather than being silently dropped');

SELECT raises($$
  INSERT INTO meeting_series (room_id, title, frequency, start_time, end_time, starts_on)
  VALUES ('d1300000-0000-0000-0000-000000000002', 'Backwards', 'weekly', '10:00', '09:00', '2026-10-05')$$,
  'a series ending before it begins is refused');

SELECT raises($$
  INSERT INTO meeting_series (room_id, title, frequency, start_time, end_time, starts_on, ends_on)
  VALUES ('d1300000-0000-0000-0000-000000000002', 'Never ends', 'weekly', '09:00', '09:30',
          '2026-10-05', NULL) RETURNING (SELECT generate_meeting_series(id))$$,
  'and generating a series with no end date is refused rather than filling the calendar to the horizon');

\echo ''
\echo '== 12. stopping a series'

SELECT raises($$SELECT stop_meeting_series('d1500000-0000-0000-0000-000000000001', '')$$,
  'stopping a recurring meeting needs a reason');

-- Everything in the series is in the future, so all four remaining go.
SELECT ok(stop_meeting_series('d1500000-0000-0000-0000-000000000001', 'Team reorganised') = 4,
  'stopping it cancels the four future occurrences');
SELECT ok(NOT (SELECT is_active FROM meeting_series
                WHERE id = 'd1500000-0000-0000-0000-000000000001'),
  'and the series is closed');

\echo ''
\echo '== 13. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                   WHERE out_kind = 'room' AND out_label = 'Quick room'
                     AND out_issue LIKE '%nobody claimed%'),
  'a room with bookings nobody claimed is reported');

UPDATE room_bookings SET attendee_count = 30 WHERE title = 'Design review';
SELECT ok(EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                   WHERE out_kind = 'booking' AND out_label = 'Design review'
                     AND out_issue LIKE '%seats 6%'),
  'a meeting booked for more people than the room seats is reported');

INSERT INTO meeting_rooms (id, name, capacity) VALUES
  ('d1300000-0000-0000-0000-000000000009', 'Room with no seats', 0);
SELECT ok(EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                   WHERE out_label = 'Room with no seats'),
  'a room in use with no capacity set is reported, because nothing can be checked against it');

UPDATE employees SET status = 'inactive' WHERE email = 'leaving@office.kh';
INSERT INTO room_bookings (room_id, title, organiser_id, starts_at, ends_at, status)
VALUES ('d1300000-0000-0000-0000-000000000009', 'Orphaned meeting',
        'd1200000-0000-0000-0000-000000000004',
        now() + interval '10 days', now() + interval '10 days 1 hour', 'confirmed');
SELECT ok(EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                   WHERE out_label = 'Orphaned meeting' AND out_issue LIKE '%who has left%'),
  'a future meeting organised by somebody who has left is reported');

-- The clashing series did get one week away, so it is NOT reported yet.
SELECT ok(NOT EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                       WHERE out_kind = 'series' AND out_label = 'Clashing weekly'),
  'a recurring meeting that still has a week booked is left alone');

SELECT cancel_room_booking(
  (SELECT id FROM room_bookings WHERE series_id = 'd1500000-0000-0000-0000-000000000002'
     AND status = 'confirmed' LIMIT 1), 'Not needed after all');
SELECT ok(EXISTS (SELECT 1 FROM meeting_room_reconciliation()
                   WHERE out_kind = 'series' AND out_label = 'Clashing weekly'),
  'but once its last occurrence is cancelled it is reported — a recurring meeting with nothing left booked stops happening quietly');

\echo ''
\echo '== 14. how busy the rooms actually are'

SELECT ok((SELECT out_no_shows FROM room_utilisation(CURRENT_DATE - 1, CURRENT_DATE + 1)
            WHERE out_room = 'Quick room') = 1,
  'the utilisation report counts the room nobody turned up to');
SELECT ok((SELECT out_bookings FROM room_utilisation('2026-09-01', '2026-09-30')
            WHERE out_room = 'Small room') >= 1,
  'and counts what a room was actually used for over a period');

\echo ''
\echo '===================================================================='
\echo ' MEETING ROOMS: all assertions passed'
\echo '===================================================================='
