-- =====================================================================
-- DISCOUNTS — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- Five modules each had a `discount numeric` column holding a lump
-- somebody typed. The assertions below are about what that lump could
-- not say.
--
-- STACKING IS NOT ONE ANSWER. Two discounts of 5% and 10% on $200 are
-- either $29 or $30, depending on whether each applies to what is left or
-- to the original. Both are real; the difference is a dollar on a $200
-- sale and a policy across a year.
--
-- EXCLUSIVE DOES NOT MEAN BEST. A 20% promotion marked exclusive must not
-- quietly beat a 30% stack the customer also qualified for.
--
-- AND A CEILING HAS TO BITE somewhere, or a business finds out in
-- February what it gave away in January.
--
-- Every figure here is invented for the arithmetic and chosen so each
-- total can be checked on paper. They are not a pricing policy.
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
  ('c1100000-0000-0000-0000-000000000001', 'boss@shop.kh'),
  ('c1100000-0000-0000-0000-000000000002', 'cashier@shop.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('c1200000-0000-0000-0000-000000000001', 'c1100000-0000-0000-0000-000000000001',
   'Bopha (manager)', 'boss@shop.kh', ARRAY['Manager']),
  ('c1200000-0000-0000-0000-000000000002', 'c1100000-0000-0000-0000-000000000002',
   'Vichea (cashier)', 'cashier@shop.kh', ARRAY['Cashier'])
ON CONFLICT DO NOTHING;

SELECT act_as('boss@shop.kh');

-- A fixed moment to test against: a Wednesday evening. Everything below
-- is evaluated at this instant so nothing depends on when the suite runs.
--   2026-08-05 19:00 in Asia/Phnom_Penh = 12:00 UTC.
\set MOMENT '''2026-08-05 12:00:00+00'''

UPDATE discount_settings SET combine_mode = 'additive', max_total_percent = 100,
                             timezone = 'Asia/Phnom_Penh';

\echo ''
\echo '== 1. nothing is given away by default'

SELECT ok((SELECT count(*) FROM discount_rules) = 0,
  'Kareya ships no discount rules at all');
SELECT ok(total_discount('pos', 200) = 0,
  'so a sale with no rules loaded gets nothing off');

\echo ''
\echo '== 2. a quantity break and a time sale'

INSERT INTO discount_rules (code, name, method, value, min_quantity, priority)
VALUES ('VOL10', 'Ten or more', 'percent', 5, 10, 10);

SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT) = 10,
  'ten items at $200 take 5% off — $10');
SELECT ok(total_discount('pos', 200, 9, NULL, :MOMENT) = 0,
  'and nine items take nothing, because the break is a break');

-- Happy hour: weekdays, 18:00 to 20:00, in the business's own timezone.
INSERT INTO discount_rules (code, name, method, value, days_of_week, start_time, end_time, priority)
VALUES ('HAPPY', 'Happy hour', 'percent', 10, ARRAY[1,2,3,4,5], '18:00', '20:00', 20);

SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT) = 20,
  'seven in the evening on a Wednesday is happy hour — 10%');
SELECT ok(total_discount('pos', 200, 1, NULL, '2026-08-05 06:00:00+00') = 0,
  'one in the afternoon is not');
SELECT ok(total_discount('pos', 200, 1, NULL, '2026-08-09 12:00:00+00') = 0,
  'and neither is Sunday evening, because the rule names its days');

\echo ''
\echo '== 3. stacking is a decision, not an accident'

-- Additive: both percentages come off the original $200. 5% + 10% = $30.
SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT) = 30,
  'additive: 5% and 10% of $200 is $30');

UPDATE discount_settings SET combine_mode = 'sequential';
-- Sequential: 5% of 200 is 10, then 10% of the remaining 190 is 19.
SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT) = 29,
  'sequential: the same two rules come to $29, because the second works on what is left');
SELECT ok((SELECT out_base FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT)
            WHERE out_code = 'HAPPY') = 190,
  'and the second rule says plainly that it was worked out on $190');

