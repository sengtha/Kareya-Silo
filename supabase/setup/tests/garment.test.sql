-- =====================================================================
-- GARMENT COST SHEET — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- garment_styles.cmt_price was one typed number per piece. The assertions
-- below are about the two things that number was hiding.
--
-- The first is efficiency. A style already carries SMV — the standard
-- minutes of sewing in one piece — but a line does not deliver a standard
-- minute in a minute. At 50% efficiency a 20-SMV garment occupies 40 real
-- minutes of a line that is paid for all 40. Quote at 75% and run at 50%
-- and the sewing cost is half what was charged for. The sensitivity test
-- below is that fact in arithmetic.
--
-- The second is amortisation. Sampling and testing cost the same whether
-- the order is 5,000 pieces or 50,000, so per piece they differ tenfold —
-- which is why buyers ask for a price at each quantity.
--
-- Figures are arbitrary and chosen so every total can be checked on paper.
-- They are not a cost sheet and nothing should be quoted from them.
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
  ('e1100000-0000-0000-0000-000000000001', 'sophal@factory.kh'),
  ('e1100000-0000-0000-0000-000000000002', 'operator@factory.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('e1200000-0000-0000-0000-000000000001', 'e1100000-0000-0000-0000-000000000001', 'Sophal (merch)', 'sophal@factory.kh',   ARRAY['Merchandiser']),
  ('e1200000-0000-0000-0000-000000000002', 'e1100000-0000-0000-0000-000000000002', 'Srey (operator)','operator@factory.kh', ARRAY['Driver'])
ON CONFLICT DO NOTHING;

SELECT act_as('sophal@factory.kh');

-- A polo shirt with 20 standard minutes of work in it.
INSERT INTO garment_styles (id, style_no, name, buyer, smv)
VALUES ('e1300000-0000-0000-0000-000000000001', 'PL-4471', 'Mens polo', 'Buyer A', 20);

INSERT INTO garment_lines (id, name, worker_count)
VALUES ('e1400000-0000-0000-0000-000000000001', 'Line 1', 50);

-- 50 workers x 8 hours x 25 days x 60 = 600,000 minutes for $18,000,
-- so one available minute costs exactly $0.03.
INSERT INTO garment_line_costs (id, line_id, name, monthly_cost, workers, hours_per_day, days_per_month, cost_source)
VALUES ('e1500000-0000-0000-0000-000000000001', 'e1400000-0000-0000-0000-000000000001',
        'Line 1 monthly', 18000, 50, 8, 25, 'Payroll plus allocated factory overhead');

INSERT INTO estimate_resources (id, code, name, resource_type, unit, unit_cost, domain, price_source) VALUES
  ('e1600000-0000-0000-0000-000000000001', 'FAB-PIQ', 'Pique knit fabric', 'material', 'yd', 2.00, 'garment', 'Mill quotation'),
  ('e1600000-0000-0000-0000-000000000002', 'TRM-BTN', 'Button',            'material', 'pc', 0.02, 'garment', 'Supplier list'),
  ('e1600000-0000-0000-0000-000000000003', 'TRM-LBL', 'Woven label set',   'material', 'set', 0.03, 'garment', 'Supplier list')
ON CONFLICT DO NOTHING;

\echo ''
\echo '== 1. what a minute of sewing costs'

SELECT ok(garment_available_minutes('e1500000-0000-0000-0000-000000000001') = 600000,
  '50 workers x 8 hours x 25 days is 600,000 minutes a month');
SELECT ok(garment_cost_per_minute('e1500000-0000-0000-0000-000000000001') = 0.03,
  'and $18,000 over those minutes is 3 cents an available minute');

\echo ''
\echo '== 2. THE HEADLINE: the sewing cost depends on efficiency'

INSERT INTO garment_cost_sheets (id, style_id, buyer, basis, order_quantity, line_cost_id,
                                 assumed_efficiency_pct, overhead_percent, margin_percent)
VALUES ('e1700000-0000-0000-0000-000000000001', 'e1300000-0000-0000-0000-000000000001',
        'Buyer A', 'cmt', 10000, 'e1500000-0000-0000-0000-000000000001', 50, 0, 0);

-- 20 SMV at 50% efficiency is 40 real minutes; 40 x 0.03 = 1.20
SELECT ok(garment_cm_cost('e1700000-0000-0000-0000-000000000001') = 1.20,
  'A 20-SMV GARMENT AT 50% EFFICIENCY COSTS $1.20 TO SEW — 40 real minutes, not 20');

UPDATE garment_cost_sheets SET assumed_efficiency_pct = 75
 WHERE id = 'e1700000-0000-0000-0000-000000000001';
-- 20 / 0.75 = 26.6667 minutes x 0.03 = 0.80
SELECT ok(garment_cm_cost('e1700000-0000-0000-0000-000000000001') = 0.80,
  'at 75% the same garment costs $0.80 — the same work, a third less money');

UPDATE garment_cost_sheets SET assumed_efficiency_pct = 100
 WHERE id = 'e1700000-0000-0000-0000-000000000001';
SELECT ok(garment_cm_cost('e1700000-0000-0000-0000-000000000001') = 0.60,
  'and at a perfect 100% it is $0.60, which is the floor nobody reaches');

UPDATE garment_cost_sheets SET assumed_efficiency_pct = 50
 WHERE id = 'e1700000-0000-0000-0000-000000000001';

SELECT ok((SELECT count(*) FROM garment_efficiency_sensitivity('e1700000-0000-0000-0000-000000000001')) = 5,
  'the sensitivity table prices the style at five efficiencies');
SELECT ok((SELECT out_cm FROM garment_efficiency_sensitivity(
             'e1700000-0000-0000-0000-000000000001', ARRAY[40]) ) = 1.50,
  'at 40% the sewing alone is $1.50');
SELECT ok((SELECT out_cm FROM garment_efficiency_sensitivity(
             'e1700000-0000-0000-0000-000000000001', ARRAY[80]) ) = 0.75,
  'at 80% it is $0.75 — the spread a merchandiser and a production manager should argue about BEFORE the price goes out');

\echo ''
\echo '== 3. a CMT price is for the making only'

-- The buyer supplies the fabric and trims on CMT, so charging for them
-- would be charging twice.
INSERT INTO garment_cost_lines (sheet_id, category, description, resource_id, unit, consumption, wastage_percent, sort_order) VALUES
  ('e1700000-0000-0000-0000-000000000001', 'fabric', 'Pique body', 'e1600000-0000-0000-0000-000000000001', 'yd', 1.5, 5, 1),
  ('e1700000-0000-0000-0000-000000000001', 'trim', 'Placket buttons', 'e1600000-0000-0000-0000-000000000002', 'pc', 3, 0, 2),
  ('e1700000-0000-0000-0000-000000000001', 'trim', 'Labels', 'e1600000-0000-0000-0000-000000000003', 'set', 1, 0, 3);

SELECT ok((SELECT amount FROM garment_cost_lines WHERE description = 'Pique body') = 3.15,
  '1.5 yards at $2.00 with 5% wastage is $3.15 of fabric');
SELECT ok((SELECT amount FROM garment_cost_lines WHERE description = 'Placket buttons') = 0.06,
  'three buttons at 2 cents is 6 cents');

SELECT ok((SELECT out_fabric FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 0,
  'ON A CMT SHEET THE FABRIC IS NOT CHARGED — the buyer supplied it');
SELECT ok((SELECT out_trim FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 0,
  'and neither are the trims');
SELECT ok((SELECT out_direct_cost FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 1.20,
  'so the CMT cost is the sewing: $1.20');

\echo ''
\echo '== 4. the same sheet on an FOB basis'

UPDATE garment_cost_sheets SET basis = 'fob' WHERE id = 'e1700000-0000-0000-0000-000000000001';

-- fabric 3.15 + trims 0.09 + sewing 1.20 = 4.44
SELECT ok((SELECT out_fabric FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 3.15,
  'on FOB the factory buys the fabric, so it is charged');
SELECT ok((SELECT out_trim FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 0.09,
  'and the trims');
SELECT ok((SELECT out_direct_cost FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 4.44,
  'so the FOB cost is $4.44 against a CMT cost of $1.20 — the same garment, a different question');

SELECT ok((SELECT out_share_pct FROM garment_cost_breakdown('e1700000-0000-0000-0000-000000000001')
            WHERE out_category = 'fabric') = 70.95,
  'and fabric is 71% of it, which is why a cotton price move IS the job');

\echo ''
\echo '== 5. a price change in the book reaches every sheet built on it'

UPDATE estimate_resources SET unit_cost = 2.20, price_source = 'Mill letter, 3 June'
 WHERE code = 'FAB-PIQ';

SELECT ok((SELECT count(*) FROM resource_price_history
            WHERE resource_id = 'e1600000-0000-0000-0000-000000000001') = 2,
  'the rise is on the record with its source');

-- The stored line still carries the old figure until it is re-priced: the
-- sheet is what was quoted, and it does not move on its own.
UPDATE garment_cost_lines SET consumption = consumption
 WHERE description = 'Pique body';
SELECT ok((SELECT amount FROM garment_cost_lines WHERE description = 'Pique body') = 3.465,
  '1.5 yards at the new $2.20 with wastage is $3.465');
SELECT ok((SELECT out_direct_cost FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 4.755,
  'and the FOB cost moves to $4.755 — a 10% fabric rise is 7% on the garment');

\echo ''
\echo '== 6. one-off costs divide by the order quantity'

INSERT INTO garment_cost_lines (sheet_id, category, description, unit, consumption, unit_cost, is_one_off, sort_order)
VALUES ('e1700000-0000-0000-0000-000000000001', 'commercial', 'Lab testing and sampling', 'lot', 1, 500, true, 4);

-- $500 over 10,000 pieces is 5 cents each.
SELECT ok((SELECT amount FROM garment_cost_lines WHERE description = 'Lab testing and sampling') = 0.05,
  '$500 of testing over 10,000 pieces is 5 cents a piece');

-- The same style at 50,000: a new sheet, because the buyer asked a
-- different question.
SELECT revise_cost_sheet('e1700000-0000-0000-0000-000000000001', 50000) \gset big_

SELECT ok((SELECT amount FROM garment_cost_lines l
             JOIN garment_cost_sheets s ON s.id = l.sheet_id
            WHERE s.order_quantity = 50000 AND l.description = 'Lab testing and sampling') = 0.01,
  'THE SAME $500 OVER 50,000 PIECES IS 1 CENT — which is why a buyer asks for a price at each quantity');
SELECT ok((SELECT revision FROM garment_cost_sheets WHERE order_quantity = 50000) = 'A',
  'a price at a different quantity is a new sheet at revision A, not a revision of the old one');
SELECT ok((SELECT status FROM garment_cost_sheets WHERE id = 'e1700000-0000-0000-0000-000000000001') = 'draft',
  'and the 10,000-piece sheet is left alone, because it still answers its own question');

\echo ''
\echo '== 7. what a sheet will not let you quote'

INSERT INTO garment_styles (id, style_no, name, smv)
VALUES ('e1300000-0000-0000-0000-000000000009', 'NO-SMV', 'Never timed', 0);
INSERT INTO garment_cost_sheets (id, style_id, basis, order_quantity, line_cost_id, assumed_efficiency_pct)
VALUES ('e1700000-0000-0000-0000-000000000009', 'e1300000-0000-0000-0000-000000000009',
        'cmt', 1000, 'e1500000-0000-0000-0000-000000000001', 60);
SELECT raises($$SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000009')$$,
  'a style with no SMV cannot be quoted — nothing can work out the sewing');

INSERT INTO garment_cost_sheets (id, style_id, basis, order_quantity, assumed_efficiency_pct)
VALUES ('e1700000-0000-0000-0000-000000000008', 'e1300000-0000-0000-0000-000000000001', 'cmt', 1000, 60);
SELECT raises($$SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000008')$$,
  'a sheet with no line cost cannot be quoted — a minute of sewing would be free');

UPDATE garment_cost_sheets SET line_cost_id = 'e1500000-0000-0000-0000-000000000001',
                               assumed_efficiency_pct = 0
 WHERE id = 'e1700000-0000-0000-0000-000000000008';
SELECT raises($$SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000008')$$,
  'nor one with no efficiency, for the same reason');

\echo ''
\echo '== 8. what was quoted to the buyer does not change'

UPDATE garment_cost_sheets SET overhead_percent = 10, margin_percent = 12
 WHERE id = 'e1700000-0000-0000-0000-000000000001';

-- direct 4.805 (4.755 + 0.05 testing) x 1.10 x 1.12
SELECT ok((SELECT out_direct_cost FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 4.805,
  'the sheet costs $4.805 to make');
SELECT ok((SELECT out_price FROM garment_sheet_summary('e1700000-0000-0000-0000-000000000001')) = 5.9198,
  'and prices at $5.9198 with 10% overhead and 12% margin');

SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000001');
SELECT ok((SELECT status FROM garment_cost_sheets WHERE id = 'e1700000-0000-0000-0000-000000000001') = 'quoted',
  'the sheet is quoted');

SELECT raises($$
  INSERT INTO garment_cost_lines (sheet_id, category, description, unit, consumption, unit_cost)
  VALUES ('e1700000-0000-0000-0000-000000000001', 'trim', 'Sneaked in', 'pc', 1, 1)
$$, 'a line cannot be added to a sheet that has gone to the buyer');
SELECT raises($$UPDATE garment_cost_lines SET consumption = 99 WHERE description = 'Pique body'$$,
  'nor changed');
SELECT raises($$SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000001')$$,
  'and quoting it twice is refused');

\echo ''
\echo '== 9. agreeing a price, and what it does'

SELECT raises($$SELECT agree_cost_sheet('e1700000-0000-0000-0000-000000000001', 3.00)$$,
  'agreeing below what the garment costs to make is refused');

SELECT agree_cost_sheet('e1700000-0000-0000-0000-000000000001', 5.60);
SELECT ok((SELECT status FROM garment_cost_sheets WHERE id = 'e1700000-0000-0000-0000-000000000001') = 'agreed',
  'a buyer negotiating down to $5.60 is recorded as agreed');
SELECT ok((SELECT agreed_price FROM garment_cost_sheets WHERE id = 'e1700000-0000-0000-0000-000000000001') = 5.60,
  'at the price actually agreed, not the one on the sheet');
SELECT ok((SELECT cmt_price FROM garment_styles WHERE id = 'e1300000-0000-0000-0000-000000000001') = 5.60,
  'AND THE STYLE PRICE FOLLOWS IT — a number somebody arrived at, not one somebody remembered');

\echo ''
\echo '== 10. THE ONE THAT MATTERS: quoted at an efficiency nobody achieves'

INSERT INTO garment_orders (id, po_no, style_id, buyer, quantity, cmt_price)
VALUES ('e1800000-0000-0000-0000-000000000001', 'PO-9001', 'e1300000-0000-0000-0000-000000000001',
        'Buyer A', 10000, 5.60);

-- The factory books its daily output. These lines run at about 45%.
INSERT INTO garment_outputs (order_id, line_id, date, output_qty, working_hours, efficiency_pct) VALUES
  ('e1800000-0000-0000-0000-000000000001', 'e1400000-0000-0000-0000-000000000001', CURRENT_DATE - 3, 540, 8, 45),
  ('e1800000-0000-0000-0000-000000000001', 'e1400000-0000-0000-0000-000000000001', CURRENT_DATE - 2, 528, 8, 44),
  ('e1800000-0000-0000-0000-000000000001', 'e1400000-0000-0000-0000-000000000001', CURRENT_DATE - 1, 552, 8, 46);

SELECT ok((SELECT out_avg_pct FROM garment_achieved_efficiency()) = 45.00,
  'the lines have actually averaged 45%');
SELECT ok((SELECT out_days FROM garment_achieved_efficiency()) = 3,
  'over three booked days');

SELECT ok(EXISTS (SELECT 1 FROM garment_costing_reconciliation()
                   WHERE out_kind = 'sheet' AND out_issue LIKE 'Priced at 50%%'),
  'AND THE SHEET PRICED AT 50% IS REPORTED AGAINST THE 45% THE FACTORY ACHIEVES — the number was already in the database and the quote never looked at it');

SELECT ok(EXISTS (SELECT 1 FROM garment_costing_reconciliation()
                   WHERE out_kind = 'sheet' AND out_issue LIKE 'Agreed at 5.60%'),
  'agreeing below the sheet price is reported too, so a decision is not mistaken for an accident');

SELECT ok(EXISTS (SELECT 1 FROM garment_costing_reconciliation()
                   WHERE out_kind = 'style' AND out_issue LIKE 'Has no SMV%'),
  'a style nobody has timed is reported');

INSERT INTO garment_styles (id, style_no, name, smv, cmt_price)
VALUES ('e1300000-0000-0000-0000-000000000007', 'GUESS-1', 'Priced from memory', 15, 4.20);
SELECT ok(EXISTS (SELECT 1 FROM garment_costing_reconciliation()
                   WHERE out_kind = 'style' AND out_issue LIKE 'Has a CMT price but no cost sheet%'),
  'and so is a style carrying a price with no sheet behind it');

UPDATE garment_orders SET cmt_price = 4.90 WHERE po_no = 'PO-9001';
SELECT ok(EXISTS (SELECT 1 FROM garment_costing_reconciliation()
                   WHERE out_kind = 'order' AND out_label = 'PO-9001'),
  'a purchase order priced differently from what was agreed is reported');

\echo ''
\echo '== 11. who may price a style'

SELECT act_as('operator@factory.kh');
SELECT raises($$SELECT quote_cost_sheet('e1700000-0000-0000-0000-000000000008')$$,
  'a machine operator cannot quote a style');
SELECT raises($$SELECT agree_cost_sheet('e1700000-0000-0000-0000-000000000008', 9)$$,
  'nor agree a price with a buyer');
SELECT act_as('sophal@factory.kh');

\echo ''
\echo '===================================================================='
\echo ' GARMENT COSTING: all assertions passed'
\echo '===================================================================='
