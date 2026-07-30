-- =====================================================================
-- DISPENSING INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The first assertion in this file is the reason the file exists. The
-- browser allocated batches by sorting on expiry date ascending and taking
-- from the top, filtering only on "has stock left". An expired batch sorts
-- EARLIEST. So the batch that was out of date went out first, ahead of
-- everything still usable, every time. That is not a reporting defect.
--
-- The rest guard: the lost update on medicine quantities, a void that left
-- the shelf short, requires_rx being a column nothing read, sale numbers
-- from a clock, and batch quantities moving with no record of why.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/pharmacy.test.sql
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

-- act_as sets BOTH claims: the RPCs match on user_id OR email, while
-- current_employee_id() matches on user_id alone. Setting only the email
-- would let an assertion pass for the wrong reason.
CREATE OR REPLACE FUNCTION act_as(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT user_id INTO v_uid FROM employees WHERE email = p_email;
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_email)::text, false);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('a0000000-0000-0000-0000-000000000001', 'sophea@pharmacy.kh'),
  ('a0000000-0000-0000-0000-000000000002', 'dara@pharmacy.kh'),
  ('a0000000-0000-0000-0000-000000000003', 'vibol@pharmacy.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'Sophea (pharmacist)', 'sophea@pharmacy.kh', ARRAY['Pharmacist']),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'Dara (cashier)',      'dara@pharmacy.kh',   ARRAY['Cashier']),
  ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000003', 'Vibol (driver)',      'vibol@pharmacy.kh',  ARRAY['Driver'])
ON CONFLICT DO NOTHING;

INSERT INTO pharmacy_products (id, name, generic_name, form, strength, unit, requires_rx, sale_price, cost_price) VALUES
  ('c0000000-0000-0000-0000-000000000001', 'Paracetamol 500mg', 'paracetamol', 'tablet', '500mg', 'strip', false, 0.50, 0.20),
  ('c0000000-0000-0000-0000-000000000002', 'Amoxicillin 500mg', 'amoxicillin', 'capsule', '500mg', 'strip', true,  1.20, 0.60),
  ('c0000000-0000-0000-0000-000000000003', 'Old syrup',         'guaifenesin', 'syrup',  '100ml', 'bottle', false, 2.00, 0.90)
ON CONFLICT DO NOTHING;

SELECT act_as('sophea@pharmacy.kh');

\echo ''
\echo '== 1. THE HEADLINE: expired medicine is not dispensed'

-- Two batches of the same drug. The expired one has the EARLIER date, so
-- the old sort put it at the top of the queue and handed it over first.
INSERT INTO pharmacy_batches (id, product_id, batch_number, expiry_date, quantity, cost_price, received_date) VALUES
  ('d0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'EXPIRED-LOT', CURRENT_DATE - 30, 100, 0.20, CURRENT_DATE - 400),
  ('d0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'GOOD-SOON',   CURRENT_DATE + 60,  40, 0.20, CURRENT_DATE - 20),
  ('d0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'GOOD-LATER',  CURRENT_DATE + 400, 50, 0.20, CURRENT_DATE - 5);

SELECT ok((SELECT count(*) FROM pharmacy_dispensable_batches('c0000000-0000-0000-0000-000000000001')) = 2,
  'the expired batch is not among the batches that can be dispensed');
SELECT ok((SELECT out_batch_number FROM pharmacy_dispensable_batches('c0000000-0000-0000-0000-000000000001') LIMIT 1) = 'GOOD-SOON',
  'the soonest-expiring batch that is still IN DATE comes first');
SELECT ok(pharmacy_batch_is_dispensable('d0000000-0000-0000-0000-000000000001') = false,
  'the expired batch reports itself as not dispensable');
SELECT ok(pharmacy_batch_is_dispensable('d0000000-0000-0000-0000-000000000002') = true,
  'the in-date batch reports itself as dispensable');

-- Dispense 10. Under the old allocation all 10 came out of EXPIRED-LOT.
SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object(
    'product_id', 'c0000000-0000-0000-0000-000000000001',
    'description', 'Paracetamol 500mg', 'quantity', 10, 'unit_price', 0.50)),
  'Walk-in');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'EXPIRED-LOT') = 100,
  'THE EXPIRED BATCH WAS NOT TOUCHED — this is the defect this file exists for');
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-SOON') = 30,
  'the 10 came out of the in-date batch that expires soonest');
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 50,
  'the batch with the longest life was left alone');
