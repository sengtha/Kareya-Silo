-- =====================================================================
-- FREIGHT QUOTING — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A freight quote used to be a description and an amount. The assertions
-- below are about the four things that arrangement could not express.
--
-- CHARGEABLE WEIGHT. A carrier bills the greater of what a shipment
-- weighs and what it occupies. 0.6 CBM at the IATA divisor of 6000 is
-- 100 kilos however light the cargo is, so a 30 kg consignment of that
-- shape is a 100 kg consignment on the invoice. Quoting the 30 gives 70
-- kilos of freight away.
--
-- THE MINIMUM. Every air rate has one, and below it the multiplication
-- does not apply. Eight kilos at $5.00 is $40 on paper and $50 on the
-- bill.
--
-- WEIGHT BREAKS. A higher band is cheaper per kilo, so 44 kilos at the
-- under-45 rate costs more than declaring 45 at the over-45 rate. That is
-- not a rounding curiosity; it is $85 on the numbers below.
--
-- BUY AND SELL. One amount per line cannot say whether the file made
-- money. Two can.
--
-- Every rate here is invented for the arithmetic and chosen so each total
-- can be checked on paper. They are not market rates. Nothing should be
-- quoted from them.
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
  ('f1100000-0000-0000-0000-000000000001', 'dara@forwarder.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('f1200000-0000-0000-0000-000000000001', 'f1100000-0000-0000-0000-000000000001',
   'Dara (freight officer)', 'dara@forwarder.kh', ARRAY['Freight Officer'])
ON CONFLICT DO NOTHING;

SELECT act_as('dara@forwarder.kh');

\echo ''
\echo '== 1. chargeable weight: the number the carrier actually bills'

-- A cubic metre is 1,000,000 cm3. At the IATA divisor of 6000 that is
-- 166.6667 kg; 0.6 CBM is exactly 100.
SELECT ok(freight_volumetric_kg(0.6, 6000) = 100,
  '0.6 CBM is 100 volumetric kilos at the IATA 6000 divisor');
SELECT ok(freight_volumetric_kg(0.6, 5000) = 120,
  'and 120 at the 5000 divisor express carriers commonly use');

SELECT ok(freight_chargeable_kg(30, 0.6, 6000) = 100,
  'a light bulky shipment is billed on its volume, not its weight');
SELECT ok(freight_chargeable_kg(250, 0.6, 6000) = 250,
  'and a dense one on its weight, not its volume');
SELECT ok(freight_chargeable_kg(30, 0, 6000) = 30,
  'with no volume recorded the chargeable weight collapses to the gross weight');

-- Sea LCL is billed W/M — weight or measurement, in revenue tonnes.
SELECT ok(freight_revenue_tonnes(800, 1.5, 1000) = 1.5,
  '800 kg in 1.5 CBM is 1.5 revenue tonnes: the measurement wins');
SELECT ok(freight_revenue_tonnes(2400, 1.5, 1000) = 2.4,
  'and 2400 kg in the same space is 2.4: the weight wins');

\echo ''
\echo '== 2. volume follows the dimensions on the packing list'

INSERT INTO freight_jobs (id, job_no, client_name, direction, mode)
VALUES ('f1300000-0000-0000-0000-000000000001', 'FJ-0001', 'Mekong Trading', 'import', 'air');

-- 100 x 50 x 40 cm is 0.2 CBM a carton; three cartons is 0.6.
INSERT INTO freight_items (id, job_id, description, piece_count, length_cm, width_cm, height_cm, weight_kg)
VALUES ('f1310000-0000-0000-0000-000000000001', 'f1300000-0000-0000-0000-000000000001',
        'Cushions', 3, 100, 50, 40, 30);

SELECT ok((SELECT volume_cbm FROM freight_items WHERE id = 'f1310000-0000-0000-0000-000000000001') = 0.6,
  'three cartons of 100x50x40 come to 0.6 CBM without anyone working it out');

UPDATE freight_items SET piece_count = 6 WHERE id = 'f1310000-0000-0000-0000-000000000001';
SELECT ok((SELECT volume_cbm FROM freight_items WHERE id = 'f1310000-0000-0000-0000-000000000001') = 1.2,
  'and doubling the cartons doubles the volume');
