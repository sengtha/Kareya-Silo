-- =====================================================================
-- TICKETING — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A bus ticket, a cinema ticket, a concert ticket and a park pass are one
-- problem: a finite inventory of admissions, sold, issued as a code, and
-- consumed once at a gate. The assertions below are about the six ways
-- that goes wrong.
--
-- ONE SEAT, ONE TICKET, enforced where it holds under a race rather than
-- where it merely looks tidy.
--
-- A TICKET IS ADMITTED ONCE. The whole reason a gate needs a computer.
--
-- A REFUSED SCAN IS RECORDED. Keeping only the successes makes a ticket
-- passed back over a fence invisible.
--
-- A HOLD EXPIRES, or an abandoned basket keeps a seat off sale forever.
--
-- A CODE IS UNGUESSABLE, because a ticket numbered 000418 tells the
-- holder exactly what 000419 will be.
--
-- AND MONEY BACK PUTS THE SEAT BACK.
--
-- The coach below is 4 seats: 2 sleeper, 2 seater. Every price is
-- invented so the arithmetic can be checked on paper, and none of it is
-- a fare.
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
  ('a2100000-0000-0000-0000-000000000001', 'clerk@bus.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles, status) VALUES
  ('a2200000-0000-0000-0000-000000000001', 'a2100000-0000-0000-0000-000000000001',
   'Sophea (clerk)', 'clerk@bus.kh', ARRAY['Cashier','Manager'], 'active')
ON CONFLICT DO NOTHING;

SELECT act_as('clerk@bus.kh');

-- A coach, a film and a park pass — the three shapes in one suite.
-- Doors open BEFORE the start, or nobody can be scanned in while they
-- are boarding — which is the only time anybody is scanned. The figures
-- are this operator's, not Kareya's.
INSERT INTO ticketed_products (id, code, name, kind, reserved_seating,
                               max_admissions, doors_open_minutes) VALUES
  ('a2300000-0000-0000-0000-000000000001', 'PP-SR', 'Phnom Penh – Siem Reap',
   'transport', true, 1, 180),
  ('a2300000-0000-0000-0000-000000000002', 'FILM', 'The Last Reel',
   'screening', false, 1, 30),
  ('a2300000-0000-0000-0000-000000000003', 'PASS', 'Two-day park pass',
   'attraction', false, 4, 0);

INSERT INTO ticket_occurrences (id, product_id, label, starts_at, ends_at, capacity, status) VALUES
  ('a2400000-0000-0000-0000-000000000001', 'a2300000-0000-0000-0000-000000000001',
   'PP–SR 07:30', now() + interval '2 hours', now() + interval '8 hours', 4, 'on_sale'),
  ('a2400000-0000-0000-0000-000000000002', 'a2300000-0000-0000-0000-000000000002',
   'Screen 2, 19:00', now() + interval '3 hours', now() + interval '5 hours', 50, 'on_sale');

-- A pass is a WINDOW, not a moment. It went on sale yesterday and is
-- usable for two days from now.
INSERT INTO ticket_occurrences (id, product_id, label, starts_at, ends_at,
                                valid_from, valid_until, capacity, status)
VALUES ('a2400000-0000-0000-0000-000000000003', 'a2300000-0000-0000-0000-000000000003',
        'Park, this week', now() - interval '1 hour', now() + interval '2 days',
        now() - interval '1 hour', now() + interval '2 days', 100, 'on_sale');

INSERT INTO ticket_classes (id, occurrence_id, name, capacity, price, sort_order) VALUES
  ('a2500000-0000-0000-0000-000000000001', 'a2400000-0000-0000-0000-000000000001', 'Sleeper', 2, 15, 1),
  ('a2500000-0000-0000-0000-000000000002', 'a2400000-0000-0000-0000-000000000001', 'Seater',  2, 9,  2),
  ('a2500000-0000-0000-0000-000000000003', 'a2400000-0000-0000-0000-000000000002', 'Standard', 50, 4, 1),
  ('a2500000-0000-0000-0000-000000000004', 'a2400000-0000-0000-0000-000000000003', 'Adult', 100, 12, 1);

INSERT INTO ticket_seats (id, occurrence_id, class_id, label, row_label, seat_no, sort_order) VALUES
  ('a2600000-0000-0000-0000-000000000001', 'a2400000-0000-0000-0000-000000000001',
   'a2500000-0000-0000-0000-000000000001', '1A', '1', 1, 1),
  ('a2600000-0000-0000-0000-000000000002', 'a2400000-0000-0000-0000-000000000001',
   'a2500000-0000-0000-0000-000000000001', '1B', '1', 2, 2),
  ('a2600000-0000-0000-0000-000000000003', 'a2400000-0000-0000-0000-000000000001',
   'a2500000-0000-0000-0000-000000000002', '2A', '2', 1, 3),
  ('a2600000-0000-0000-0000-000000000004', 'a2400000-0000-0000-0000-000000000001',
   'a2500000-0000-0000-0000-000000000002', '2B', '2', 2, 4);

\set COACH '''a2400000-0000-0000-0000-000000000001'''
\set SLEEPER '''a2500000-0000-0000-0000-000000000001'''
\set SEATER '''a2500000-0000-0000-0000-000000000002'''
\set FILM '''a2400000-0000-0000-0000-000000000002'''
\set STD '''a2500000-0000-0000-0000-000000000003'''
\set PARK '''a2400000-0000-0000-0000-000000000003'''
\set ADULT '''a2500000-0000-0000-0000-000000000004'''
\set S1A '''a2600000-0000-0000-0000-000000000001'''
\set S1B '''a2600000-0000-0000-0000-000000000002'''
\set S2A '''a2600000-0000-0000-0000-000000000003'''

\echo ''
\echo '== 1. nothing is sold yet'

SELECT ok((SELECT count(*) FROM tickets_issued) = 0,
  'no tickets exist');
SELECT ok((SELECT out_free FROM occurrence_availability(:COACH) WHERE out_class = 'Sleeper') = 2,
  'both sleepers are free');
SELECT ok((SELECT count(*) FROM seat_map(:COACH) WHERE out_state = 'free') = 4,
  'and all four seats show as free on the map');

\echo ''
\echo '== 2. the code'

SELECT ok(new_ticket_code() ~ '^[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$',
  'a code is twelve characters in three groups');
SELECT ok(new_ticket_code() !~ '[01OIL]',
  'and never uses the characters people misread aloud');
SELECT ok(new_ticket_code() <> new_ticket_code(),
  'two codes in a row are not the same, because it is not a counter');

\echo ''
\echo '== 3. one seat, one ticket'

SELECT ok((SELECT count(*) FROM hold_tickets(:COACH, :SLEEPER, 1, ARRAY[:S1A]::uuid[])) = 1,
  'seat 1A is held');
SELECT ok((SELECT out_state FROM seat_map(:COACH) WHERE out_label = '1A') = 'held',
  'and the map says so');
SELECT ok((SELECT out_free FROM occurrence_availability(:COACH) WHERE out_class = 'Sleeper') = 1,
  'a held seat is not free — it comes off availability immediately');

SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000001',
  'a2500000-0000-0000-0000-000000000001', 1, ARRAY['a2600000-0000-0000-0000-000000000001']::uuid[])$$,
  'and a second person cannot have the same seat');