SELECT ok((SELECT batch_id FROM pharmacy_sale_items ORDER BY quantity DESC LIMIT 1)
          = 'd0000000-0000-0000-0000-000000000002',
  'the sale line records WHICH batch it came from, so a recall can be answered');

\echo ''
\echo '== 2. a sale that crosses batches crosses in date order'

-- Ask for 45. GOOD-SOON has 30 left; the rest must come from GOOD-LATER,
-- and none of it from the expired lot sitting there with 100 in it.
SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object(
    'product_id', 'c0000000-0000-0000-0000-000000000001',
    'description', 'Paracetamol 500mg', 'quantity', 45, 'unit_price', 0.50)),
  'Split across batches');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-SOON') = 0,
  'the soonest-expiring batch is used up first');
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 35,
  'the remainder comes from the next batch in date order');
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'EXPIRED-LOT') = 100,
  'and still nothing came out of the expired lot');
SELECT ok((SELECT count(*) FROM pharmacy_sale_items i
             JOIN pharmacy_sales s ON s.id = i.sale_id
            WHERE s.customer_name = 'Split across batches') = 2,
  'a sale spanning two batches is written as two lines, one per batch');
SELECT ok((SELECT sum(i.quantity) FROM pharmacy_sale_items i
             JOIN pharmacy_sales s ON s.id = i.sale_id
            WHERE s.customer_name = 'Split across batches') = 45,
  'and the lines add up to what was asked for');

\echo ''
\echo '== 3. "in stock" means in stock AND in date'

-- 100 expired tablets are not 100 tablets. The old check summed every
-- batch, so a shelf of expired medicine read as plenty.
SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object(
      'product_id', 'c0000000-0000-0000-0000-000000000001',
      'description', 'Paracetamol 500mg', 'quantity', 100, 'unit_price', 0.50)),
    'Walk-in')
$$, 'asking for 100 when only 35 are in date is refused, though 135 sit on the shelf');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 35,
  'and the refusal left the shelf exactly as it was');

\echo ''
\echo '== 4. a prescription-only medicine needs a prescription'

INSERT INTO pharmacy_batches (id, product_id, batch_number, expiry_date, quantity, cost_price) VALUES
  ('d0000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000002', 'AMOX-1', CURRENT_DATE + 200, 60, 0.60);

SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object(
      'product_id', 'c0000000-0000-0000-0000-000000000002',
      'description', 'Amoxicillin', 'quantity', 10, 'unit_price', 1.20)),
    'Walk-in')
$$, 'Rx-only medicine over the counter with no prescriber is refused');

SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object(
      'product_id', 'c0000000-0000-0000-0000-000000000002',
      'description', 'Amoxicillin', 'quantity', 10, 'unit_price', 1.20)),
    'Walk-in', 'Dr Chan')
$$, 'a prescriber name with no prescription reference is still refused');

SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object(
    'product_id', 'c0000000-0000-0000-0000-000000000002',
    'description', 'Amoxicillin', 'quantity', 10, 'unit_price', 1.20)),
  'Sok Pisey', 'Dr Chan', 'RX-2026-0417');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'AMOX-1') = 50,
  'with a prescriber and a reference it is dispensed');
SELECT ok((SELECT prescriber FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417') = 'Dr Chan',
  'and who prescribed it is on the record, not in somebody memory');

\echo ''
\echo '== 5. a withdrawn product cannot be dispensed'

INSERT INTO pharmacy_batches (id, product_id, batch_number, expiry_date, quantity, cost_price) VALUES
  ('d0000000-0000-0000-0000-000000000005', 'c0000000-0000-0000-0000-000000000003', 'SYRUP-1', CURRENT_DATE + 300, 20, 0.90);
UPDATE pharmacy_products SET is_active = false WHERE id = 'c0000000-0000-0000-0000-000000000003';

SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object(
      'product_id', 'c0000000-0000-0000-0000-000000000003',
      'description', 'Old syrup', 'quantity', 1, 'unit_price', 2.00)),
    'Walk-in')