UPDATE freight_items SET piece_count = 3 WHERE id = 'f1310000-0000-0000-0000-000000000001';

\echo ''
\echo '== 3. a rate card that knows when it stops being true'

INSERT INTO freight_tariffs (id, name, carrier, mode, service_type, origin, destination,
                             currency, volumetric_divisor, valid_from, valid_to, rate_source)
VALUES ('f1400000-0000-0000-0000-000000000001', 'PNH-HKG air', 'An airline', 'air', 'air',
        'PNH', 'HKG', 'USD', 6000, CURRENT_DATE - 10, CURRENT_DATE + 20,
        'Carrier rate sheet, invented for this test');

-- Freight, banded. The over-45 rate is cheaper per kilo, as air rates are.
INSERT INTO freight_tariff_rates (id, tariff_id, charge_code, description, basis,
                                  break_from_kg, break_to_kg, buy_rate, sell_rate, minimum_charge, sort_order)
VALUES
 ('f1410000-0000-0000-0000-000000000001', 'f1400000-0000-0000-0000-000000000001',
  'FRT', 'Air freight (under 45 kg)', 'per_kg', 0, 45, 4.00, 5.00, 50, 10),
 ('f1410000-0000-0000-0000-000000000002', 'f1400000-0000-0000-0000-000000000001',
  'FRT', 'Air freight (45 kg and over)', 'per_kg', 45, NULL, 2.00, 3.00, 50, 10);

INSERT INTO freight_tariff_rates (id, tariff_id, charge_code, description, basis,
                                  buy_rate, sell_rate, minimum_charge, sort_order)
VALUES
 ('f1410000-0000-0000-0000-000000000003', 'f1400000-0000-0000-0000-000000000001',
  'FSC', 'Fuel surcharge', 'per_kg', 0.40, 0.50, 0, 20),
 ('f1410000-0000-0000-0000-000000000004', 'f1400000-0000-0000-0000-000000000001',
  'DOC', 'Documentation', 'per_shipment', 20, 35, 0, 30);

-- Duty fronted for the client and recharged at cost. Never revenue.
INSERT INTO freight_tariff_rates (id, tariff_id, charge_code, description, basis,
                                  buy_rate, sell_rate, is_disbursement, sort_order)
VALUES ('f1410000-0000-0000-0000-000000000005', 'f1400000-0000-0000-0000-000000000001',
        'CUS', 'Customs duty and taxes', 'per_shipment', 45, 45, true, 40);

SELECT raises($$
  INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis,
                                    break_from_kg, break_to_kg, buy_rate, sell_rate)
  VALUES ('f1400000-0000-0000-0000-000000000001', 'FRT', 'Overlapping band', 'per_kg', 40, 100, 1, 2)$$,
  'a weight band that overlaps another band of the same charge is refused');

SELECT raises($$
  INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis,
                                    break_from_kg, break_to_kg, buy_rate, sell_rate)
  VALUES ('f1400000-0000-0000-0000-000000000001', 'XXX', 'Backwards band', 'per_kg', 100, 50, 1, 2)$$,
  'and so is a band that ends before it begins');

SELECT ok(freight_pick_rate('f1400000-0000-0000-0000-000000000001', 'FRT', 44)
          = 'f1410000-0000-0000-0000-000000000001',
  '44 kilos falls in the under-45 band');
SELECT ok(freight_pick_rate('f1400000-0000-0000-0000-000000000001', 'FRT', 45)
          = 'f1410000-0000-0000-0000-000000000002',
  '45 kilos falls in the over-45 band — the boundary belongs to the band above');

\echo ''
\echo '== 4. pricing an air shipment'

INSERT INTO freight_quotes (id, job_id, client_name, direction, mode, origin, destination,
                            tariff_id, gross_weight_kg, volume_cbm, piece_count,
                            currency, quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000001', 'f1300000-0000-0000-0000-000000000001',
        'Mekong Trading', 'import', 'air', 'PNH', 'HKG',
        'f1400000-0000-0000-0000-000000000001', 30, 0.6, 3,
        'USD', CURRENT_DATE, CURRENT_DATE + 14);