-- The message is a courtesy; the partial unique index is what actually
-- holds under two tills pressing at once.
SELECT raises($$INSERT INTO tickets_issued (occurrence_id, class_id, seat_id, code, status, held_until)
  VALUES ('a2400000-0000-0000-0000-000000000001', 'a2500000-0000-0000-0000-000000000001',
          'a2600000-0000-0000-0000-000000000001', new_ticket_code(), 'held', now() + interval '10 minutes')$$,
  'even writing straight to the table is refused by the index');

\echo ''
\echo '== 4. capacity'

SELECT ok((SELECT count(*) FROM hold_tickets(:COACH, :SLEEPER, 1, ARRAY[:S1B]::uuid[])) = 1,
  'the second sleeper goes');
SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000001',
  'a2500000-0000-0000-0000-000000000001', 1)$$,
  'a third sleeper is refused — the section is full, not the coach');
SELECT ok((SELECT count(*) FROM hold_tickets(:COACH, :SEATER, 1, ARRAY[:S2A]::uuid[])) = 1,
  'but a seater is still available, because the two ceilings are different');

SELECT raises($$INSERT INTO ticket_classes (occurrence_id, name, capacity, price)
  VALUES ('a2400000-0000-0000-0000-000000000001', 'Extra', 10, 5)$$,
  'and classes cannot add up to more places than the coach has');

\echo ''
\echo '== 5. reserved seating means a seat has to be chosen'

SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000001',
  'a2500000-0000-0000-0000-000000000002', 1)$$,
  'a coach with a seat map will not sell an unnamed place');
SELECT ok((SELECT count(*) FROM hold_tickets(:FILM, :STD, 3)) = 3,
  'while general admission sells three at once with no seats at all');

UPDATE ticket_seats SET is_blocked = true, block_reason = 'Over the wheel arch'
 WHERE id = 'a2600000-0000-0000-0000-000000000004';
SELECT ok((SELECT out_state FROM seat_map(:COACH) WHERE out_label = '2B') = 'blocked',
  'a blocked seat is neither free nor sold — it is unavailable');
SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000001',
  'a2500000-0000-0000-0000-000000000002', 1, ARRAY['a2600000-0000-0000-0000-000000000004']::uuid[])$$,
  'and it says why it cannot be sold');
SELECT raises($$UPDATE ticket_seats SET is_blocked = true, block_reason = NULL
  WHERE id = 'a2600000-0000-0000-0000-000000000003'$$,
  'blocking a seat without saying why is refused');

\echo ''
\echo '== 6. a hold that nobody pays for'

INSERT INTO tickets_issued (id, occurrence_id, class_id, code, status, held_until, price)
VALUES ('a2700000-0000-0000-0000-000000000001', :FILM, :STD, new_ticket_code(),
        'held', now() - interval '1 minute', 4);
SELECT ok(release_expired_holds() >= 1,
  'a hold past its time is given back');
SELECT ok((SELECT status FROM tickets_issued WHERE id = 'a2700000-0000-0000-0000-000000000001') = 'expired',
  'and says expired rather than being deleted');
SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation() WHERE out_issue ILIKE '%never finished%')
       OR release_expired_holds() = 0,
  'stale holds are reported until somebody gives them back');

SELECT raises($$SELECT issue_ticket('a2700000-0000-0000-0000-000000000001')$$,
  'and an expired hold cannot then be paid for');

SELECT raises($$INSERT INTO tickets_issued (occurrence_id, class_id, code, status)
  VALUES ('a2400000-0000-0000-0000-000000000002', 'a2500000-0000-0000-0000-000000000003',
          new_ticket_code(), 'held')$$,
  'a hold with no expiry is refused — that is how a seat is lost forever');

\echo ''
\echo '== 7. paying'

SELECT ok((SELECT status FROM issue_ticket(
    (SELECT id FROM tickets_issued WHERE seat_id = :S1A),
    'Chan Dara', '012345678', 'ID99887')) = 'issued',
  'the hold becomes a ticket');
SELECT ok((SELECT holder_name FROM tickets_issued WHERE seat_id = :S1A) = 'Chan Dara',
  'with a name on it');
SELECT ok((SELECT price FROM tickets_issued WHERE seat_id = :S1A) = 15,
  'and the class price, which nobody had to type');
SELECT ok((SELECT issued_by FROM tickets_issued WHERE seat_id = :S1A)
          = 'a2200000-0000-0000-0000-000000000001',
  'and who sold it');
SELECT raises($$SELECT issue_ticket((SELECT id FROM tickets_issued WHERE seat_id = 'a2600000-0000-0000-0000-000000000001'))$$,
  'issuing the same ticket twice is refused');

-- The second sleeper is paid for too, so there is something to refund
-- later and something for the takings to add up from.
SELECT ok((SELECT status FROM issue_ticket(
    (SELECT id FROM tickets_issued WHERE seat_id = :S1B), 'Sok Nary', '098765432')) = 'issued',
  'the second sleeper is sold as well');

\echo ''
\echo '== 8. the gate'

\set CODE1 '(SELECT code FROM tickets_issued WHERE seat_id = ''a2600000-0000-0000-0000-000000000001'')'

SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE seat_id = :S1A), NULL, 'Gate A')) = true,
  'a paid ticket is admitted');
SELECT ok((SELECT status FROM tickets_issued WHERE seat_id = :S1A) = 'admitted',
  'and the ticket says so');

-- The point of the whole vertical.
SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE seat_id = :S1A), NULL, 'Gate B')) = false,
  'the same ticket a second time is NOT admitted');
SELECT ok((SELECT out_result FROM admit_ticket((SELECT code FROM tickets_issued WHERE seat_id = :S1A))) = 'duplicate',
  'it is called a duplicate, which is a different thing from invalid');