$$, 'a withdrawn product is refused even though its batch is in date and in stock');

UPDATE pharmacy_products SET is_active = true WHERE id = 'c0000000-0000-0000-0000-000000000003';

\echo ''
\echo '== 6. a batch can be held back, and held-back stock does not go out'

SELECT quarantine_pharmacy_batch('d0000000-0000-0000-0000-000000000005', 'Supplier recall notice 2026/11');

SELECT ok((SELECT quarantined FROM pharmacy_batches WHERE batch_number = 'SYRUP-1') = true,
  'the batch is marked held back');
SELECT ok((SELECT count(*) FROM pharmacy_dispensable_batches('c0000000-0000-0000-0000-000000000003')) = 0,
  'a held-back batch is not dispensable');
SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object(
      'product_id', 'c0000000-0000-0000-0000-000000000003',
      'description', 'Old syrup', 'quantity', 1, 'unit_price', 2.00)),
    'Walk-in')
$$, 'and dispensing from it is refused');
SELECT raises($$SELECT quarantine_pharmacy_batch('d0000000-0000-0000-0000-000000000005', '')$$,
  'holding a batch back without saying why is refused');

SELECT quarantine_pharmacy_batch('d0000000-0000-0000-0000-000000000005', NULL, true);
SELECT ok((SELECT quarantined FROM pharmacy_batches WHERE batch_number = 'SYRUP-1') = false,
  'releasing it puts it back in circulation');
SELECT ok((SELECT quarantine_reason FROM pharmacy_batches WHERE batch_number = 'SYRUP-1') IS NULL,
  'and clears the reason it was held');

\echo ''
\echo '== 7. voiding puts the medicine back on the shelf'

-- The old void flipped a status column. The batch stayed decremented, so
-- 10 capsules that were never handed to anybody read as gone for ever.
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'AMOX-1') = 50,
  'before the void, the batch is down by what was dispensed');

SELECT void_pharmacy_sale(
  (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417'),
  'Customer changed their mind at the counter');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'AMOX-1') = 60,
  'THE MEDICINE WENT BACK to the batch it came from, with its expiry');