SELECT ok((SELECT quote_no FROM freight_quotes WHERE id = 'f1500000-0000-0000-0000-000000000001')
          LIKE 'FQ-%', 'a quote takes a number from the series without being asked');

SELECT ok(price_freight_quote('f1500000-0000-0000-0000-000000000001') = 4,
  'four charges come off the rate card: freight, fuel, documentation and duty');

-- The whole point: 30 kg of cargo, priced as 100.
SELECT ok((SELECT quantity FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'FRT') = 100,
  'the freight is charged on 100 chargeable kilos, not the 30 the cargo weighs');

SELECT ok((SELECT rate_id FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'FRT')
          = 'f1410000-0000-0000-0000-000000000002',
  'and at 100 kilos it takes the cheaper over-45 band by itself');

SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'FRT') = 300,
  '100 kilos at $3.00 is $300 to the client');
SELECT ok((SELECT amount_buy FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'FRT') = 200,
  'and $200 to the airline');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'FSC') = 50,
  'the fuel surcharge follows the same chargeable weight');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'DOC') = 35,
  'a per-shipment charge is levied once whatever the cargo is');
SELECT ok((SELECT is_disbursement FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000001' AND charge_code = 'CUS'),
  'and the duty comes across still marked a disbursement');

\echo ''
\echo '== 5. the total, read the way a forwarder reads it'

SELECT ok((SELECT out_chargeable_kg FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 100,
  'chargeable weight: 100 kg');
SELECT ok((SELECT out_volumetric_kg FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 100,
  'volumetric weight: 100 kg');
SELECT ok((SELECT out_sell FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 385,
  'the forwarder own fees come to $385 (300 + 50 + 35)');
SELECT ok((SELECT out_disbursements FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 45,
  'the duty of $45 is held apart — it is cash fronted, not income');
SELECT ok((SELECT out_total_to_client FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 430,
  'the client is billed $430 in total');
SELECT ok((SELECT out_buy FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 260,
  'the carrier costs $260, counting revenue lines only');
SELECT ok((SELECT out_margin FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 125,
  'so the file makes $125');
SELECT ok((SELECT out_margin_pct FROM freight_quote_summary('f1500000-0000-0000-0000-000000000001')) = 32.47,
  'which is 32.47% of the revenue, not of the $430 the client pays');

\echo ''
\echo '== 6. the minimum charge, which no multiplication finds'

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000002', 'Small Parcel Co', 'air',
        'f1400000-0000-0000-0000-000000000001', 8, 0, CURRENT_DATE, CURRENT_DATE + 7);

SELECT price_freight_quote('f1500000-0000-0000-0000-000000000002');

SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000002' AND charge_code = 'FRT') = 50,
  'eight kilos at $5.00 is $40 on paper and $50 on the bill');
SELECT ok((SELECT minimum_applied FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000002' AND charge_code = 'FRT'),
  'and the line says so, rather than leaving someone to wonder');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000002' AND charge_code = 'FSC') = 4,
  'a charge with no minimum is left alone');

\echo ''
\echo '== 7. the weight break: 44 kilos costs more than 45'

SELECT ok((SELECT out_next_break_kg FROM freight_break_advice(
             'f1400000-0000-0000-0000-000000000001', 'FRT', 44)) = 45,
  'at 44 kilos the next break is 45');
SELECT ok((SELECT out_as_shipped FROM freight_break_advice(
             'f1400000-0000-0000-0000-000000000001', 'FRT', 44)) = 220,
  '44 kilos at the under-45 rate is $220');
SELECT ok((SELECT out_at_break FROM freight_break_advice(
             'f1400000-0000-0000-0000-000000000001', 'FRT', 44)) = 135,
  'declaring 45 at the over-45 rate is $135');
SELECT ok((SELECT out_saving FROM freight_break_advice(
             'f1400000-0000-0000-0000-000000000001', 'FRT', 44)) = 85,
  'so the shipment is $85 cheaper carrying a kilo it does not have');

SELECT ok(NOT EXISTS (SELECT 1 FROM freight_break_advice(
            'f1400000-0000-0000-0000-000000000001', 'FRT', 100)),
  'above the last break there is nothing to advise, and nothing is said');
SELECT ok(NOT EXISTS (SELECT 1 FROM freight_break_advice(
            'f1400000-0000-0000-0000-000000000001', 'FSC', 10)),
  'a charge with a single band never triggers the advice');

\echo ''
\echo '== 8. sea LCL is priced on revenue tonnes'

INSERT INTO freight_tariffs (id, name, mode, service_type, origin, destination,
                             currency, wm_kg_per_cbm, valid_from, rate_source)
VALUES ('f1400000-0000-0000-0000-000000000002', 'SIN-PNH LCL', 'sea', 'lcl', 'SIN', 'PNH',
        'USD', 1000, CURRENT_DATE - 5, 'Console operator quote, invented for this test');

INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis,
                                  buy_rate, sell_rate, minimum_charge, sort_order)
VALUES
 ('f1400000-0000-0000-0000-000000000002', 'OFR', 'Ocean freight W/M', 'per_wm', 30, 45, 60, 10),
 ('f1400000-0000-0000-0000-000000000002', 'THC', 'Terminal handling', 'per_cbm', 10, 15, 0, 20);

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000003', 'Angkor Ceramics', 'sea',
        'f1400000-0000-0000-0000-000000000002', 800, 1.5, CURRENT_DATE, CURRENT_DATE + 30);

SELECT price_freight_quote('f1500000-0000-0000-0000-000000000003');

SELECT ok((SELECT quantity FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000003' AND charge_code = 'OFR') = 1.5,
  '800 kg in 1.5 CBM is charged as 1.5 revenue tonnes');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000003' AND charge_code = 'OFR') = 67.5,
  'at $45 a tonne that is $67.50, clear of the $60 minimum');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000003' AND charge_code = 'THC') = 22.5,
  'and terminal handling is charged on the cubic metres, not the tonnes');
SELECT ok((SELECT out_revenue_tonnes FROM freight_quote_summary('f1500000-0000-0000-0000-000000000003')) = 1.5,
  'the summary reports the revenue tonnes the price was built on');

\echo ''
\echo '== 9. FCL is priced per box, and insurance on the value'

INSERT INTO freight_tariffs (id, name, mode, service_type, origin, destination,
                             currency, valid_from, rate_source)
VALUES ('f1400000-0000-0000-0000-000000000003', 'SHA-SHV FCL', 'sea', 'fcl', 'SHA', 'SHV',
        'USD', CURRENT_DATE - 5, 'Line contract, invented for this test');

INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis, container_type,
                                  buy_rate, sell_rate, sort_order)
VALUES
 ('f1400000-0000-0000-0000-000000000003', 'OFR', 'Ocean freight 20GP', 'per_container', '20GP', 900, 1100, 10),
 ('f1400000-0000-0000-0000-000000000003', 'OFR', 'Ocean freight 40HC', 'per_container', '40HC', 1500, 1800, 20);

-- Insurance is a percentage of the declared value, not a rate per unit.
INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis,
                                  buy_rate, sell_rate, minimum_charge, sort_order)
VALUES ('f1400000-0000-0000-0000-000000000003', 'INS', 'Cargo insurance', 'percent_of_value',
        0.10, 0.15, 25, 30);

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, declared_value,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000004', 'Delta Furniture', 'sea',
        'f1400000-0000-0000-0000-000000000003', 20000, CURRENT_DATE, CURRENT_DATE + 21);