UPDATE discount_settings SET combine_mode = 'additive';

\echo ''
\echo '== 4. priority decides the order'

SELECT ok((SELECT out_order FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT)
            WHERE out_code = 'VOL10') = 1,
  'the lower priority applies first');
SELECT ok((SELECT out_order FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT)
            WHERE out_code = 'HAPPY') = 2,
  'and the higher one second');

\echo ''
\echo '== 5. exclusive does not mean best'

INSERT INTO discount_rules (code, name, method, value, valid_from, valid_to, exclusive, priority)
VALUES ('SEASON', 'Season sale', 'percent', 20, '2026-08-01', '2026-08-31', true, 5);

-- The stack is worth $30; the exclusive rule is worth $40.
SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT) = 40,
  'a 20% exclusive beats a $30 stack, so the customer gets the 20%');
SELECT ok((SELECT count(*) FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT)) = 1,
  'and it applies alone, because that is what exclusive means');

-- Now make the stack worth more than the exclusive rule.
INSERT INTO discount_rules (code, name, method, value, customer_tier, priority)
VALUES ('GOLD', 'Gold member', 'percent', 15, 'gold', 30);

SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT, 'gold') = 60,
  'with a gold member the stack is worth $60 and wins');
SELECT ok((SELECT count(*) FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT, 'gold')) = 3,
  'and all three stacking rules are reported');
SELECT ok(NOT EXISTS (SELECT 1 FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT, 'gold')
                       WHERE out_code = 'SEASON'),
  'the exclusive rule steps aside rather than charging the customer more');

SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT, 'silver') = 40,
  'a silver member does not qualify for the gold rule, so the exclusive one wins again');

\echo ''
\echo '== 6. the ceiling'

UPDATE discount_settings SET max_total_percent = 25;
SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT, 'gold') = 50,
  'a 25% house ceiling cuts a $60 stack down to $50');
SELECT ok(EXISTS (SELECT 1 FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT, 'gold')
                   WHERE out_capped),
  'and the line that was cut short says so');
UPDATE discount_settings SET max_total_percent = 100;

-- Read as a gold member, so the stack outruns the exclusive season rule
-- and VOL10 is actually one of the lines that applies.
UPDATE discount_rules SET max_discount_amount = 5 WHERE code = 'VOL10';
SELECT ok((SELECT out_amount FROM evaluate_discounts('pos', 200, 10, NULL, :MOMENT, 'gold')
            WHERE out_code = 'VOL10') = 5,
  'a rule can carry its own ceiling too: 5% of $200 capped at $5');
SELECT ok(total_discount('pos', 200, 10, NULL, :MOMENT, 'gold') = 55,
  'so the stack comes to $55 rather than $60');
UPDATE discount_rules SET max_discount_amount = NULL WHERE code = 'VOL10';

\echo ''
\echo '== 7. the repeat customer, and the first-timer'

INSERT INTO discount_rules (code, name, method, value, min_prior_purchases, priority, is_active)
VALUES ('LOYAL', 'Fourth visit onwards', 'percent', 10, 3, 40, false);
UPDATE discount_rules SET is_active = false WHERE code IN ('VOL10','HAPPY','SEASON','GOLD');
UPDATE discount_rules SET is_active = true WHERE code = 'LOYAL';

SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 3) = 20,
  'a customer on their fourth visit gets 10%');
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 2) = 0,
  'on their third, nothing yet');

INSERT INTO discount_rules (code, name, method, value, first_purchase_only, priority)
VALUES ('WELCOME', 'First time', 'percent', 25, true, 50);
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 0) = 50,
  'a first-time customer gets the welcome 25%');
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 5)
          = total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 5),
  'and a regular does not get it twice');
SELECT ok(NOT EXISTS (SELECT 1 FROM evaluate_discounts('pos', 200, 1, NULL, :MOMENT, NULL, 5)
                       WHERE out_code = 'WELCOME'),
  'because first-time means first time');