SELECT ok((SELECT status FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417') = 'void',
  'and the sale is marked void rather than deleted');
SELECT ok((SELECT count(*) FROM pharmacy_sale_items
            WHERE sale_id = (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417')) = 1,
  'the line stays, so the record of what was rung up survives the void');

SELECT raises($$
  SELECT void_pharmacy_sale(
    (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417'),
    'again')
$$, 'voiding the same sale twice is refused — otherwise the stock doubles');

SELECT raises($$
  SELECT void_pharmacy_sale((SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417'), '  ')
$$, 'voiding without a reason is refused');

\echo ''
\echo '== 8. a dispensing record is what somebody was handed'

SELECT raises($$DELETE FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417'$$,
  'a dispensing record cannot be deleted');
SELECT raises($$UPDATE pharmacy_sale_items SET quantity = 999
                 WHERE sale_id = (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417')$$,
  'what was handed over cannot be edited afterwards');
SELECT raises($$UPDATE pharmacy_sales SET total = 0 WHERE rx_reference = 'RX-2026-0417'$$,
  'the amount charged cannot be edited afterwards');
SELECT raises($$DELETE FROM pharmacy_sale_items
                 WHERE sale_id = (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417')$$,
  'a line cannot be removed from a dispensing');

\echo ''
\echo '== 9. sale numbers come from the database, not from a clock'

SELECT ok((SELECT sale_number FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417')
            LIKE 'RX-' || to_char(CURRENT_DATE, 'YYYY') || '-%',
  'a sale number carries the year and a counter');
SELECT ok((SELECT count(DISTINCT sale_number) FROM pharmacy_sales) = (SELECT count(*) FROM pharmacy_sales),
  'every sale so far has its own number');

-- The old code built the number in the browser from Date.now(). Two sales
-- inside the same millisecond collided.
DO $$
DECLARE i integer;
BEGIN
  FOR i IN 1..40 LOOP
    PERFORM dispense_pharmacy_sale(
      jsonb_build_array(jsonb_build_object(
        'product_id', 'c0000000-0000-0000-0000-000000000003',
        'description', 'Old syrup', 'quantity', 0.25, 'unit_price', 2.00)),
      'Rapid ' || i);
  END LOOP;
END $$;

SELECT ok((SELECT count(DISTINCT sale_number) FROM pharmacy_sales WHERE customer_name LIKE 'Rapid %') = 40,
  '40 sales rung up back to back got 40 different numbers');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_pharmacy_sales_number'),
  'and a unique index makes a duplicate impossible rather than unlikely');

-- Whatever the client sends is ignored: the number is the database's to give.
INSERT INTO pharmacy_sales (sale_number, total, sold_by)
VALUES ('I-MADE-THIS-UP', 5, 'b0000000-0000-0000-0000-000000000001');
SELECT ok(NOT EXISTS (SELECT 1 FROM pharmacy_sales WHERE sale_number = 'I-MADE-THIS-UP'),
  'a sale number supplied by the client is overwritten, not trusted');

\echo ''
\echo '== 10. a batch quantity cannot move without a record of why'

SELECT raises($$UPDATE pharmacy_batches SET quantity = 5000 WHERE batch_number = 'GOOD-LATER'$$,
  'a batch quantity cannot be changed by a plain UPDATE');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 35,
  'and the refused change left the figure alone');

SELECT adjust_pharmacy_batch('d0000000-0000-0000-0000-000000000003', 33, 'Physical count: two strips damaged by water');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 33,
  'a stock adjustment with a reason is accepted, and takes the COUNTED figure');
SELECT ok((SELECT reason FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000003' AND movement_type = 'adjust')
          = 'Physical count: two strips damaged by water',
  'and the reason is on the record');
SELECT ok((SELECT quantity_delta FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000003' AND movement_type = 'adjust') = -2,
  'the movement records the difference the count made');

SELECT raises($$SELECT adjust_pharmacy_batch('d0000000-0000-0000-0000-000000000003', 10, '')$$,
  'an adjustment with no reason is refused');
SELECT raises($$SELECT adjust_pharmacy_batch('d0000000-0000-0000-0000-000000000003', -5, 'negative')$$,
  'a counted quantity below zero is refused');

\echo ''
\echo '== 11. the movement ledger is a record, not a working document'

SELECT ok((SELECT count(*) FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'receive') = 1,
  'receiving a batch is recorded');
SELECT ok((SELECT count(*) FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'dispense') = 1,
  'dispensing from it is recorded');
SELECT ok((SELECT count(*) FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'void_return') = 1,
  'and the medicine coming back on a void is recorded separately');
SELECT ok((SELECT reason FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'void_return')
          = 'Customer changed their mind at the counter',
  'the void carries the reason the medicine came back');
SELECT ok((SELECT sum(quantity_delta) FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004') = 60,
  'the movements for a batch add up to what is on the shelf');
SELECT ok((SELECT reference FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'dispense')
          = (SELECT sale_number FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0417'),
  'a dispensing movement names the sale it belongs to');
SELECT ok((SELECT employee_id FROM pharmacy_batch_movements
            WHERE batch_id = 'd0000000-0000-0000-0000-000000000004' AND movement_type = 'dispense')
          = 'b0000000-0000-0000-0000-000000000001',
  'and who did it');

SELECT raises($$UPDATE pharmacy_batch_movements SET quantity_delta = 0
                 WHERE batch_id = 'd0000000-0000-0000-0000-000000000004'$$,
  'a movement cannot be edited');
SELECT raises($$DELETE FROM pharmacy_batch_movements
                 WHERE batch_id = 'd0000000-0000-0000-0000-000000000004'$$,
  'a movement cannot be removed');

\echo ''
\echo '== 12. the arithmetic of a sale belongs to the database'

SELECT dispense_pharmacy_sale(
  jsonb_build_array(
    jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                       'description', 'Paracetamol', 'quantity', 3, 'unit_price', 0.50),
    jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000002',
                       'description', 'Amoxicillin', 'quantity', 2, 'unit_price', 1.20)),
  'Chea Sarin', 'Dr Ly', 'RX-2026-0500', 'cash', 0.40, 10);

SELECT ok((SELECT subtotal FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0500') = 3.90,
  '3 x 0.50 plus 2 x 1.20 is 3.90');
SELECT ok((SELECT tax_amount FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0500') = 0.35,
  'tax is charged on the amount after the discount, not before');
SELECT ok((SELECT total FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0500') = 3.85,
  'and the total is subtotal less discount plus tax');
SELECT ok((SELECT sum(line_total) FROM pharmacy_sale_items
            WHERE sale_id = (SELECT id FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0500')) = 3.90,
  'the lines add up to the subtotal');

SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                                       'description', 'Paracetamol', 'quantity', 1, 'unit_price', 0.50)),
  'Discount test', NULL, NULL, 'cash', 99);

SELECT ok((SELECT total FROM pharmacy_sales WHERE customer_name = 'Discount test') = 0,
  'a discount larger than the sale gives a total of zero, not a negative one');

\echo ''
\echo '== 13. nothing moves if any line is refused'

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 29,
  'a known starting point');

SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(
      jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                         'description', 'Paracetamol', 'quantity', 2, 'unit_price', 0.50),
      jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000002',
                         'description', 'Amoxicillin', 'quantity', 9999, 'unit_price', 1.20)),
    'Sok Dara', 'Dr Ly', 'RX-2026-0600')
$$, 'a sale whose LAST line has no stock is refused whole');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'GOOD-LATER') = 29,
  'and the FIRST line was not already taken off the shelf');
SELECT ok(NOT EXISTS (SELECT 1 FROM pharmacy_sales WHERE rx_reference = 'RX-2026-0600'),
  'no sale record was left behind');

SELECT raises($$SELECT dispense_pharmacy_sale('[]'::jsonb, 'Nobody')$$,
  'an empty sale is refused');
SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                                         'description', 'Paracetamol', 'quantity', 0, 'unit_price', 0.50)),
    'Nobody')
