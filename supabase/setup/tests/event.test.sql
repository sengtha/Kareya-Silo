-- =====================================================================
-- EVENT QUOTING — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- `event_bookings.guests` sat on the booking and not one charge line
-- referred to it. A wedding is quoted per head; the line carried a lump
-- sum somebody had multiplied by hand, and the guest count is the number
-- that changes most.
--
-- On the figures below, moving 350 guests to 400 moves the quote by
-- $1,050 — and used to move it by nothing at all.
--
-- TABLES ARE NOT GUESTS. A table seats ten, so 351 guests need 36 tables
-- and the 351st guest costs a whole one. The price steps.
--
-- AND A SMALL EVENT STILL PAYS THE VENUE MINIMUM, which no multiplication
-- ever finds.
--
-- Every figure here is invented for the arithmetic and chosen so each
-- total can be checked on paper. They are not market prices and nothing
-- should be quoted from them.
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
  ('b1100000-0000-0000-0000-000000000001', 'chenda@events.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('b1200000-0000-0000-0000-000000000001', 'b1100000-0000-0000-0000-000000000001',
   'Chenda (planner)', 'chenda@events.kh', ARRAY['Event Planner'])
ON CONFLICT DO NOTHING;

SELECT act_as('chenda@events.kh');

INSERT INTO event_vendors (id, name, service_type) VALUES
  ('b1300000-0000-0000-0000-000000000001', 'A caterer', 'catering'),
  ('b1300000-0000-0000-0000-000000000002', 'A hall', 'venue'),
  ('b1300000-0000-0000-0000-000000000003', 'A photographer', 'photo'),
  ('b1300000-0000-0000-0000-000000000004', 'A sound company', 'sound'),
  ('b1300000-0000-0000-0000-000000000005', 'A florist', 'decoration');

-- 350 guests, ten to a table.
INSERT INTO event_bookings (id, event_name, event_type, customer_name, venue,
                            event_date, guests, seats_per_table, status)
VALUES ('b1400000-0000-0000-0000-000000000001', 'A wedding', 'wedding',
        'A customer', 'A hall', CURRENT_DATE + 120, 350, 10, 'inquiry');

\echo ''
\echo '== 1. tables come from guests, and only in whole numbers'

SELECT ok(event_tables('b1400000-0000-0000-0000-000000000001') = 35,
  '350 guests at ten to a table is 35 tables');

UPDATE event_bookings SET guests = 351 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok(event_tables('b1400000-0000-0000-0000-000000000001') = 36,
  'and the 351st guest needs a whole extra table, not a tenth of one');

UPDATE event_bookings SET seats_per_table = 8 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok(event_tables('b1400000-0000-0000-0000-000000000001') = 44,
  'at eight to a table the same 351 guests need 44');

UPDATE event_bookings SET guests = 350, seats_per_table = 10
 WHERE id = 'b1400000-0000-0000-0000-000000000001';

\echo ''
\echo '== 2. a charge line that knows how it is sold'

INSERT INTO event_services (id, booking_id, name, vendor_id, basis,
                            unit_cost, unit_price, sort_order) VALUES
 ('b1500000-0000-0000-0000-000000000001', 'b1400000-0000-0000-0000-000000000001',
  'Catering', 'b1300000-0000-0000-0000-000000000001', 'per_guest', 12, 18, 10);

SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000001') = 6300,
  '350 guests at $18 a head is $6,300, worked out rather than typed');
SELECT ok((SELECT cost FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000001') = 4200,
  'and the caterer charges $4,200 for the same heads');

-- The venue is sold by the table, with a minimum below the current total
-- so it does not bite yet.
INSERT INTO event_services (id, booking_id, name, vendor_id, basis,
                            unit_cost, unit_price, minimum_charge, sort_order) VALUES
 ('b1500000-0000-0000-0000-000000000002', 'b1400000-0000-0000-0000-000000000001',
  'Hall and tables', 'b1300000-0000-0000-0000-000000000002', 'per_table', 20, 30, 900, 20);

SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002') = 1050,
  '35 tables at $30 is $1,050');
SELECT ok(NOT (SELECT minimum_applied FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002'),
  'the $900 minimum does not bite at this size');

INSERT INTO event_services (id, booking_id, name, vendor_id, basis,
                            unit_cost, unit_price, quantity, sort_order) VALUES
 ('b1500000-0000-0000-0000-000000000003', 'b1400000-0000-0000-0000-000000000001',
  'Photography', 'b1300000-0000-0000-0000-000000000003', 'per_event', 400, 600, 1, 30),
 ('b1500000-0000-0000-0000-000000000004', 'b1400000-0000-0000-0000-000000000001',
  'Sound and lighting', 'b1300000-0000-0000-0000-000000000004', 'per_hour', 50, 80, 6, 40),
 ('b1500000-0000-0000-0000-000000000005', 'b1400000-0000-0000-0000-000000000001',
  'Table flowers', 'b1300000-0000-0000-0000-000000000005', 'per_item', 5, 9, 35, 50);

SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000004') = 480,
  'six hours of sound at $80 is $480');
SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000005') = 315,
  'and 35 centrepieces at $9 is $315');

\echo ''
\echo '== 3. the booking totals itself'

-- 6300 + 1050 + 600 + 480 + 315
SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 8745,
  'the event is worth $8,745, and the figure lives in the database rather than in the browser');
SELECT ok((SELECT total_cost FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 5775,
  'the vendors come to $5,775');
SELECT ok((SELECT out_margin FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 2970,
  'so the planner makes $2,970');
SELECT ok((SELECT out_margin_pct FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 33.96,
  'which is 33.96%');
SELECT ok((SELECT out_per_head FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 24.99,
  'and $24.99 a head — the figure a customer asks for first and a lump sum hides');

\echo ''
\echo '== 4. the guest count is the price'

UPDATE event_bookings SET guests = 400 WHERE id = 'b1400000-0000-0000-0000-000000000001';

SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000001') = 7200,
  'fifty more guests move the catering to $7,200 without anybody touching the line');
SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002') = 1200,
  'and the hall to $1,200, because forty tables are now needed');
SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000003') = 600,
  'the photographer, who is priced per event, does not move');

-- 8745 -> 9795.
SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 9795,
  'the quote is $1,050 bigger, and used to be $1,050 wrong');

-- One guest over a table boundary.
UPDATE event_bookings SET guests = 401 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002') = 1230,
  'the 401st guest needs a 41st table and the hall goes up $30 for one person');
SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 9843,
  'so one more guest costs $48: eighteen for the head and thirty for the table');

UPDATE event_bookings SET guests = 350 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 8745,
  'and putting the count back puts the price back');

\echo ''
\echo '== 5. a small event still pays the minimum'

UPDATE event_bookings SET guests = 200 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok((SELECT price FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002') = 900,
  '20 tables at $30 is $600 on paper, and $900 on the bill');
SELECT ok((SELECT minimum_applied FROM event_services WHERE id = 'b1500000-0000-0000-0000-000000000002'),
  'and the line says so, rather than leaving somebody to wonder at the arithmetic');

UPDATE event_bookings SET guests = 350 WHERE id = 'b1400000-0000-0000-0000-000000000001';

\echo ''
\echo '== 6. an optional extra is offered, not charged'

INSERT INTO event_services (id, booking_id, name, basis, unit_price, quantity, is_optional, sort_order)
VALUES ('b1500000-0000-0000-0000-000000000006', 'b1400000-0000-0000-0000-000000000001',
        'Fireworks', 'per_event', 450, 1, true, 60);

SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 8745,
  'an optional extra does not join the total');
