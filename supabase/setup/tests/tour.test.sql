-- =====================================================================
-- TOUR ITINERARY, COSTING AND SELLING — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A package used to carry `destinations text` and `base_price numeric`.
-- The assertions below are about what sat between those two columns.
--
-- ONE PRICE CANNOT BE RIGHT FOR TWO GROUP SIZES. On the figures here the
-- same three-day tour is $437.50 a head for two people and $227.50 for
-- ten. Nothing changed about the tour; the van and the guide were simply
-- divided by more people.
--
-- AND IT DOES NOT FALL SMOOTHLY. A twelve-seat van takes twelve. The
-- thirteenth needs a second van and everybody pays for it, so the price
-- per head goes UP between twelve and thirteen. A single number cannot
-- express a step.
--
-- A ROOM IS NOT A PERSON. Two sharing a twin carry half each; one alone
-- carries the room. That difference is the single supplement.
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
  ('a1100000-0000-0000-0000-000000000001', 'sokha@tours.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('a1200000-0000-0000-0000-000000000001', 'a1100000-0000-0000-0000-000000000001',
   'Sokha (travel agent)', 'sokha@tours.kh', ARRAY['Travel Agent'])
ON CONFLICT DO NOTHING;

SELECT act_as('sokha@tours.kh');

INSERT INTO tour_packages (id, name, description, days, nights, destinations, is_active)
VALUES ('a1300000-0000-0000-0000-000000000001', 'Three days upcountry',
        'A three-day, two-night programme', 3, 2, 'Somewhere, Somewhere else', true);

\echo ''
\echo '== 1. the programme is a programme, not a comma-separated string'

INSERT INTO tour_itinerary_days (id, package_id, day_no, title, overnight_in, lunch, dinner) VALUES
  ('a1400000-0000-0000-0000-000000000001', 'a1300000-0000-0000-0000-000000000001', 1,
   'Arrival and the old town', 'Town hotel', true, true);
INSERT INTO tour_itinerary_days (id, package_id, day_no, title, overnight_in, breakfast, lunch, dinner) VALUES
  ('a1400000-0000-0000-0000-000000000002', 'a1300000-0000-0000-0000-000000000001', 2,
   'The temples', 'Town hotel', true, true, true),
  ('a1400000-0000-0000-0000-000000000003', 'a1300000-0000-0000-0000-000000000001', 3,
   'The lake and departure', NULL, true, true, false);

SELECT raises($$
  INSERT INTO tour_itinerary_days (package_id, day_no, title)
  VALUES ('a1300000-0000-0000-0000-000000000001', 2, 'A second day two')$$,
  'a package cannot have two day twos');

SELECT ok((SELECT out_meals FROM tour_programme('a1300000-0000-0000-0000-000000000001')
            WHERE out_day_no = 2 LIMIT 1) = 'B/L/D',
  'day two carries the B/L/D line every tour programme has');
SELECT ok((SELECT out_meals FROM tour_programme('a1300000-0000-0000-0000-000000000001')
            WHERE out_day_no = 1 LIMIT 1) = 'L/D',
  'and day one, arriving after breakfast, carries L/D');

\echo ''
\echo '== 2. every line of the programme is a thing somebody buys'

-- Per person: consumed once by each traveller. $60 + 3 x $10 = $90 a head.
INSERT INTO tour_itinerary_items (day_id, sort_order, title, item_type, cost_basis,
                                  unit_cost, quantity, supplier, cost_source) VALUES
 ('a1400000-0000-0000-0000-000000000002', 10, 'Temple entrance pass', 'sightseeing',
  'per_person', 60, 1, 'Site authority', 'Published ticket price, invented for this test'),
 ('a1400000-0000-0000-0000-000000000001', 20, 'Lunches and dinners', 'meal',
  'per_person', 10, 3, 'Various restaurants', 'Agreed set menu, invented for this test');

-- Per room per night: two nights in one room is $100, however many rooms
-- the party ends up needing.
INSERT INTO tour_itinerary_items (day_id, sort_order, title, item_type, cost_basis,
                                  unit_cost, quantity, supplier, cost_source) VALUES
 ('a1400000-0000-0000-0000-000000000001', 30, 'Twin room, two nights', 'accommodation',
  'per_room_night', 50, 2, 'Town hotel', 'Contract rate, invented for this test');