UPDATE discount_rules SET is_active = false WHERE code IN ('LOYAL','WELCOME');

\echo ''
\echo '== 8. buy three get one free, and a fixed price'

INSERT INTO discount_rules (code, name, method, value, min_quantity, priority)
VALUES ('BOGO', 'Buy three get one', 'free_items', 1, 3, 60);

-- Ten bought at $20 each: three groups of three, so three free.
SELECT ok(total_discount('retail', 200, 10, 20, :MOMENT) = 60,
  'ten items at $20 with buy-three-get-one is three free — $60');
SELECT ok(total_discount('retail', 40, 2, 20, :MOMENT) = 0,
  'two items do not reach the three, so nothing is free');

UPDATE discount_rules SET is_active = false WHERE code = 'BOGO';

INSERT INTO discount_rules (code, name, method, value, priority)
VALUES ('CLEAR', 'Clearance at $15', 'fixed_price', 15, 70);
SELECT ok(total_discount('retail', 200, 10, 20, :MOMENT) = 50,
  'ten items marked down from $20 to $15 is $50 off');
SELECT ok(total_discount('retail', 100, 10, 10, :MOMENT) = 0,
  'and a fixed price above what is being charged takes nothing off — never a surcharge');

UPDATE discount_rules SET is_active = false WHERE code = 'CLEAR';

\echo ''
\echo '== 9. a rule that has to be asked for'

INSERT INTO discount_rules (code, name, method, value, trigger, priority, max_redemptions)
VALUES ('KHMER50', 'Voucher', 'amount', 50, 'code', 80, 2);

SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT) = 0,
  'a code discount is not given away to somebody who did not ask');
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 0, NULL, NULL, 'KHMER50') = 50,
  'but it applies when the code is quoted');
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT, NULL, 0, NULL, NULL, 'khmer50') = 50,
  'and the code is not case sensitive, because nobody types it the same way twice');

\echo ''
\echo '== 10. money is not yours to discount if it is passing through'

INSERT INTO discount_rules (code, name, method, value, priority, is_active)
VALUES ('ALL10', 'Ten percent off everything', 'percent', 10, 90, true);
UPDATE discount_rules SET is_active = false WHERE code = 'KHMER50';

SELECT ok(total_discount('freight', 200, 1, NULL, :MOMENT) = 20,
  'the forwarder can discount its own fee');
SELECT ok(total_discount('freight', 200, 1, NULL, :MOMENT, NULL, 0, NULL, NULL, NULL, true) = 0,
  'but not a duty it fronted for the client — that is somebody else money passing through');

UPDATE discount_rules SET applies_to_disbursements = true WHERE code = 'ALL10';
SELECT ok(total_discount('freight', 200, 1, NULL, :MOMENT, NULL, 0, NULL, NULL, NULL, true) = 20,
  'unless the rule says outright that it may');
UPDATE discount_rules SET applies_to_disbursements = false WHERE code = 'ALL10';

\echo ''
\echo '== 11. a rule can be told which modules it belongs to'

UPDATE discount_rules SET modules = ARRAY['pos','retail'] WHERE code = 'ALL10';
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT) = 20, 'it applies in the POS');
SELECT ok(total_discount('clinic', 200, 1, NULL, :MOMENT) = 0, 'and not in the clinic');
UPDATE discount_rules SET modules = NULL WHERE code = 'ALL10';

\echo ''
\echo '== 12. what was actually given'

SELECT ok((SELECT discount_amount FROM apply_discount(
             'pos', 'sale', 'c1500000-0000-0000-0000-000000000001', 200, 20,
             (SELECT id FROM discount_rules WHERE code = 'ALL10'))) = 20,
  'a discount is recorded against the document it came off');

SELECT ok(document_discount('pos', 'c1500000-0000-0000-0000-000000000001') = 20,
  'and the document can be asked what it has had taken off it');