INSERT INTO freight_quote_containers (quote_id, container_type, container_count) VALUES
  ('f1500000-0000-0000-0000-000000000004', '20GP', 2),
  ('f1500000-0000-0000-0000-000000000004', '40HC', 1);

SELECT price_freight_quote('f1500000-0000-0000-0000-000000000004');

SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000004'
              AND description LIKE '%20GP') = 2200,
  'two twenty-foot boxes at $1,100 is $2,200');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000004'
              AND description LIKE '%40HC') = 1800,
  'and one forty-foot high cube is priced on its own rate, not the twenty-foot one');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000004' AND charge_code = 'INS') = 30,
  'insurance at 0.15% of a $20,000 declared value is $30');
SELECT ok((SELECT out_sell FROM freight_quote_summary('f1500000-0000-0000-0000-000000000004')) = 4030,
  'the sell total is $4,030');

-- On a smaller value the minimum takes over.
UPDATE freight_quotes SET declared_value = 10000 WHERE id = 'f1500000-0000-0000-0000-000000000004';
SELECT price_freight_quote('f1500000-0000-0000-0000-000000000004');
SELECT ok((SELECT amount_sell FROM freight_quote_lines
            WHERE quote_id = 'f1500000-0000-0000-0000-000000000004' AND charge_code = 'INS') = 25,
  '0.15% of $10,000 is $15, so the $25 minimum takes over');