-- Per group: bought once whoever goes.
INSERT INTO tour_itinerary_items (day_id, sort_order, title, item_type, cost_basis,
                                  unit_cost, quantity, supplier, cost_source) VALUES
 ('a1400000-0000-0000-0000-000000000001', 40, 'Guide, three days', 'guide',
  'per_group', 60, 3, 'Freelance guide', 'Day rate, invented for this test');

-- Per vehicle: a twelve-seat van, three days. This is the step.
INSERT INTO tour_itinerary_items (id, day_id, sort_order, title, item_type, cost_basis,
                                  unit_cost, quantity, unit_capacity, supplier, cost_source) VALUES
 ('a1500000-0000-0000-0000-000000000001', 'a1400000-0000-0000-0000-000000000001', 50,
  'Van and driver, three days', 'transport', 'per_vehicle', 240, 1, 12,
  'Transport company', 'Charter rate, invented for this test');

-- On the programme, not in the price.
INSERT INTO tour_itinerary_items (day_id, sort_order, title, item_type, is_costed) VALUES
 ('a1400000-0000-0000-0000-000000000003', 10, 'Free time at the market', 'free_time', false);

-- Offered and priced separately.
INSERT INTO tour_itinerary_items (day_id, sort_order, title, item_type, cost_basis,
                                  unit_cost, quantity, is_optional, supplier) VALUES
 ('a1400000-0000-0000-0000-000000000003', 20, 'Sunset boat (optional)', 'activity',
  'per_person', 15, 1, true, 'Boat operator');

SELECT raises($$
  INSERT INTO tour_itinerary_items (day_id, title, cost_basis, unit_cost, quantity)
  VALUES ('a1400000-0000-0000-0000-000000000001', 'A van with no seats', 'per_vehicle', 100, 1)$$,
  'a per-vehicle cost with no seat count is refused — it cannot be counted out');

-- Four things on day one, one on day two, two on day three.
SELECT ok((SELECT count(*) FROM tour_programme('a1300000-0000-0000-0000-000000000001')) = 7,
  'the programme prints seven lines, including the free time that costs nothing');

\echo ''
\echo '== 3. what the tour costs, party by party'

INSERT INTO tour_costings (id, package_id, name, season, room_occupancy, markup_percent,
                           child_percent, valid_from, valid_to)
VALUES ('a1600000-0000-0000-0000-000000000001', 'a1300000-0000-0000-0000-000000000001',
        'Test season', 'high', 2, 25, 75, CURRENT_DATE - 30, CURRENT_DATE + 180);

-- 2 pax: 90x2 person + 180 guide + 240 van + 1 room x 100 = 700.
SELECT ok((SELECT out_total FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 2)) = 700,
  'two people cost $700 to take: 180 personal, 180 guide, 240 van, 100 room');
SELECT ok((SELECT out_cost_per_person FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 2)) = 350,
  'which is $350 each');
SELECT ok((SELECT out_rooms FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 2)) = 1,
  'two people sharing need one room');

-- 10 pax: 900 + 180 + 240 + 5 rooms x 100 = 1820.
SELECT ok((SELECT out_total FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 10)) = 1820,
  'ten people cost $1,820');
SELECT ok((SELECT out_cost_per_person FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 10)) = 182,
  'which is $182 each — the guide and the van did not get more expensive');
SELECT ok((SELECT out_rooms FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 10)) = 5,
  'and they need five rooms');

-- The optional boat and the free time are outside the price.
SELECT ok((SELECT out_per_person_cost FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 2)) = 90,
  'the optional boat is not in the tour cost, because it is not in the tour');

\echo ''
\echo '== 4. the step nobody can see in a single price'

-- 12 pax: one van still. 1080 + 180 + 240 + 6 rooms x 100 = 2100, /12 = 175.
SELECT ok((SELECT out_cost_per_person FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 12)) = 175,
  'twelve people, one van: $175 each');
-- 13 pax: two vans. 1170 + 180 + 480 + 7 rooms x 100 = 2530, /13 = 194.6154.
SELECT ok((SELECT out_vehicles FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 13)) = 2,
  'the thirteenth traveller needs a second van');
SELECT ok(round((SELECT out_cost_per_person FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 13)), 2)
          = 194.62,
  'and the cost per head goes UP, from $175 to $194.62 — everybody pays for the second van');