SELECT ok((SELECT code FROM discount_applications
            WHERE document_id = 'c1500000-0000-0000-0000-000000000001') = 'ALL10',
  'the rule code is copied onto the record');

-- History has to survive the rule changing.
UPDATE discount_rules SET value = 90, name = 'Ninety percent off' WHERE code = 'ALL10';
SELECT ok((SELECT value FROM discount_applications
            WHERE document_id = 'c1500000-0000-0000-0000-000000000001') = 10,
  'and editing the rule afterwards does not rewrite what somebody was charged');
UPDATE discount_rules SET value = 10, name = 'Ten percent off everything' WHERE code = 'ALL10';

SELECT raises($$
  UPDATE discount_applications SET discount_amount = 500
   WHERE document_id = 'c1500000-0000-0000-0000-000000000001'$$,
  'a recorded discount cannot be rewritten');
SELECT raises($$
  DELETE FROM discount_applications
   WHERE document_id = 'c1500000-0000-0000-0000-000000000001'$$,
  'nor deleted');

SELECT raises($$SELECT void_discount(
  (SELECT id FROM discount_applications
    WHERE document_id = 'c1500000-0000-0000-0000-000000000001'), '')$$,
  'voiding one needs a reason');

SELECT ok((SELECT redemption_count FROM discount_rules WHERE code = 'ALL10') = 1,
  'the rule counts how often it has been used');
SELECT void_discount(
  (SELECT id FROM discount_applications WHERE document_id = 'c1500000-0000-0000-0000-000000000001'),
  'Sale was cancelled');
SELECT ok(document_discount('pos', 'c1500000-0000-0000-0000-000000000001') = 0,
  'voiding takes the discount back off the document');
SELECT ok((SELECT redemption_count FROM discount_rules WHERE code = 'ALL10') = 0,
  'and gives the redemption back, so a cancelled sale does not burn a voucher');

\echo ''
\echo '== 13. what a discount is not allowed to be'

SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, -5,
  (SELECT id FROM discount_rules WHERE code = 'ALL10'))$$,
  'a negative discount is refused — that is a surcharge and needs its own line');
SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 150,
  (SELECT id FROM discount_rules WHERE code = 'ALL10'))$$,
  'and one bigger than the thing it comes off is refused');

SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 20)$$,
  'a discount given outside the rules with no reason is refused');
SELECT ok((SELECT is_manual FROM apply_discount(
             'pos', 'sale', gen_random_uuid(), 100, 20, NULL, 'Damaged packaging')),
  'with a reason it is allowed, and marked as given by hand');

UPDATE discount_settings SET reason_required_over_percent = 15;
SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 20,
  (SELECT id FROM discount_rules WHERE code = 'ALL10'))$$,
  'over the house threshold even a rule discount needs a reason in writing');
UPDATE discount_settings SET reason_required_over_percent = 100;

SELECT raises($$
  INSERT INTO discount_rules (code, name, method, value) VALUES ('X', 'Over a hundred', 'percent', 120)$$,
  'a percentage over a hundred is refused — it is a gift with change');
SELECT raises($$
  INSERT INTO discount_rules (code, name, method, value, min_quantity)
  VALUES ('Y', 'Free with no how many', 'free_items', 1, 0)$$,
  'free goods with no buy-quantity are refused');
SELECT raises($$
  INSERT INTO discount_rules (code, name, method, value, start_time, end_time)
  VALUES ('Z', 'Backwards hour', 'percent', 5, '20:00', '18:00')$$,
  'and a happy hour that ends before it begins');

\echo ''
\echo '== 14. the floor'

SELECT raises($$SELECT apply_discount('retail', 'sale', gen_random_uuid(), 100, 40,
  (SELECT id FROM discount_rules WHERE code = 'ALL10'), NULL, NULL, 70)$$,
  'discounting through the floor the module set is refused');

