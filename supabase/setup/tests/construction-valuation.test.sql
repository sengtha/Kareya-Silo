-- =====================================================================
-- TAKE-OFF, VARIATIONS AND INTERIM VALUATION — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- Three typed numbers become worked-out ones here: the quantity, the
-- contract sum after a change, and the amount on an interim certificate.
--
-- The assertions that matter most are the ones about claiming twice. A
-- valuation measures work TO DATE and the certificate pays the difference,
-- so however the months are cut the same concrete cannot be certified in
-- two of them. progress_claims held one percentage for a whole project and
-- an amount somebody typed beside it, which could not do this at all.
--
-- Figures are arbitrary and chosen so the arithmetic can be checked on
-- paper. They are not a price book and not a contract.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded. Any failure aborts the run.
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
  ('d0100000-0000-0000-0000-000000000001', 'qs@build.kh'),
  ('d0100000-0000-0000-0000-000000000002', 'labourer@build.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('d0200000-0000-0000-0000-000000000001', 'd0100000-0000-0000-0000-000000000001', 'Vuthy (QS)',   'qs@build.kh',       ARRAY['Site Manager']),
  ('d0200000-0000-0000-0000-000000000002', 'd0100000-0000-0000-0000-000000000002', 'Sam (labour)', 'labourer@build.kh', ARRAY['Driver'])
ON CONFLICT DO NOTHING;

SELECT act_as('qs@build.kh');

-- No overhead and no margin, so every figure below is the arithmetic being
-- tested and nothing else.
INSERT INTO construction_estimates (id, title, client_name, overhead_percent, margin_percent)
VALUES ('d0300000-0000-0000-0000-000000000001', 'Shophouse, Battambang', 'Mr Vann', 0, 0);

INSERT INTO boq_sections (id, estimate_id, title, sort_order)
VALUES ('d0400000-0000-0000-0000-000000000001', 'd0300000-0000-0000-0000-000000000001', 'Substructure', 1);

INSERT INTO boq_items (id, estimate_id, section_id, description, item_type, unit, quantity, rate_cost, sort_order)
VALUES ('d0500000-0000-0000-0000-000000000001', 'd0300000-0000-0000-0000-000000000001',
        'd0400000-0000-0000-0000-000000000001', 'Excavate for foundations', 'measured', 'm3', 0, 5.00, 1),
       ('d0500000-0000-0000-0000-000000000002', 'd0300000-0000-0000-0000-000000000001',
        'd0400000-0000-0000-0000-000000000001', 'Mass concrete in foundations', 'measured', 'm3', 100, 100.00, 2);

\echo ''
\echo '== 1. THE HEADLINE: a quantity is measured, not typed'

-- Two strip footings 12m x 0.6m x 0.9m, less one 2m length where the
-- footing is stepped. This is a take-off sheet, written the way one is.
INSERT INTO boq_takeoff (item_id, description, nr, length, width, height, sort_order) VALUES
  ('d0500000-0000-0000-0000-000000000001', 'Strip footing, grid A',  2, 12,  0.6, 0.9, 1),
  ('d0500000-0000-0000-0000-000000000001', 'Strip footing, grid B',  1, 8,   0.6, 0.9, 2),
  ('d0500000-0000-0000-0000-000000000001', 'Ddt step at grid A/3',  -1, 2,   0.6, 0.9, 3);

-- 2 x 12 x 0.6 x 0.9 = 12.96 ; 1 x 8 x 0.6 x 0.9 = 4.32 ; -1 x 2 x 0.6 x 0.9 = -1.08
SELECT ok((SELECT quantity FROM boq_takeoff WHERE description = 'Strip footing, grid A') = 12.96,
  'two footings 12 x 0.6 x 0.9 measure 12.96 cubic metres');
SELECT ok((SELECT quantity FROM boq_takeoff WHERE description = 'Ddt step at grid A/3') = -1.08,
  'a deduction line measures negative, which is how a take-off sheet takes things off');
SELECT ok((SELECT quantity FROM boq_items WHERE id = 'd0500000-0000-0000-0000-000000000001') = 16.20,
  'AND THE ITEM QUANTITY IS THE SHEET TOTAL — 16.20, not a number somebody typed');
SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'd0500000-0000-0000-0000-000000000001') = 81.00,
  'the money follows the measurement');