-- Rooming steps too: an odd traveller needs a whole extra room.
SELECT ok((SELECT out_rooms FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 5)) = 3,
  'five people at two to a room need three rooms, not two and a half');

\echo ''
\echo '== 5. a room is not a person'

-- One room for the stay is $100. At two to a room a traveller alone
-- carries the half the other would have carried.
SELECT ok((SELECT out_single_supplement FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 4)) = 50,
  'sole occupancy costs the half of the room nobody else is paying for');

UPDATE tour_costings SET room_occupancy = 4 WHERE id = 'a1600000-0000-0000-0000-000000000001';
SELECT ok((SELECT out_single_supplement FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 4)) = 75,
  'in a room built for four, being alone costs three quarters of it');
SELECT ok((SELECT out_rooms FROM tour_cost_at_pax('a1600000-0000-0000-0000-000000000001', 10)) = 3,
  'and ten people at four to a room need three rooms');
UPDATE tour_costings SET room_occupancy = 2 WHERE id = 'a1600000-0000-0000-0000-000000000001';

\echo ''
\echo '== 6. the grid'

SELECT raises($$SELECT price_tour_costing('a1600000-0000-0000-0000-000000000001')$$,
  'a costing with no group sizes on it cannot be priced');

INSERT INTO tour_price_bands (costing_id, min_pax, max_pax) VALUES
  ('a1600000-0000-0000-0000-000000000001', 2, 3),
  ('a1600000-0000-0000-0000-000000000001', 4, 9),
  ('a1600000-0000-0000-0000-000000000001', 10, NULL);

SELECT raises($$
  INSERT INTO tour_price_bands (costing_id, min_pax, max_pax)
  VALUES ('a1600000-0000-0000-0000-000000000001', 6, 12)$$,
  'a band that overlaps another is refused');

SELECT ok(price_tour_costing('a1600000-0000-0000-0000-000000000001') = 3,
  'three bands price from the itinerary');

-- A band is priced at its SMALLEST party, because that is where the
-- per-group cost is spread thinnest.
SELECT ok((SELECT out_price FROM tour_price_grid('a1600000-0000-0000-0000-000000000001')
            WHERE out_min_pax = 2) = 437.50,
  'the 2–3 band is $437.50 a head: $350 cost at 25% markup');
SELECT ok((SELECT out_price FROM tour_price_grid('a1600000-0000-0000-0000-000000000001')
            WHERE out_min_pax = 4) = 306.25,
  'the 4–9 band is $306.25, priced at four rather than nine');
SELECT ok((SELECT out_price FROM tour_price_grid('a1600000-0000-0000-0000-000000000001')
            WHERE out_min_pax = 10) = 227.50,
  'and the 10+ band is $227.50');

-- The whole point, in one line.
SELECT ok((SELECT out_price FROM tour_price_grid('a1600000-0000-0000-0000-000000000001') WHERE out_min_pax = 2)
        - (SELECT out_price FROM tour_price_grid('a1600000-0000-0000-0000-000000000001') WHERE out_min_pax = 10)
          = 210,
  'the same tour is $210 a head dearer for a couple than for a party of ten');

SELECT ok((SELECT out_single FROM tour_price_grid('a1600000-0000-0000-0000-000000000001')
            WHERE out_min_pax = 4) = 62.50,
  'the single supplement is marked up like everything else: $50 becomes $62.50');
SELECT ok((SELECT out_child FROM tour_price_grid('a1600000-0000-0000-0000-000000000001')
            WHERE out_min_pax = 4) = 229.69,
  'a child at 75% of $306.25 is $229.69');

\echo ''
\echo '== 7. publishing'

SELECT ok((SELECT status FROM publish_tour_costing('a1600000-0000-0000-0000-000000000001')) = 'published',
  'a priced costing publishes');

SELECT ok((SELECT base_price FROM tour_packages WHERE id = 'a1300000-0000-0000-0000-000000000001') = 437.50,
  'the package headline price follows the smallest band, so the brochure and the grid cannot drift');

SELECT raises($$
  UPDATE tour_price_bands SET price_per_person = 1
   WHERE costing_id = 'a1600000-0000-0000-0000-000000000001' AND min_pax = 2$$,
  'a published price cannot be quietly edited');

SELECT raises($$SELECT price_tour_costing('a1600000-0000-0000-0000-000000000001')$$,
  'nor can a published costing be repriced');