SELECT ok((SELECT out_message FROM admit_ticket((SELECT code FROM tickets_issued WHERE seat_id = :S1A))) ILIKE '%Already admitted%',
  'and the gate is told when and where, so the argument ends there');

SELECT ok((SELECT count(*) FROM ticket_admissions
            WHERE ticket_id = (SELECT id FROM tickets_issued WHERE seat_id = :S1A)) >= 4,
  'every scan is on the record, the refusals included');
SELECT ok((SELECT count(*) FROM ticket_admissions
            WHERE ticket_id = (SELECT id FROM tickets_issued WHERE seat_id = :S1A)
              AND result = 'admitted') = 1,
  'and exactly one of them let somebody through');
SELECT ok((SELECT gate FROM ticket_admissions
            WHERE ticket_id = (SELECT id FROM tickets_issued WHERE seat_id = :S1A)
              AND result = 'admitted') = 'Gate A',
  'at the gate it actually happened at');

SELECT ok((SELECT out_result FROM admit_ticket('ZZZZ-ZZZZ-ZZZZ', NULL, 'Gate A')) = 'not_found',
  'a code nobody issued is turned away');
SELECT ok((SELECT count(*) FROM ticket_admissions WHERE result = 'not_found') >= 1,
  'and that is logged too — several of them is somebody trying codes');

-- Typed by hand at a counter, in lower case, with the dashes left out.
SELECT ok((SELECT out_result FROM admit_ticket(
    lower(replace((SELECT code FROM tickets_issued WHERE seat_id = :S1A), '-', '')))) = 'duplicate',
  'a code typed in lower case with no dashes finds the same ticket — that is not a forgery');

SELECT raises($$UPDATE ticket_admissions SET result = 'admitted' WHERE result = 'duplicate'$$,
  'a scan cannot be rewritten afterwards');
SELECT raises($$DELETE FROM ticket_admissions WHERE result = 'not_found'$$,
  'nor deleted');

\echo ''
\echo '== 9. too early, too late, and the wrong bus'

INSERT INTO ticket_occurrences (id, product_id, label, starts_at, ends_at, capacity, status)
VALUES ('a2400000-0000-0000-0000-000000000004', 'a2300000-0000-0000-0000-000000000002',
        'Tomorrow 19:00', now() + interval '1 day', now() + interval '1 day 2 hours', 20, 'on_sale');
INSERT INTO ticket_classes (id, occurrence_id, name, capacity, price)
VALUES ('a2500000-0000-0000-0000-000000000005', 'a2400000-0000-0000-0000-000000000004', 'Standard', 20, 4);

SELECT issue_ticket((SELECT id FROM hold_tickets('a2400000-0000-0000-0000-000000000004',
  'a2500000-0000-0000-0000-000000000005', 1) LIMIT 1), 'Early Bird');
SELECT ok((SELECT out_result FROM admit_ticket(
    (SELECT code FROM tickets_issued WHERE holder_name = 'Early Bird'))) = 'too_early',
  'turning up a day early is refused, and told when to come back');
SELECT ok((SELECT valid_from FROM ticket_occurrences WHERE id = 'a2400000-0000-0000-0000-000000000004')
          = (SELECT starts_at - interval '30 minutes' FROM ticket_occurrences
              WHERE id = 'a2400000-0000-0000-0000-000000000004'),
  'the doors open thirty minutes before the film, because that is when people walk in');

INSERT INTO ticket_occurrences (id, product_id, label, starts_at, ends_at,
                                valid_from, valid_until, capacity, status)
VALUES ('a2400000-0000-0000-0000-000000000005', 'a2300000-0000-0000-0000-000000000002',
        'Last night', now() - interval '2 days', now() - interval '2 days' + interval '2 hours',
        now() - interval '2 days', now() - interval '2 days' + interval '2 hours', 20, 'on_sale');
INSERT INTO ticket_classes (id, occurrence_id, name, capacity, price)
VALUES ('a2500000-0000-0000-0000-000000000006', 'a2400000-0000-0000-0000-000000000005', 'Standard', 20, 4);
INSERT INTO tickets_issued (occurrence_id, class_id, code, status, price, holder_name, issued_at)
VALUES ('a2400000-0000-0000-0000-000000000005', 'a2500000-0000-0000-0000-000000000006',
        new_ticket_code(), 'issued', 4, 'Late Arrival', now() - interval '2 days');