SELECT ok((SELECT count(*) FROM boq_takeoff_sheet('d0500000-0000-0000-0000-000000000001')) = 3,
  'the sheet can be shown to a client, line by line');
SELECT ok((SELECT out_dims FROM boq_takeoff_sheet('d0500000-0000-0000-0000-000000000001')
            WHERE out_line = 'Strip footing, grid B') = '1 nr x 8 x 0.6 x 0.9',
  'with the dimensions that produced each line');

SELECT raises($$UPDATE boq_items SET quantity = 999 WHERE id = 'd0500000-0000-0000-0000-000000000001'$$,
  'a measured quantity cannot be typed over — change the dimensions instead');

-- A linear item has a length and nothing else. A blank dimension is not a
-- zero, or every measurement would come out at nothing.
INSERT INTO boq_items (id, estimate_id, section_id, description, item_type, unit, rate_cost, sort_order)
VALUES ('d0500000-0000-0000-0000-000000000003', 'd0300000-0000-0000-0000-000000000001',
        'd0400000-0000-0000-0000-000000000001', 'Damp proof course', 'measured', 'm', 3.00, 3);
INSERT INTO boq_takeoff (item_id, description, nr, length)
VALUES ('d0500000-0000-0000-0000-000000000003', 'Perimeter', 1, 44);
SELECT ok((SELECT quantity FROM boq_items WHERE id = 'd0500000-0000-0000-0000-000000000003') = 44,
  'a linear measurement with only a length comes out at its length');

DELETE FROM boq_takeoff WHERE description = 'Ddt step at grid A/3';
SELECT ok((SELECT quantity FROM boq_items WHERE id = 'd0500000-0000-0000-0000-000000000001') = 17.28,
  'removing a line from the sheet re-totals the item');

\echo ''
\echo '== 2. an accepted price is a contract'

SELECT issue_estimate('d0300000-0000-0000-0000-000000000001');
UPDATE construction_estimates SET status = 'accepted', accepted_at = now()
 WHERE id = 'd0300000-0000-0000-0000-000000000001';

SELECT raises($$
  INSERT INTO boq_takeoff (item_id, description, nr, length)
  VALUES ('d0500000-0000-0000-0000-000000000003', 'More', 1, 5)
$$, 'the take-off sheet behind an accepted bill cannot be edited');