SELECT raises($$SELECT publish_tour_costing('a1600000-0000-0000-0000-000000000001')$$,
  'and it cannot be published twice');

\echo ''
\echo '== 8. what a party of this size pays on this day'

SELECT ok((SELECT out_price FROM tour_price_for('a1300000-0000-0000-0000-000000000001', 2, CURRENT_DATE)) = 437.50,
  'a party of two is quoted the 2–3 band');
SELECT ok((SELECT out_price FROM tour_price_for('a1300000-0000-0000-0000-000000000001', 6, CURRENT_DATE)) = 306.25,
  'a party of six falls in the 4–9 band');
SELECT ok((SELECT out_price FROM tour_price_for('a1300000-0000-0000-0000-000000000001', 40, CURRENT_DATE)) = 227.50,
  'and a party of forty takes the open-ended band');
SELECT ok(NOT EXISTS (SELECT 1 FROM tour_price_for('a1300000-0000-0000-0000-000000000001', 1, CURRENT_DATE)),
  'a single traveller falls outside every band, and nothing is invented for them');
SELECT ok(NOT EXISTS (SELECT 1 FROM tour_price_for('a1300000-0000-0000-0000-000000000001', 4, CURRENT_DATE + 400)),
  'and a date outside the season has no price at all');

\echo ''
\echo '== 9. a new season leaves the old one alone'

SELECT ok((SELECT status FROM copy_tour_costing('a1600000-0000-0000-0000-000000000001',
            'Next season', CURRENT_DATE + 181, CURRENT_DATE + 360)) = 'draft',
  'a copy starts as a draft');
SELECT ok((SELECT count(*) FROM tour_price_bands b JOIN tour_costings c ON c.id = b.costing_id
           WHERE c.name = 'Next season') = 3,
  'the band shape is carried over');
SELECT ok((SELECT count(*) FROM tour_price_bands b JOIN tour_costings c ON c.id = b.costing_id
           WHERE c.name = 'Next season' AND b.price_per_person > 0) = 0,
  'but not the prices — those come back from the itinerary at what it costs now');
SELECT ok((SELECT status FROM tour_costings WHERE id = 'a1600000-0000-0000-0000-000000000001') = 'published',
  'and the season that is running is untouched');

\echo ''
\echo '== 10. seats are counted in the database'

INSERT INTO tour_departures (id, package_id, depart_date, return_date, capacity, status)
VALUES ('a1700000-0000-0000-0000-000000000001', 'a1300000-0000-0000-0000-000000000001',
        CURRENT_DATE + 30, CURRENT_DATE + 32, 10, 'scheduled');

SELECT ok((SELECT out_remaining FROM tour_departure_seats('a1700000-0000-0000-0000-000000000001')) = 10,
  'a new departure has all ten seats');

SELECT ok((SELECT booking_number FROM book_tour_seats(
             'a1700000-0000-0000-0000-000000000001', 'Party of four', 4)) LIKE 'TB-%',
  'a booking takes a number from the series without being asked');

-- Priced for the party that is actually travelling.
SELECT ok((SELECT unit_price FROM tour_bookings WHERE customer_name = 'Party of four') = 306.25,
  'four people are priced at the 4–9 band, not at a single package figure');
SELECT ok((SELECT total FROM tour_bookings WHERE customer_name = 'Party of four') = 1225,
  'and the total is worked out by the database: 4 x $306.25');

SELECT ok((SELECT out_remaining FROM tour_departure_seats('a1700000-0000-0000-0000-000000000001')) = 6,
  'six seats left');

SELECT raises($$SELECT book_tour_seats('a1700000-0000-0000-0000-000000000001', 'Party of eight', 8)$$,
  'eight more will not fit, and the database says so rather than the browser');

SELECT ok((SELECT out_remaining FROM tour_departure_seats('a1700000-0000-0000-0000-000000000001')) = 6,
  'and the refused booking took no seats');

-- Children take a seat on the coach whatever they pay for it.
SELECT ok((SELECT child_pax FROM book_tour_seats(
             'a1700000-0000-0000-0000-000000000001', 'Family', 2, 2, 0)) = 2,
  'a family of two adults and two children books');
SELECT ok((SELECT out_remaining FROM tour_departure_seats('a1700000-0000-0000-0000-000000000001')) = 2,
  'and the children take seats too');