SELECT ok((SELECT out_result FROM admit_ticket(
    (SELECT code FROM tickets_issued WHERE holder_name = 'Late Arrival'))) = 'too_late',
  'and a ticket for a show that has been and gone is expired, not merely invalid');

SELECT ok((SELECT out_result FROM admit_ticket(
    (SELECT code FROM tickets_issued WHERE holder_name = 'Early Bird'),
    'a2400000-0000-0000-0000-000000000002')) = 'wrong_occurrence',
  'presented at the wrong screen, the gate says which one it IS for');

\echo ''
\echo '== 10. a pass that allows re-entry'

SELECT issue_ticket((SELECT id FROM hold_tickets(:PARK, :ADULT, 1) LIMIT 1), 'Park Visitor');
\set PCODE '(SELECT code FROM tickets_issued WHERE holder_name = ''Park Visitor'')'

SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) = true,
  'the first entry is allowed');
SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) = true,
  'and so is the second — a pass is not a bus ticket');
SELECT ok((SELECT admissions_used FROM tickets_issued WHERE holder_name = 'Park Visitor') = 2,
  'the entries are counted');
SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) = true,
  'third');
SELECT ok((SELECT out_ok FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) = true,
  'fourth');
SELECT ok((SELECT out_result FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) = 'exhausted',
  'the fifth is refused as spent — which is NOT the same word as duplicate');
SELECT ok((SELECT out_message FROM admit_ticket((SELECT code FROM tickets_issued WHERE holder_name = 'Park Visitor'))) ILIKE '%All 4 entries%',
  'and says how many there were');

\echo ''
\echo '== 11. money back, and the seat with it'

SELECT ok((SELECT status FROM refund_ticket(
    (SELECT id FROM tickets_issued WHERE seat_id = :S1B), NULL, 'Passenger cancelled')) = 'refunded',
  'a ticket is refunded');
SELECT ok((SELECT out_state FROM seat_map(:COACH) WHERE out_label = '1B') = 'free',
  'and the seat goes straight back on sale — the index does that on its own');
SELECT ok((SELECT count(*) FROM hold_tickets(:COACH, :SLEEPER, 1, ARRAY[:S1B]::uuid[])) = 1,
  'so somebody else can have it');

SELECT raises($$SELECT refund_ticket((SELECT id FROM tickets_issued WHERE holder_name = 'Late Arrival'), 99, 'Too much')$$,
  'refunding more than the ticket cost is refused');
SELECT raises($$SELECT refund_ticket((SELECT id FROM tickets_issued WHERE holder_name = 'Late Arrival'), NULL, '')$$,
  'and a refund with no reason is refused');

SELECT raises($$SELECT void_ticket((SELECT id FROM tickets_issued WHERE seat_id = 'a2600000-0000-0000-0000-000000000001'), 'Changed my mind')$$,
  'a ticket somebody has already travelled on cannot be voided — refund it instead');
SELECT raises($$SELECT void_ticket((SELECT id FROM tickets_issued WHERE holder_name = 'Late Arrival'), '')$$,
  'and a void needs a reason');
SELECT raises($$UPDATE tickets_issued SET status = 'void', void_reason = NULL
  WHERE holder_name = 'Late Arrival'$$,
  'even by direct update, because the constraint says so');

\echo ''
\echo '== 12. calling off a departure'

SELECT ok(cancel_occurrence('a2400000-0000-0000-0000-000000000004', 'Driver ill') >= 1,
  'cancelling voids every live ticket on it');
SELECT ok((SELECT status FROM tickets_issued WHERE holder_name = 'Early Bird') = 'void',
  'so nobody turns up to a bus that is not coming');
SELECT ok((SELECT void_reason FROM tickets_issued WHERE holder_name = 'Early Bird') = 'Driver ill',
  'and they are told why');
SELECT ok((SELECT out_result FROM admit_ticket(
    (SELECT code FROM tickets_issued WHERE holder_name = 'Early Bird'))) = 'void',
  'a voided ticket is turned away at the gate');
SELECT raises($$SELECT cancel_occurrence('a2400000-0000-0000-0000-000000000004', '')$$,
  'and calling something off needs a reason');

SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000004',
  'a2500000-0000-0000-0000-000000000005', 1)$$,
  'nothing more can be sold on a cancelled departure');

\echo ''
\echo '== 13. when the counter is open'

UPDATE ticket_occurrences SET sales_close_at = now() - interval '1 minute'
 WHERE id = 'a2400000-0000-0000-0000-000000000002';
SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000002',
  'a2500000-0000-0000-0000-000000000003', 1)$$,
  'once sales have closed nothing more goes out');
UPDATE ticket_occurrences SET sales_close_at = NULL, status = 'closed'
 WHERE id = 'a2400000-0000-0000-0000-000000000002';
SELECT raises($$SELECT * FROM hold_tickets('a2400000-0000-0000-0000-000000000002',
  'a2500000-0000-0000-0000-000000000003', 1)$$,
  'and a departure that is not on sale sells nothing');
UPDATE ticket_occurrences SET status = 'on_sale' WHERE id = 'a2400000-0000-0000-0000-000000000002';

\echo ''
\echo '== 14. the manifest'

SELECT ok((SELECT count(*) FROM passenger_manifest(:COACH)) >= 1,
  'the manifest lists who is on the coach');
SELECT ok((SELECT out_boarded FROM passenger_manifest(:COACH) WHERE out_seat = '1A') = true,
  'and says who actually boarded');
SELECT ok((SELECT out_document FROM passenger_manifest(:COACH) WHERE out_seat = '1A') = 'ID99887',
  'with the document number, which road transport is required to hold');
SELECT ok(NOT EXISTS (SELECT 1 FROM passenger_manifest(:COACH) WHERE out_seat = '1B'),
  'a refunded passenger is not on the manifest, because they are not on the bus');

\echo ''
\echo '== 15. what was taken'

SELECT ok((SELECT out_issued FROM ticket_sales(CURRENT_DATE, CURRENT_DATE)
            WHERE out_product = 'Phnom Penh – Siem Reap' AND out_class = 'Sleeper') = 1,
  'one sleeper still stands as sold');
SELECT ok((SELECT out_refunds FROM ticket_sales(CURRENT_DATE, CURRENT_DATE)
            WHERE out_product = 'Phnom Penh – Siem Reap' AND out_class = 'Sleeper') = 15,
  'the refund is counted as a refund');
SELECT ok((SELECT out_net FROM ticket_sales(CURRENT_DATE, CURRENT_DATE)
            WHERE out_product = 'Phnom Penh – Siem Reap' AND out_class = 'Sleeper') = 15,
  'and the net is what was actually kept: two at 15 less one refunded');

\echo ''
\echo '== 16. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_issue ILIKE '%already admitted%'),
  'a ticket turned away as a duplicate is reported — printed twice, or passed back');

INSERT INTO ticket_occurrences (id, product_id, label, starts_at, capacity, status)
VALUES ('a2400000-0000-0000-0000-000000000006', 'a2300000-0000-0000-0000-000000000001',
        'No classes', now() + interval '1 day', 10, 'on_sale');
SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_label = 'No classes' AND out_issue ILIKE '%no classes%'),
  'on sale with no class is reported — there is no price and nothing to buy');
SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_label = 'No classes' AND out_issue ILIKE '%no seat map%'),
  'and reserved seating with no seats drawn is reported too');

INSERT INTO ticket_occurrences (id, product_id, label, starts_at, capacity, status)
VALUES ('a2400000-0000-0000-0000-000000000007', 'a2300000-0000-0000-0000-000000000002',
        'Went hours ago', now() - interval '5 hours', 10, 'on_sale');
SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_label = 'Went hours ago' AND out_issue ILIKE '%Still on sale%'),
  'still selling tickets for something that started five hours ago is reported');

INSERT INTO ticketed_products (id, name, kind, doors_open_minutes)
VALUES ('a2300000-0000-0000-0000-000000000004', 'Doors never open', 'performance', 0);
INSERT INTO ticket_occurrences (product_id, label, starts_at, capacity)
VALUES ('a2300000-0000-0000-0000-000000000004', 'A show', now() + interval '3 days', 10);
SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_label = 'Doors never open'
                     AND out_issue ILIKE '%while boarding%'),
  'a gate that only opens at the starting second is reported — nobody could be scanned in');

SELECT ok(EXISTS (SELECT 1 FROM ticketing_reconciliation()
                   WHERE out_issue ILIKE '%codes that do not exist%')
       OR (SELECT count(*) FROM ticket_admissions WHERE result = 'not_found') < 3,
  'repeated scans of codes that do not exist are reported as somebody trying codes');

\echo ''
\echo '===================================================================='
\echo ' TICKETING: all assertions passed'
\echo '===================================================================='