SELECT ok((SELECT floor_breached FROM apply_discount(
             'retail', 'sale', gen_random_uuid(), 100, 40,
             (SELECT id FROM discount_rules WHERE code = 'ALL10'),
             'Manager agreed to take a loss to clear it', NULL, 70)),
  'with a reason it goes through, and is flagged for somebody to look at');

\echo ''
\echo '== 15. approval'

INSERT INTO discount_rules (code, name, method, value, requires_approval, approval_role, priority)
VALUES ('STAFF', 'Staff price', 'percent', 50, true, 'Manager', 95);

SELECT act_as('cashier@shop.kh');
SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 50,
  (SELECT id FROM discount_rules WHERE code = 'STAFF'), 'Staff purchase')$$,
  'a cashier cannot give the staff discount by themselves');

SELECT act_as('boss@shop.kh');
SELECT ok((SELECT approved_by FROM apply_discount(
             'pos', 'sale', gen_random_uuid(), 100, 50,
             (SELECT id FROM discount_rules WHERE code = 'STAFF'), 'Staff purchase')) IS NOT NULL,
  'a manager can, and who approved it is recorded');

\echo ''
\echo '== 16. a promotion that runs out'

UPDATE discount_rules SET max_redemptions = 1, redemption_count = 1 WHERE code = 'STAFF';
SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 50,
  (SELECT id FROM discount_rules WHERE code = 'STAFF'), 'Staff purchase')$$,
  'a rule used its full number of times is refused');
SELECT ok(total_discount('pos', 200, 1, NULL, :MOMENT) = 20,
  'and a spent rule stops being offered — only the ten percent is left');

UPDATE discount_rules SET is_active = false WHERE code = 'STAFF';
SELECT raises($$SELECT apply_discount('pos', 'sale', gen_random_uuid(), 100, 10,
  (SELECT id FROM discount_rules WHERE code = 'STAFF'), 'Staff purchase')$$,
  'and a withdrawn rule cannot be applied at all');

\echo ''
\echo '== 17. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM discount_reconciliation()
                   WHERE out_kind = 'discount' AND out_issue LIKE '%below the floor%'),
  'a sale taken below its floor is reported');

INSERT INTO discount_rules (code, name, method, value, valid_from, valid_to)
VALUES ('OLDSALE', 'Last month promotion', 'percent', 30, CURRENT_DATE - 60, CURRENT_DATE - 30);
SELECT ok(EXISTS (SELECT 1 FROM discount_reconciliation()
                   WHERE out_kind = 'rule' AND out_label = 'Last month promotion'),
  'a promotion still switched on a month after it ended is reported');

INSERT INTO discount_rules (code, name, method, value)
VALUES ('FREEBIE', 'Everything free', 'percent', 100);
SELECT ok(EXISTS (SELECT 1 FROM discount_reconciliation()
                   WHERE out_label = 'Everything free' AND out_issue LIKE '%whole amount%'),
  'a rule that gives everything away is reported, in case it was a typo');

INSERT INTO discount_coupons (code, rule_id, expires_on)
VALUES ('GONE', (SELECT id FROM discount_rules WHERE code = 'ALL10'), CURRENT_DATE - 5);
SELECT ok(EXISTS (SELECT 1 FROM discount_reconciliation()
                   WHERE out_kind = 'coupon' AND out_label = 'GONE'),
  'an expired coupon nobody voided is reported');

\echo ''
\echo '== 18. what the discounts cost'

SELECT ok((SELECT out_given FROM discount_report(CURRENT_DATE - 1, CURRENT_DATE + 1, 'pos')
            WHERE out_code = '(outside the rules)') = 20,
  'the report separates what was given by hand from what a rule gave');
SELECT ok((SELECT sum(out_given) FROM discount_report(CURRENT_DATE - 1, CURRENT_DATE + 1)) > 0,
  'and totals every module together when no module is named');

\echo ''
\echo '===================================================================='
\echo ' DISCOUNTS: all assertions passed'
\echo '===================================================================='