UPDATE freight_quotes SET declared_value = 20000 WHERE id = 'f1500000-0000-0000-0000-000000000004';
SELECT price_freight_quote('f1500000-0000-0000-0000-000000000004');

\echo ''
\echo '== 10. a tariff that has expired is not a tariff'

INSERT INTO freight_tariffs (id, name, mode, valid_from, valid_to, rate_source)
VALUES ('f1400000-0000-0000-0000-000000000009', 'Last month rates', 'air',
        CURRENT_DATE - 60, CURRENT_DATE - 30, 'Superseded card, invented for this test');

INSERT INTO freight_tariff_rates (tariff_id, charge_code, description, basis, buy_rate, sell_rate)
VALUES ('f1400000-0000-0000-0000-000000000009', 'FRT', 'Air freight', 'per_kg', 1.00, 2.00);

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000005', 'Stale Quote Ltd', 'air',
        'f1400000-0000-0000-0000-000000000009', 100, CURRENT_DATE, CURRENT_DATE + 7);

SELECT raises($$SELECT price_freight_quote('f1500000-0000-0000-0000-000000000005')$$,
  'a quote cannot be priced off a rate card that expired last month');

INSERT INTO freight_quotes (id, client_name, mode, gross_weight_kg, quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000006', 'No Tariff Co', 'air', 50,
        CURRENT_DATE, CURRENT_DATE + 7);
SELECT raises($$SELECT price_freight_quote('f1500000-0000-0000-0000-000000000006')$$,
  'nor with no rate card at all — there would be nothing to apply');

\echo ''
\echo '== 11. what has to be true before a price goes out'

SELECT raises($$SELECT send_freight_quote('f1500000-0000-0000-0000-000000000006')$$,
  'a quote with no charges on it cannot be sent');

-- Validity: a freight rate that never expires is a fiction.
INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm, quote_date)
VALUES ('f1500000-0000-0000-0000-000000000007', 'Open Ended Ltd', 'air',
        'f1400000-0000-0000-0000-000000000001', 30, 0.6, CURRENT_DATE);
SELECT price_freight_quote('f1500000-0000-0000-0000-000000000007');
SELECT raises($$SELECT send_freight_quote('f1500000-0000-0000-0000-000000000007')$$,
  'and neither can one with no expiry date on the price');

UPDATE freight_quotes SET valid_until = CURRENT_DATE + 7
 WHERE id = 'f1500000-0000-0000-0000-000000000007';

-- Selling under cost is allowed to exist, but not to leave the building
-- unnoticed.
INSERT INTO freight_quote_lines (quote_id, description, basis, quantity,
                                 buy_rate, sell_rate, amount_buy, amount_sell, is_manual)
VALUES ('f1500000-0000-0000-0000-000000000007', 'Special handling', 'per_shipment', 1,
        500, 0, 500, 0, true);
SELECT raises($$SELECT send_freight_quote('f1500000-0000-0000-0000-000000000007')$$,
  'a quote that sells below what the carrier charges is refused');

DELETE FROM freight_quote_lines
 WHERE quote_id = 'f1500000-0000-0000-0000-000000000007' AND is_manual = true;

SELECT ok((SELECT status FROM send_freight_quote('f1500000-0000-0000-0000-000000000007')) = 'sent',
  'with cargo, charges, an expiry and a margin, it goes out');