-- 17.28 x 5 = 86.40 ; 100 x 100 = 10000 ; 44 x 3 = 132  -> 10218.40
SELECT ok((SELECT out_original FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 10218.40,
  'the accepted bill totals 10,218.40');
SELECT ok((SELECT out_contract FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 10218.40,
  'and with nothing varied that is the contract sum');

\echo ''
\echo '== 3. variations change the contract, edits do not'

INSERT INTO construction_variations (id, estimate_id, title, reason)
VALUES ('d0600000-0000-0000-0000-000000000001', 'd0300000-0000-0000-0000-000000000001',
        'Additional ground beam at grid C', 'Client added a rear extension');

SELECT ok((SELECT variation_no FROM construction_variations WHERE id = 'd0600000-0000-0000-0000-000000000001') = 'VO01',
  'a variation is numbered in sequence on the job');

INSERT INTO variation_items (id, variation_id, description, item_type, unit, quantity, rate_cost, sort_order)
VALUES ('d0700000-0000-0000-0000-000000000001', 'd0600000-0000-0000-0000-000000000001',
        'Reinforced concrete ground beam', 'measured', 'm3', 6, 120.00, 1),
       ('d0700000-0000-0000-0000-000000000002', 'd0600000-0000-0000-0000-000000000001',
        'Omit part of strip footing at grid C', 'measured', 'm3', -2, 100.00, 2);

SELECT ok((SELECT amount_sell FROM variation_items WHERE id = 'd0700000-0000-0000-0000-000000000002') = -200.00,
  'omitted work is a negative quantity, so a variation can take money OFF the contract');

SELECT ok((SELECT out_pending FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 520.00,
  'the variation is pending at 520.00 (720 added less 200 omitted)');
SELECT ok((SELECT out_contract FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 10218.40,
  'and a PENDING variation does not move the contract sum');

SELECT decide_variation('d0600000-0000-0000-0000-000000000001', true, 'Instruction 04 dated 12 May');

SELECT ok((SELECT out_variations FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 520.00,
  'approving it brings it into the contract');
SELECT ok((SELECT out_contract FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 10738.40,
  'and the contract sum becomes 10,738.40');
SELECT ok((SELECT out_pending FROM contract_sum('d0300000-0000-0000-0000-000000000001')) = 0,
  'with nothing left pending');

SELECT raises($$UPDATE variation_items SET quantity = 50 WHERE id = 'd0700000-0000-0000-0000-000000000001'$$,
  'an approved variation cannot be edited afterwards');
SELECT raises($$SELECT decide_variation('d0600000-0000-0000-0000-000000000001', true)$$,
  'nor decided twice');

INSERT INTO construction_variations (id, estimate_id, title)
VALUES ('d0600000-0000-0000-0000-000000000002', 'd0300000-0000-0000-0000-000000000001', 'Empty variation');
SELECT raises($$SELECT decide_variation('d0600000-0000-0000-0000-000000000002', true)$$,
  'a variation with nothing priced in it cannot be approved');
SELECT raises($$SELECT decide_variation('d0600000-0000-0000-0000-000000000002', false, '  ')$$,
  'and turning one down needs a reason');
SELECT decide_variation('d0600000-0000-0000-0000-000000000002', false, 'Withdrawn by the client');
SELECT ok((SELECT status FROM construction_variations WHERE id = 'd0600000-0000-0000-0000-000000000002') = 'rejected',
  'a rejected variation is recorded rather than deleted');

\echo ''
\echo '== 4. an interim certificate is worked out, not typed'

INSERT INTO interim_valuations (id, estimate_id, period_to, retention_percent)
VALUES ('d0800000-0000-0000-0000-000000000001', 'd0300000-0000-0000-0000-000000000001',
        CURRENT_DATE, 10);

SELECT ok((SELECT valuation_no FROM interim_valuations WHERE id = 'd0800000-0000-0000-0000-000000000001') = 1,
  'the first valuation on a job is number 1');

-- Half the excavation, a fifth of the concrete, none of the DPC.
INSERT INTO valuation_items (valuation_id, boq_item_id, quantity_to_date) VALUES
  ('d0800000-0000-0000-0000-000000000001', 'd0500000-0000-0000-0000-000000000001', 8.64),
  ('d0800000-0000-0000-0000-000000000001', 'd0500000-0000-0000-0000-000000000002', 20);

-- 8.64 x 5 = 43.20 ; 20 x 100 = 2000  -> 2043.20
SELECT ok((SELECT out_gross_to_date FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 2043.20,
  'the gross value of work to date is 2,043.20 — added up, not entered');
SELECT ok((SELECT out_retention_held FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 204.32,
  'retention at 10% is 204.32');
SELECT ok((SELECT out_net_to_date FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 1838.88,
  'so the net to date is 1,838.88');
SELECT ok((SELECT out_previously_certified FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 0,
  'nothing has been certified before');
SELECT ok((SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 1838.88,
  'and that whole amount is due on this certificate');
SELECT ok((SELECT out_contract_sum FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 10738.40,
  'the certificate shows the contract sum including the approved variation');
SELECT ok((SELECT out_percent_complete FROM valuation_certificate('d0800000-0000-0000-0000-000000000001')) = 19.03,
  'and the job is 19.03% complete by value — derived, not a number somebody felt');

SELECT raises($$
  INSERT INTO valuation_items (valuation_id, boq_item_id, quantity_to_date)
  VALUES ('d0800000-0000-0000-0000-000000000001', 'd0500000-0000-0000-0000-000000000002', 5)
$$, 'the same item cannot be measured twice on one valuation');

SELECT raises($$
  UPDATE valuation_items SET quantity_to_date = 500
   WHERE boq_item_id = 'd0500000-0000-0000-0000-000000000002'
$$, 'measuring more than the bill holds is refused — that is a variation nobody raised');

SELECT raises($$
  INSERT INTO interim_valuations (estimate_id, period_to) VALUES ('d0300000-0000-0000-0000-000000000001', CURRENT_DATE)
$$, 'a second valuation cannot be opened while one is still running');

\echo ''
\echo '== 5. THE SAME WORK IS NOT CERTIFIED TWICE'

SELECT certify_valuation('d0800000-0000-0000-0000-000000000001');
SELECT ok((SELECT status FROM interim_valuations WHERE id = 'd0800000-0000-0000-0000-000000000001') = 'certified',
  'valuation 1 is certified');
SELECT ok((SELECT certified_by FROM interim_valuations WHERE id = 'd0800000-0000-0000-0000-000000000001')
          = 'd0200000-0000-0000-0000-000000000001',
  'by a named person');

SELECT raises($$UPDATE valuation_items SET quantity_to_date = 1
                 WHERE valuation_id = 'd0800000-0000-0000-0000-000000000001'$$,
  'a certified valuation cannot be re-measured');
SELECT raises($$DELETE FROM interim_valuations WHERE id = 'd0800000-0000-0000-0000-000000000001'$$,
  'nor deleted — it is what was paid against');
SELECT raises($$UPDATE interim_valuations SET status = 'draft'
                 WHERE id = 'd0800000-0000-0000-0000-000000000001'$$,
  'nor reopened');

-- Valuation 2 measures the job TO DATE, not the month. The excavation is
-- finished and the concrete is half done.
INSERT INTO interim_valuations (id, estimate_id, period_to, retention_percent)
VALUES ('d0800000-0000-0000-0000-000000000002', 'd0300000-0000-0000-0000-000000000001',
        CURRENT_DATE + 30, 10);

INSERT INTO valuation_items (valuation_id, boq_item_id, quantity_to_date) VALUES
  ('d0800000-0000-0000-0000-000000000002', 'd0500000-0000-0000-0000-000000000001', 17.28),
  ('d0800000-0000-0000-0000-000000000002', 'd0500000-0000-0000-0000-000000000002', 50);

-- 17.28 x 5 = 86.40 ; 50 x 100 = 5000  -> 5086.40 gross to date
-- retention 508.64 ; net to date 4577.76 ; previously certified 1838.88
-- due now 2738.88
SELECT ok((SELECT out_gross_to_date FROM valuation_certificate('d0800000-0000-0000-0000-000000000002')) = 5086.40,
  'valuation 2 measures 5,086.40 of work done TO DATE');
SELECT ok((SELECT out_previously_certified FROM valuation_certificate('d0800000-0000-0000-0000-000000000002')) = 1838.88,
  'it knows 1,838.88 was already certified');
SELECT ok((SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000002')) = 2738.88,
  'SO ONLY THE DIFFERENCE IS DUE — 2,738.88, and the first certificate is not paid again');
SELECT ok((SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000001'))
          + (SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000002'))
          = (SELECT out_net_to_date FROM valuation_certificate('d0800000-0000-0000-0000-000000000002')),
  'and the two certificates add up to exactly the net value of the work done');

SELECT raises($$
  UPDATE valuation_items SET quantity_to_date = 2
   WHERE valuation_id = 'd0800000-0000-0000-0000-000000000002'
     AND boq_item_id = 'd0500000-0000-0000-0000-000000000002'
$$, 'a later valuation cannot measure less than a certified one already did');

\echo ''
\echo '== 6. approved variations can be valued; pending ones cannot'

INSERT INTO valuation_items (valuation_id, variation_item_id, quantity_to_date)
VALUES ('d0800000-0000-0000-0000-000000000002', 'd0700000-0000-0000-0000-000000000001', 3);
SELECT ok((SELECT value_to_date FROM valuation_items
            WHERE variation_item_id = 'd0700000-0000-0000-0000-000000000001') = 360.00,
  'work on an approved variation is valued at its own rate');

INSERT INTO construction_variations (id, estimate_id, title)
VALUES ('d0600000-0000-0000-0000-000000000003', 'd0300000-0000-0000-0000-000000000001', 'Not yet decided');
INSERT INTO variation_items (id, variation_id, description, item_type, unit, quantity, rate_cost)
VALUES ('d0700000-0000-0000-0000-000000000003', 'd0600000-0000-0000-0000-000000000003',
        'Extra blockwork', 'measured', 'm2', 20, 15.00);
SELECT raises($$
  INSERT INTO valuation_items (valuation_id, variation_item_id, quantity_to_date)
  VALUES ('d0800000-0000-0000-0000-000000000002', 'd0700000-0000-0000-0000-000000000003', 5)
$$, 'work on a variation nobody has approved cannot be certified');

\echo ''
\echo '== 7. where the job stands'

SELECT certify_valuation('d0800000-0000-0000-0000-000000000002');

SELECT ok((SELECT out_contract_sum FROM job_financial_position('d0300000-0000-0000-0000-000000000001')) = 10738.40,
  'the contract is worth 10,738.40');
SELECT ok((SELECT out_certified FROM job_financial_position('d0300000-0000-0000-0000-000000000001')) = 5446.40,
  '5,446.40 has been certified');
SELECT ok((SELECT out_remaining FROM job_financial_position('d0300000-0000-0000-0000-000000000001')) = 5292.00,
  'and 5,292.00 of the contract is still to come');
SELECT ok((SELECT out_retention_held FROM job_financial_position('d0300000-0000-0000-0000-000000000001')) = 544.64,
  'with 544.64 held as retention');

\echo ''
\echo '== 8. retention only holds what the contract says it holds'

INSERT INTO construction_estimates (id, title, overhead_percent, margin_percent)
VALUES ('d0300000-0000-0000-0000-000000000002', 'Capped retention job', 0, 0);
INSERT INTO boq_items (id, estimate_id, description, item_type, unit, quantity, rate_cost)
VALUES ('d0500000-0000-0000-0000-000000000009', 'd0300000-0000-0000-0000-000000000002',
        'Everything', 'measured', 'item', 1, 10000);
SELECT issue_estimate('d0300000-0000-0000-0000-000000000002');
UPDATE construction_estimates SET status = 'accepted' WHERE id = 'd0300000-0000-0000-0000-000000000002';

-- 10% of the work done, but capped at 3% of the contract sum.
INSERT INTO interim_valuations (id, estimate_id, retention_percent, retention_cap_pct)
VALUES ('d0800000-0000-0000-0000-000000000009', 'd0300000-0000-0000-0000-000000000002', 10, 3);
INSERT INTO valuation_items (valuation_id, boq_item_id, quantity_to_date)
VALUES ('d0800000-0000-0000-0000-000000000009', 'd0500000-0000-0000-0000-000000000009', 1);

SELECT ok((SELECT out_gross_to_date FROM valuation_certificate('d0800000-0000-0000-0000-000000000009')) = 10000,
  'all the work is done');
SELECT ok((SELECT out_retention_held FROM valuation_certificate('d0800000-0000-0000-0000-000000000009')) = 300.00,
  '10% would be 1,000 but the contract caps retention at 3%, so 300 is held');
SELECT ok((SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000009')) = 9700.00,
  'and 9,700 is due');

UPDATE interim_valuations SET retention_released = 150
 WHERE id = 'd0800000-0000-0000-0000-000000000009';
SELECT ok((SELECT out_retention_held FROM valuation_certificate('d0800000-0000-0000-0000-000000000009')) = 150.00,
  'releasing half the retention leaves 150 held');
SELECT ok((SELECT out_due_now FROM valuation_certificate('d0800000-0000-0000-0000-000000000009')) = 9850.00,
  'and the released half is paid');

SELECT raises($$
  INSERT INTO interim_valuations (estimate_id, retention_percent)
  VALUES ('d0300000-0000-0000-0000-000000000002', 150)
$$, 'a retention of 150% is refused');

\echo ''
\echo '== 9. who may certify'

SELECT act_as('labourer@build.kh');
SELECT raises($$SELECT certify_valuation('d0800000-0000-0000-0000-000000000009')$$,
  'a labourer cannot certify a valuation');
SELECT raises($$SELECT decide_variation('d0600000-0000-0000-0000-000000000003', true)$$,
  'nor approve a variation');
SELECT act_as('qs@build.kh');

SELECT raises($$SELECT certify_valuation((SELECT id FROM interim_valuations
                  WHERE estimate_id = 'd0300000-0000-0000-0000-000000000001' AND valuation_no = 1))$$,
  'certifying an already-certified valuation is refused');

\echo ''
\echo '===================================================================='
\echo ' TAKE-OFF, VARIATIONS AND VALUATION: all assertions passed'
\echo '===================================================================='