$$, 'a line with no quantity is refused');
SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000009',
                                         'description', 'Ghost', 'quantity', 1, 'unit_price', 1)),
    'Nobody')
$$, 'a line for a product that does not exist is refused');

\echo ''
\echo '== 14. who may dispense, and who may not'

SELECT act_as('vibol@pharmacy.kh');
SELECT raises($$
  SELECT dispense_pharmacy_sale(
    jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                                         'description', 'Paracetamol', 'quantity', 1, 'unit_price', 0.50)),
    'Walk-in')
$$, 'a driver cannot dispense medicine');
SELECT raises($$SELECT quarantine_pharmacy_batch('d0000000-0000-0000-0000-000000000003', 'because')$$,
  'a driver cannot hold a batch back');
SELECT raises($$SELECT adjust_pharmacy_batch('d0000000-0000-0000-0000-000000000003', 1, 'because')$$,
  'a driver cannot adjust stock');

SELECT act_as('dara@pharmacy.kh');
SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000001',
                                       'description', 'Paracetamol', 'quantity', 1, 'unit_price', 0.50)),
  'Cashier sale');
SELECT ok((SELECT sold_by FROM pharmacy_sales WHERE customer_name = 'Cashier sale')
          = 'b0000000-0000-0000-0000-000000000002',
  'a cashier can dispense over the counter, and is recorded as who did');
SELECT raises($$SELECT void_pharmacy_sale(
    (SELECT id FROM pharmacy_sales WHERE customer_name = 'Cashier sale'), 'mistake')$$,
  'but a cashier cannot void their own sale');

SELECT act_as('sophea@pharmacy.kh');
SELECT void_pharmacy_sale((SELECT id FROM pharmacy_sales WHERE customer_name = 'Cashier sale'),
                          'Rung up on the wrong customer');
SELECT ok((SELECT status FROM pharmacy_sales WHERE customer_name = 'Cashier sale') = 'void',
  'a pharmacist can');

\echo ''
\echo '== 15. what must not go out, and what is about to'