\echo ''
\echo '== 12. what was sent stays sent'

SELECT raises($$
  UPDATE freight_quote_lines SET sell_rate = 1
   WHERE quote_id = 'f1500000-0000-0000-0000-000000000007' AND charge_code = 'FRT'$$,
  'a line on a sent quote cannot be quietly edited');

SELECT raises($$
  DELETE FROM freight_quote_lines
   WHERE quote_id = 'f1500000-0000-0000-0000-000000000007' AND charge_code = 'DOC'$$,
  'nor deleted');

SELECT raises($$SELECT price_freight_quote('f1500000-0000-0000-0000-000000000007')$$,
  'and the whole quote cannot be repriced behind the client back');

\echo ''
\echo '== 13. a revision, rather than a rewrite'

INSERT INTO freight_quote_lines (quote_id, description, basis, quantity,
                                 buy_rate, sell_rate, amount_buy, amount_sell, is_manual)
VALUES ('f1500000-0000-0000-0000-000000000001', 'Palletising', 'per_shipment', 1, 15, 25, 15, 25, true);

SELECT ok((SELECT revision FROM revise_freight_quote('f1500000-0000-0000-0000-000000000001')) = 'B',
  'a revision of A is B');

SELECT ok((SELECT count(*) FROM freight_quotes
            WHERE quote_no = (SELECT quote_no FROM freight_quotes
                               WHERE id = 'f1500000-0000-0000-0000-000000000001')) = 2,
  'and it keeps the quote number, so the client sees one reference');

SELECT ok((SELECT status FROM freight_quotes WHERE id = 'f1500000-0000-0000-0000-000000000001')
          = 'superseded',
  'the sheet it came from is marked superseded rather than deleted');

SELECT ok((SELECT count(*) FROM freight_quote_lines l
            JOIN freight_quotes q ON q.id = l.quote_id
           WHERE q.revision = 'B' AND q.client_name = 'Mekong Trading') = 1,
  'the hand-typed line is carried over');

SELECT ok((SELECT count(*) FROM freight_quote_lines l
            JOIN freight_quotes q ON q.id = l.quote_id
           WHERE q.revision = 'B' AND q.client_name = 'Mekong Trading' AND l.is_manual = false) = 0,
  'and the priced lines are not — they come back from the tariff, at current rates');

SELECT price_freight_quote((SELECT id FROM freight_quotes
                             WHERE revision = 'B' AND client_name = 'Mekong Trading'));
SELECT ok((SELECT count(*) FROM freight_quote_lines l
            JOIN freight_quotes q ON q.id = l.quote_id
           WHERE q.revision = 'B' AND q.client_name = 'Mekong Trading') = 5,
  'repriced, revision B carries the four tariff charges plus the typed one');

\echo ''
\echo '== 14. accepting turns a quote into a file'

UPDATE freight_quotes SET valid_until = CURRENT_DATE + 14
 WHERE revision = 'B' AND client_name = 'Mekong Trading';

SELECT ok((SELECT status FROM accept_freight_quote(
             (SELECT id FROM freight_quotes WHERE revision = 'B' AND client_name = 'Mekong Trading')))
          = 'booked',
  'accepting a quote against an existing file books it');

SELECT ok((SELECT count(*) FROM freight_charges
            WHERE job_id = 'f1300000-0000-0000-0000-000000000001') = 5,
  'all five charges land on the job without anyone retyping them');

-- 385 revenue + 45 duty + 25 palletising = 455.
SELECT ok((SELECT charges_total FROM freight_jobs
            WHERE id = 'f1300000-0000-0000-0000-000000000001') = 455,
  'and the job total is $455 — the quote, not a recollection of it');

SELECT ok((SELECT count(*) FROM freight_charges
            WHERE job_id = 'f1300000-0000-0000-0000-000000000001' AND is_disbursement) = 1,
  'the duty is still a disbursement on the job, so it stays out of revenue');

SELECT ok((SELECT status FROM freight_quotes
            WHERE revision = 'B' AND client_name = 'Mekong Trading') = 'accepted',
  'and the quote is marked accepted');