-- 4 adults + 2 children = 6 travelling, so the 4-9 band, and the
-- children pay 75% of it.
SELECT ok((SELECT total FROM tour_bookings WHERE customer_name = 'Family') = 1071.88,
  'the family pays 2 x $306.25 plus 2 x $229.69 = $1,071.88');

SELECT raises($$SELECT book_tour_seats('a1700000-0000-0000-0000-000000000001', 'Nobody', 0, 0)$$,
  'a booking with nobody on it is refused');
SELECT raises($$SELECT book_tour_seats('a1700000-0000-0000-0000-000000000001', '', 2)$$,
  'and so is one with no name');
SELECT raises($$SELECT book_tour_seats('a1700000-0000-0000-0000-000000000001', 'Odd request', 2, 0, 3)$$,
  'more single rooms than adults is refused');

\echo ''
\echo '== 11. a single supplement is charged per single room'

INSERT INTO tour_departures (id, package_id, depart_date, capacity, status)
VALUES ('a1700000-0000-0000-0000-000000000002', 'a1300000-0000-0000-0000-000000000001',
        CURRENT_DATE + 60, 20, 'scheduled');

SELECT book_tour_seats('a1700000-0000-0000-0000-000000000002', 'Four, one alone', 4, 0, 1);
SELECT ok((SELECT total FROM tour_bookings WHERE customer_name = 'Four, one alone')
          = 4 * 306.25 + 62.50,
  'four people with one in a room alone pay 4 x $306.25 plus one supplement of $62.50');

\echo ''
\echo '== 12. money is a ledger'