INSERT INTO pharmacy_batches (id, product_id, batch_number, expiry_date, quantity, cost_price) VALUES
  ('d0000000-0000-0000-0000-000000000006', 'c0000000-0000-0000-0000-000000000002', 'AMOX-SOON', CURRENT_DATE + 45, 25, 0.60);

SELECT ok((SELECT count(*) FROM pharmacy_expired_stock()) = 1,
  'the expired batch is listed so somebody can pull it off the shelf');
SELECT ok((SELECT out_batch_number FROM pharmacy_expired_stock()) = 'EXPIRED-LOT',
  'by name');
SELECT ok((SELECT out_days_expired FROM pharmacy_expired_stock()) = 30,
  'with how long it has been out of date');
SELECT ok((SELECT out_value FROM pharmacy_expired_stock()) = 20.00,
  'and what it cost, because that is the number that gets written off');

SELECT ok((SELECT count(*) FROM pharmacy_expiring_soon(90)) = 1,
  'stock expiring within 90 days is listed while it can still be used');
SELECT ok((SELECT out_days_left FROM pharmacy_expiring_soon(90)) = 45,
  'with how long is left to use it');
SELECT ok(NOT EXISTS (SELECT 1 FROM pharmacy_expiring_soon(90) WHERE out_batch_number = 'EXPIRED-LOT'),
  'already-expired stock is not in the expiring-soon list — it is in the expired one');
SELECT ok(NOT EXISTS (SELECT 1 FROM pharmacy_expiring_soon(10)),
  'a 10-day window is empty: nothing is that close');

-- FEFO still holds when the soonest batch arrived last: it is the date on
-- the box that decides, not the order the shelf was filled.
SELECT ok((SELECT out_batch_number FROM pharmacy_dispensable_batches('c0000000-0000-0000-0000-000000000002') LIMIT 1)
          = 'AMOX-SOON',
  'a batch received today but expiring sooner goes out before older stock');

\echo ''
\echo '== 16. reconciliation names drift, it does not paper over it'

SELECT ok(NOT EXISTS (
  SELECT 1 FROM pharmacy_reconciliation() WHERE out_issue = 'The shelf figure and the movements disagree.'),
  'after everything above, no batch disagrees with its own movements');
SELECT ok(EXISTS (
  SELECT 1 FROM pharmacy_reconciliation() WHERE out_batch_number = 'EXPIRED-LOT'),
  'but the expired stock still on the shelf is reported');
SELECT ok((SELECT out_on_shelf FROM pharmacy_reconciliation() WHERE out_batch_number = 'EXPIRED-LOT') = 100,
  'with the figure that is actually there');

\echo ''
\echo '== 17. stock cannot go negative'

SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pharmacy_batches_qty_non_negative'),
  'a batch quantity is constrained non-negative');

\echo ''
\echo '== 18. dispensing works from the database figure, not a remembered one'

-- This is what the lost update was. The browser held batch quantities in
-- React state, decremented them there and wrote absolute numbers back, so
-- a figure changed by anybody else in the meantime was overwritten. The
-- adjustment below is exactly that: a change the caller does not know
-- about. The dispensing that follows has to see it.
SELECT adjust_pharmacy_batch('d0000000-0000-0000-0000-000000000006', 3, 'Damaged in transit, three left');

SELECT ok((SELECT out_quantity FROM pharmacy_dispensable_batches('c0000000-0000-0000-0000-000000000002') LIMIT 1) = 3,
  'the allocation reads 3 from the database, not the 25 the caller last saw');

SELECT dispense_pharmacy_sale(
  jsonb_build_array(jsonb_build_object('product_id', 'c0000000-0000-0000-0000-000000000002',
                                       'description', 'Amoxicillin', 'quantity', 4, 'unit_price', 1.20)),
  'Crosses to older stock', 'Dr Ly', 'RX-2026-0701');

SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'AMOX-SOON') = 0,
  'the soonest-expiring batch is emptied first');
SELECT ok((SELECT quantity FROM pharmacy_batches WHERE batch_number = 'AMOX-1') = 57,
  'and only the shortfall comes from the batch with longer to run');

\echo ''
\echo '===================================================================='
\echo ' PHARMACY: all assertions passed'
\echo '===================================================================='