\echo ''
\echo '== 15. a price that has run out'

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000008', 'Late Decider Co', 'air',
        'f1400000-0000-0000-0000-000000000001', 30, 0.6,
        CURRENT_DATE - 10, CURRENT_DATE - 1);
SELECT price_freight_quote('f1500000-0000-0000-0000-000000000008');
SELECT send_freight_quote('f1500000-0000-0000-0000-000000000008');

SELECT raises($$SELECT accept_freight_quote('f1500000-0000-0000-0000-000000000008')$$,
  'a price that ran out yesterday cannot be accepted today');

SELECT ok(expire_freight_quotes() >= 1,
  'and the sweep moves it to expired, so nobody chases it');
SELECT ok((SELECT status FROM freight_quotes WHERE id = 'f1500000-0000-0000-0000-000000000008')
          = 'expired',
  'the status says so plainly');

\echo ''
\echo '== 16. a quote that was lost is worth keeping'

INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-000000000009', 'Went Elsewhere Ltd', 'air',
        'f1400000-0000-0000-0000-000000000001', 30, 0.6, CURRENT_DATE, CURRENT_DATE + 7);
SELECT price_freight_quote('f1500000-0000-0000-0000-000000000009');
SELECT send_freight_quote('f1500000-0000-0000-0000-000000000009');

SELECT ok((SELECT status FROM decline_freight_quote(
             'f1500000-0000-0000-0000-000000000009', 'Beaten by $40 on the freight')) = 'declined',
  'a lost quote is recorded, not deleted');
SELECT ok((SELECT notes FROM freight_quotes WHERE id = 'f1500000-0000-0000-0000-000000000009')
          LIKE '%Beaten by $40%',
  'with the reason, which is the only part worth anything later');

\echo ''
\echo '== 17. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM freight_quoting_reconciliation()
                   WHERE out_kind = 'tariff' AND out_label = 'Last month rates'),
  'a rate card still switched on a month after it expired is reported');

-- An air shipment with no volume is billed on gross weight, which is the
-- defect this whole vertical exists to stop.
INSERT INTO freight_quotes (id, client_name, mode, tariff_id, gross_weight_kg, volume_cbm,
                            quote_date, valid_until)
VALUES ('f1500000-0000-0000-0000-00000000000a', 'No Volume Co', 'air',
        'f1400000-0000-0000-0000-000000000001', 300, 0, CURRENT_DATE, CURRENT_DATE + 7);
SELECT ok(EXISTS (SELECT 1 FROM freight_quoting_reconciliation()
                   WHERE out_kind = 'quote' AND out_label LIKE '%A'
                     AND out_issue LIKE '%no volume%'),
  'an air quote with no volume recorded is reported');

INSERT INTO freight_jobs (id, job_no, client_name, charges_total)
VALUES ('f1300000-0000-0000-0000-000000000002', 'FJ-0002', 'Unpriced Client', 900);
SELECT ok(EXISTS (SELECT 1 FROM freight_quoting_reconciliation()
                   WHERE out_kind = 'job' AND out_label = 'FJ-0002'),
  'a file carrying charges with no quote behind them is reported');

SELECT ok(NOT EXISTS (SELECT 1 FROM freight_quoting_reconciliation()
                       WHERE out_kind = 'job' AND out_label = 'FJ-0001'),
  'the accepted file matches its quote exactly and is not reported');

UPDATE freight_charges SET amount = amount + 20
 WHERE job_id = 'f1300000-0000-0000-0000-000000000001'
   AND id = (SELECT id FROM freight_charges
              WHERE job_id = 'f1300000-0000-0000-0000-000000000001' LIMIT 1);
UPDATE freight_jobs SET charges_total = 475 WHERE id = 'f1300000-0000-0000-0000-000000000001';
SELECT ok(EXISTS (SELECT 1 FROM freight_quoting_reconciliation()
                   WHERE out_kind = 'job' AND out_label = 'FJ-0001'),
  'but the moment the file is billed differently from the quote, it is');

\echo ''
\echo '===================================================================='
\echo ' FREIGHT QUOTING: all assertions passed'
\echo '===================================================================='