SELECT ok((SELECT amount FROM record_tour_payment(
             (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four'),
             300, 'cash', 'deposit')) = 300,
  'a deposit is recorded');
SELECT ok((SELECT status FROM tour_bookings WHERE customer_name = 'Party of four') = 'confirmed',
  'and the booking moves to confirmed by itself');

SELECT record_tour_payment((SELECT id FROM tour_bookings WHERE customer_name = 'Party of four'),
                           925, 'bank', 'balance');
SELECT ok((SELECT paid_amount FROM tour_bookings WHERE customer_name = 'Party of four') = 1225,
  'the balance brings it to $1,225');
SELECT ok((SELECT status FROM tour_bookings WHERE customer_name = 'Party of four') = 'paid',
  'and the booking reads as paid');
SELECT ok((SELECT count(*) FROM tour_booking_payments
            WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')) = 2,
  'both movements survive as their own rows, with dates, methods and who took them');

SELECT raises($$SELECT record_tour_payment(
  (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four'), 100)$$,
  'taking more than the booking is for is refused');

SELECT raises($$
  UPDATE tour_booking_payments SET amount = 5000
   WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')$$,
  'a payment cannot be rewritten');
SELECT raises($$
  DELETE FROM tour_booking_payments
   WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')$$,
  'nor deleted');

SELECT raises($$SELECT void_tour_payment(
  (SELECT id FROM tour_booking_payments
    WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')
    ORDER BY created_at LIMIT 1), '')$$,
  'voiding without a reason is refused');

SELECT void_tour_payment(
  (SELECT id FROM tour_booking_payments
    WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')
    ORDER BY created_at LIMIT 1), 'Cheque bounced');
SELECT ok((SELECT paid_amount FROM tour_bookings WHERE customer_name = 'Party of four') = 925,
  'voiding the deposit takes it back off the booking');
SELECT ok((SELECT count(*) FROM tour_booking_payments
            WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Party of four')) = 2,
  'and the voided row stays, with the reason on it');

\echo ''
\echo '== 13. cancelling'

SELECT raises($$SELECT cancel_tour_booking(
  (SELECT id FROM tour_bookings WHERE customer_name = 'Family'), '')$$,
  'a cancellation without a reason is refused');

SELECT record_tour_payment((SELECT id FROM tour_bookings WHERE customer_name = 'Family'),
                           500, 'cash', 'deposit');

SELECT raises($$SELECT cancel_tour_booking(
  (SELECT id FROM tour_bookings WHERE customer_name = 'Family'), 'Changed plans', 99999)$$,
  'a cancellation charge larger than the booking is refused');

SELECT ok((SELECT status FROM cancel_tour_booking(
             (SELECT id FROM tour_bookings WHERE customer_name = 'Family'),
             'Changed plans', 200)) = 'cancelled',
  'a booking is cancelled with a reason and a charge');

SELECT ok((SELECT out_remaining FROM tour_departure_seats('a1700000-0000-0000-0000-000000000001')) = 6,
  'the four seats come back to the departure');

SELECT ok((SELECT out_refundable FROM tour_booking_position(
             (SELECT id FROM tour_bookings WHERE customer_name = 'Family'))) = 300,
  '$500 was taken against a $200 charge, so $300 is owed back');
SELECT ok((SELECT out_due FROM tour_booking_position(
             (SELECT id FROM tour_bookings WHERE customer_name = 'Family'))) = 0,
  'and nothing is still to collect');

-- The refund is its own movement, made by whoever hands the money over.
SELECT record_tour_payment((SELECT id FROM tour_bookings WHERE customer_name = 'Family'),
                           -300, 'cash');
SELECT ok((SELECT out_refundable FROM tour_booking_position(
             (SELECT id FROM tour_bookings WHERE customer_name = 'Family'))) = 0,
  'once refunded, nothing is owed back');
SELECT ok((SELECT kind FROM tour_booking_payments
            WHERE booking_id = (SELECT id FROM tour_bookings WHERE customer_name = 'Family')
              AND amount < 0) = 'refund',
  'and a negative amount is recorded as a refund whatever it was called');

-- $500 was taken and $300 handed back, so $200 is still held. Handing
-- back $300 more would be refunding money that never arrived.
SELECT raises($$SELECT record_tour_payment(
  (SELECT id FROM tour_bookings WHERE customer_name = 'Family'), -300)$$,
  'refunding more than was ever taken is refused');

SELECT raises($$SELECT cancel_tour_booking(
  (SELECT id FROM tour_bookings WHERE customer_name = 'Family'), 'Again')$$,
  'and a booking cannot be cancelled twice');

\echo ''
\echo '== 14. what needs looking at'

SELECT ok(NOT EXISTS (SELECT 1 FROM tour_selling_reconciliation()
                       WHERE out_kind = 'departure'),
  'no departure is oversold');

-- Paid amount forced out of step with the ledger behind it.
UPDATE tour_bookings SET paid_amount = 9999 WHERE customer_name = 'Party of four';
SELECT ok(EXISTS (SELECT 1 FROM tour_selling_reconciliation()
                   WHERE out_kind = 'booking' AND out_issue LIKE '%9999%'),
  'a paid figure adrift from its payments is reported');

INSERT INTO tour_packages (id, name, base_price, is_active)
VALUES ('a1300000-0000-0000-0000-000000000009', 'Priced from thin air', 199, true);
SELECT ok(EXISTS (SELECT 1 FROM tour_costing_reconciliation()
                   WHERE out_kind = 'package' AND out_label = 'Priced from thin air'
                     AND out_issue LIKE '%no costing behind it%'),
  'a package carrying a price with no costing behind it is reported');
SELECT ok(EXISTS (SELECT 1 FROM tour_costing_reconciliation()
                   WHERE out_kind = 'package' AND out_label = 'Priced from thin air'
                     AND out_issue LIKE '%no itinerary%'),
  'and one sold with no itinerary at all is reported too');

INSERT INTO tour_itinerary_days (id, package_id, day_no, title)
VALUES ('a1400000-0000-0000-0000-000000000009', 'a1300000-0000-0000-0000-000000000009', 1, 'A day');
INSERT INTO tour_itinerary_items (day_id, title, cost_basis, unit_cost)
VALUES ('a1400000-0000-0000-0000-000000000009', 'A cost from nowhere', 'per_person', 40);
SELECT ok(EXISTS (SELECT 1 FROM tour_costing_reconciliation()
                   WHERE out_issue LIKE '%no source recorded%'),
  'an itinerary cost with no supplier and no source is reported');

UPDATE tour_costings SET valid_to = CURRENT_DATE - 1
 WHERE id = 'a1600000-0000-0000-0000-000000000001';
SELECT ok(EXISTS (SELECT 1 FROM tour_costing_reconciliation()
                   WHERE out_kind = 'costing' AND out_issue LIKE '%season ended%'),
  'a costing still published after its season ended is reported');

\echo ''
\echo '===================================================================='
\echo ' TOUR: all assertions passed'
\echo '===================================================================='