SELECT ok((SELECT out_optional FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 450,
  'but it is reported separately, so it can be offered');

\echo ''
\echo '== 7. one venue, one event, one day'

SELECT raises($$
  INSERT INTO event_bookings (event_name, venue, event_date, guests, status)
  VALUES ('Another wedding', 'A hall', CURRENT_DATE + 120, 100, 'inquiry')$$,
  'a second event at the same hall on the same day is refused');

SELECT raises($$
  INSERT INTO event_bookings (event_name, venue, event_date, guests, status)
  VALUES ('Yet another', 'a HALL ', CURRENT_DATE + 120, 100, 'inquiry')$$,
  'and case and stray spaces do not get round it');

INSERT INTO event_bookings (id, event_name, venue, event_date, guests, status)
VALUES ('b1400000-0000-0000-0000-000000000002', 'A different day', 'A hall',
        CURRENT_DATE + 121, 100, 'inquiry');
SELECT ok((SELECT count(*) FROM event_bookings WHERE venue = 'A hall') = 2,
  'the next day at the same hall is fine');

INSERT INTO event_bookings (event_name, venue, event_date, guests, status)
VALUES ('A cancelled one', 'A hall', CURRENT_DATE + 121, 50, 'cancelled');
SELECT ok((SELECT count(*) FROM event_bookings WHERE venue = 'A hall') = 3,
  'and a cancelled event releases the day');

\echo ''
\echo '== 8. the quote is what the customer was sent'

SELECT raises($$SELECT issue_event_quote('b1400000-0000-0000-0000-000000000002')$$,
  'an event with nothing on it cannot be quoted');

INSERT INTO event_bookings (id, event_name, venue, event_date, guests, status)
VALUES ('b1400000-0000-0000-0000-000000000003', 'No headcount', 'Another hall',
        CURRENT_DATE + 90, 0, 'inquiry');
INSERT INTO event_services (booking_id, name, basis, unit_price)
VALUES ('b1400000-0000-0000-0000-000000000003', 'Catering', 'per_guest', 18);
SELECT raises($$SELECT issue_event_quote('b1400000-0000-0000-0000-000000000003')$$,
  'nor one with no guest count, because on a per-head event that number IS the price');

SELECT ok((SELECT quote_no FROM issue_event_quote(
             'b1400000-0000-0000-0000-000000000001', CURRENT_DATE + 30)) LIKE 'EVQ-%',
  'a quote takes a number from the series without being asked');

SELECT ok((SELECT total_price FROM event_quotes
            WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A') = 8745,
  'revision A is frozen at $8,745');
SELECT ok((SELECT guests FROM event_quotes
            WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A') = 350,
  'and it records the guest count the price was built on');
SELECT ok((SELECT count(*) FROM event_quote_lines l JOIN event_quotes q ON q.id = l.quote_id
           WHERE q.booking_id = 'b1400000-0000-0000-0000-000000000001' AND q.revision = 'A') = 6,
  'all six lines are photographed, optional one included');

SELECT raises($$
  UPDATE event_quote_lines SET price = 1
   WHERE quote_id = (SELECT id FROM event_quotes
                      WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A')$$,
  'a quoted line cannot be edited afterwards');

-- The working services move; what was sent does not.
UPDATE event_bookings SET guests = 400 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok((SELECT total_price FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 9795,
  'the live booking follows the new guest count');
SELECT ok((SELECT total_price FROM event_quotes
            WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A') = 8745,
  'and revision A still says what the customer was actually sent');

\echo ''
\echo '== 9. revisions'

SELECT ok((SELECT revision FROM issue_event_quote('b1400000-0000-0000-0000-000000000001')) = 'B',
  'a second issue is revision B');
SELECT ok((SELECT status FROM event_quotes
            WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A') = 'superseded',
  'and revision A is superseded rather than deleted');
SELECT ok((SELECT total_price FROM event_quotes
            WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'B') = 9795,
  'revision B carries the new figure');
SELECT ok((SELECT count(DISTINCT quote_no) FROM event_quotes
           WHERE booking_id = 'b1400000-0000-0000-0000-000000000001') = 1,
  'both revisions share one quote number, so the customer sees one reference');

SELECT ok((SELECT status FROM accept_event_quote(
             (SELECT id FROM event_quotes
               WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'B'))) = 'accepted',
  'the customer accepts revision B');
SELECT ok((SELECT status FROM event_bookings WHERE id = 'b1400000-0000-0000-0000-000000000001') = 'confirmed',
  'and the event moves from inquiry to confirmed by itself');

SELECT raises($$SELECT accept_event_quote(
  (SELECT id FROM event_quotes
    WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' AND revision = 'A'))$$,
  'a superseded revision cannot be accepted');

\echo ''
\echo '== 10. money in stages'

INSERT INTO event_payment_schedule (booking_id, label, due_on, percent, sort_order) VALUES
 ('b1400000-0000-0000-0000-000000000001', 'Deposit', CURRENT_DATE - 30, 30, 10),
 ('b1400000-0000-0000-0000-000000000001', 'Balance', CURRENT_DATE + 110, 70, 20);

SELECT raises($$
  INSERT INTO event_payment_schedule (booking_id, label, due_on, amount, percent)
  VALUES ('b1400000-0000-0000-0000-000000000001', 'Both at once', CURRENT_DATE, 100, 50)$$,
  'an instalment cannot be both a figure and a percentage');

-- 30% of 9795.
SELECT ok((SELECT out_amount FROM event_schedule_due('b1400000-0000-0000-0000-000000000001')
            WHERE out_label = 'Deposit') = 2938.50,
  'the deposit is 30% of $9,795, and follows the total rather than being retyped');
SELECT ok((SELECT out_overdue FROM event_schedule_due('b1400000-0000-0000-0000-000000000001')
            WHERE out_label = 'Deposit'),
  'and it is overdue, because nothing has been paid');

SELECT ok((SELECT amount FROM record_event_payment(
             'b1400000-0000-0000-0000-000000000001', 2938.50, 'deposit', 'bank')) = 2938.50,
  'the deposit is taken');
SELECT ok(NOT (SELECT out_overdue FROM event_schedule_due('b1400000-0000-0000-0000-000000000001')
                WHERE out_label = 'Deposit'),
  'and the instalment stops being overdue');

SELECT ok((SELECT out_due FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 6856.50,
  '$6,856.50 is still to come');

SELECT raises($$SELECT record_event_payment('b1400000-0000-0000-0000-000000000001', 99999)$$,
  'taking more than the event is for is refused');

SELECT raises($$
  UPDATE event_payments SET amount = 5000
   WHERE booking_id = 'b1400000-0000-0000-0000-000000000001'$$,
  'a payment cannot be rewritten');
SELECT raises($$
  DELETE FROM event_payments WHERE booking_id = 'b1400000-0000-0000-0000-000000000001'$$,
  'nor deleted — which was the only way to correct one');

SELECT raises($$SELECT void_event_payment(
  (SELECT id FROM event_payments WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' LIMIT 1), '')$$,
  'voiding without a reason is refused');

SELECT void_event_payment(
  (SELECT id FROM event_payments WHERE booking_id = 'b1400000-0000-0000-0000-000000000001' LIMIT 1),
  'Transfer never cleared');
SELECT ok((SELECT out_paid FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 0,
  'voiding takes the money back off the event');
SELECT ok((SELECT count(*) FROM event_payments WHERE booking_id = 'b1400000-0000-0000-0000-000000000001') = 1,
  'and the voided row stays, with the reason on it');

SELECT record_event_payment('b1400000-0000-0000-0000-000000000001', 3000, 'deposit', 'cash');
SELECT ok((SELECT type FROM record_event_payment(
             'b1400000-0000-0000-0000-000000000001', -500, 'installment')) = 'refund',
  'a negative amount is recorded as a refund whatever it was called');
SELECT ok((SELECT out_paid FROM event_summary('b1400000-0000-0000-0000-000000000001')) = 2500,
  'and the event is $2,500 in');

SELECT raises($$SELECT record_event_payment('b1400000-0000-0000-0000-000000000001', -3000)$$,
  'refunding more than was ever taken is refused');

\echo ''
\echo '== 11. cancelling'

SELECT raises($$SELECT cancel_event_booking('b1400000-0000-0000-0000-000000000002', '')$$,
  'a cancellation needs a reason');
SELECT ok((SELECT status FROM cancel_event_booking(
             'b1400000-0000-0000-0000-000000000002', 'Customer postponed')) = 'cancelled',
  'an event is cancelled with a reason');
SELECT raises($$SELECT cancel_event_booking('b1400000-0000-0000-0000-000000000002', 'Again')$$,
  'and cannot be cancelled twice');

\echo ''
\echo '== 12. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM event_reconciliation()
                   WHERE out_label = 'No headcount' AND out_issue LIKE '%no guest count%'),
  'an event with per-head charges and no guest count is reported');

INSERT INTO event_services (booking_id, name, basis, unit_cost, unit_price, quantity)
VALUES ('b1400000-0000-0000-0000-000000000003', 'A cost from nowhere', 'per_event', 300, 400, 1);
SELECT ok(EXISTS (SELECT 1 FROM event_reconciliation()
                   WHERE out_issue LIKE '%no vendor against it%'),
  'a service carrying a cost with no vendor named is reported');

-- The guest count moved after the customer accepted.
UPDATE event_bookings SET guests = 380 WHERE id = 'b1400000-0000-0000-0000-000000000001';
SELECT ok(EXISTS (SELECT 1 FROM event_reconciliation()
                   WHERE out_label = 'A wedding' AND out_issue LIKE '%Quoted at 400 guests%'),
  'a guest count that moved after the quote was accepted is reported');

INSERT INTO event_bookings (id, event_name, venue, event_date, guests, status, seats_per_table)
VALUES ('b1400000-0000-0000-0000-000000000004', 'Confirmed on nothing', 'A third hall',
        CURRENT_DATE + 60, 100, 'confirmed', 10);
SELECT ok(EXISTS (SELECT 1 FROM event_reconciliation()
                   WHERE out_label = 'Confirmed on nothing'
                     AND out_issue LIKE '%no accepted quote%'),
  'an event confirmed with no accepted quote behind it is reported');

INSERT INTO event_bookings (id, event_name, venue, event_date, guests, status, seats_per_table)
VALUES ('b1400000-0000-0000-0000-000000000005', 'Money still out', 'A fourth hall',
        CURRENT_DATE + 3, 50, 'confirmed', 10);
INSERT INTO event_services (booking_id, name, basis, unit_price)
VALUES ('b1400000-0000-0000-0000-000000000005', 'Catering', 'per_guest', 20);
SELECT ok(EXISTS (SELECT 1 FROM event_reconciliation()
                   WHERE out_label = 'Money still out' AND out_issue LIKE '%still uncollected%'),
  'an event three days away with nothing collected is reported');

-- The cancelled event never took a payment, so it is NOT reported.
SELECT ok(NOT EXISTS (SELECT 1 FROM event_reconciliation()
                       WHERE out_label = 'A different day'),
  'a cancelled event that took no money is not reported at all');

\echo ''
\echo '===================================================================='
\echo ' EVENT QUOTING: all assertions passed'
\echo '===================================================================='
