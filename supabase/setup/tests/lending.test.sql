-- =====================================================================
-- LENDING INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The schedule a borrower signs and the interest a pawn customer pays
-- were both worked out in a browser. Every assertion here is about a
-- figure that decides how much money somebody owes.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/lending.test.sql
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

CREATE OR REPLACE FUNCTION act_as(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT user_id INTO v_uid FROM employees WHERE email = p_email;
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_email)::text, false);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('11000000-0000-0000-0000-000000000001', 'officer@mfi.kh'),
  ('11000000-0000-0000-0000-000000000002', 'clerk@mfi.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('12000000-0000-0000-0000-000000000001', '11000000-0000-0000-0000-000000000001', 'Sina (loan officer)', 'officer@mfi.kh', ARRAY['Loan Officer']),
  ('12000000-0000-0000-0000-000000000002', '11000000-0000-0000-0000-000000000002', 'Bopha (clerk)',       'clerk@mfi.kh',   ARRAY['Reception'])
ON CONFLICT DO NOTHING;

INSERT INTO borrowers (id, name, phone) VALUES
  ('13000000-0000-0000-0000-000000000001', 'Chea Sokun', '012000111')
ON CONFLICT DO NOTHING;

SELECT act_as('officer@mfi.kh');

\echo '== 1. the schedule is computed by the database'

-- Flat: 1200 at 12% over 12 months is 144 of interest, 100 principal and
-- 12 interest a month. Simple enough to check by hand, which is the point.
SELECT ok((SELECT count(*) FROM build_loan_schedule(1200, 12, 12, 'flat', DATE '2026-01-31')) = 12,
  'a twelve-month flat loan produces twelve installments');
SELECT ok((SELECT sum(out_principal_due) FROM build_loan_schedule(1200, 12, 12, 'flat', DATE '2026-01-31')) = 1200,
  'and the principal adds back to exactly what was lent');
SELECT ok((SELECT sum(out_interest_due) FROM build_loan_schedule(1200, 12, 12, 'flat', DATE '2026-01-31')) = 144,
  'and the interest to exactly what was agreed');

-- Declining: the principal must still add back exactly, with the last row
-- absorbing the rounding. That is where a hand-rolled schedule drifts.
SELECT ok((SELECT sum(out_principal_due) FROM build_loan_schedule(1000, 18, 6, 'declining', DATE '2026-01-01')) = 1000,
  'a declining-balance schedule also adds back to the principal, to the cent');
SELECT ok((SELECT out_interest_due FROM build_loan_schedule(1000, 18, 6, 'declining', DATE '2026-01-01')
            WHERE out_installment_no = 1) = 15.00,
  'the first month charges interest on the whole balance');
SELECT ok((SELECT out_interest_due FROM build_loan_schedule(1000, 18, 6, 'declining', DATE '2026-01-01')
            WHERE out_installment_no = 6)
        < (SELECT out_interest_due FROM build_loan_schedule(1000, 18, 6, 'declining', DATE '2026-01-01')
            WHERE out_installment_no = 1),
  'and the last month less, because the balance has come down');

SELECT ok((SELECT sum(out_interest_due) FROM build_loan_schedule(1000, 0, 6, 'declining', DATE '2026-01-01')) = 0,
  'a nil-rate loan charges nothing');

SELECT raises($$SELECT * FROM build_loan_schedule(0, 12, 12, 'flat', CURRENT_DATE)$$,
  'a loan of nothing is refused');
SELECT raises($$SELECT * FROM build_loan_schedule(1000, -5, 12, 'flat', CURRENT_DATE)$$,
  'a negative interest rate is refused');
SELECT raises($$SELECT * FROM build_loan_schedule(1000, 12, 12, 'compound', CURRENT_DATE)$$,
  'an interest method this system does not implement is refused, not guessed');

\echo '== 2. disbursement is one act'

INSERT INTO loans (id, loan_number, borrower_id, principal, interest_rate, term_months, method, status)
VALUES ('14000000-0000-0000-0000-000000000001', 'WHATEVER', '13000000-0000-0000-0000-000000000001',
        1200, 12, 12, 'flat', 'pending');

SELECT ok((SELECT loan_number FROM loans WHERE id = '14000000-0000-0000-0000-000000000001') <> 'WHATEVER',
  'the loan number a browser sent is ignored');
SELECT ok((SELECT loan_number FROM loans WHERE id = '14000000-0000-0000-0000-000000000001')
          = 'L-' || to_char(CURRENT_DATE, 'YYYY') || '-000001',
  'and the database issues it');

SELECT act_as('clerk@mfi.kh');
SELECT raises($$SELECT disburse_loan('14000000-0000-0000-0000-000000000001')$$,
  'a clerk cannot disburse a loan');
SELECT act_as('officer@mfi.kh');

SELECT ok((disburse_loan('14000000-0000-0000-0000-000000000001', DATE '2026-01-31')).status = 'active',
  'the loan officer disburses it');
SELECT ok((SELECT count(*) FROM loan_schedule WHERE loan_id = '14000000-0000-0000-0000-000000000001') = 12,
  'and the schedule was written in the same act');
SELECT ok((SELECT sum(total_due) FROM loan_schedule WHERE loan_id = '14000000-0000-0000-0000-000000000001') = 1344,
  'the borrower owes principal plus the agreed interest, and nothing else');

-- The double-click case: two round-trips used to be able to write the
-- schedule twice.
SELECT raises($$SELECT disburse_loan('14000000-0000-0000-0000-000000000001')$$,
  'a loan already disbursed cannot be disbursed again');

\echo '== 3. the schedule cannot be edited afterwards'

SELECT raises($$UPDATE loan_schedule SET total_due = 1 WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'an installment amount cannot be changed — it is the contract');
SELECT raises($$UPDATE loan_schedule SET due_date = CURRENT_DATE WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'nor when it falls due');
SELECT raises($$UPDATE loan_schedule SET paid_amount = 9999 WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'and what a borrower has paid cannot be typed in');
SELECT raises($$DELETE FROM loan_schedule WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'an installment cannot be deleted');

\echo '== 4. a repayment is allocated by the database'

-- One instalment is 100 principal + 12 interest.
SELECT ok((SELECT out_interest FROM record_loan_repayment('14000000-0000-0000-0000-000000000001', 112)) = 12,
  'a payment of one instalment clears that month''s interest');
SELECT ok((SELECT out_principal FROM record_loan_repayment('14000000-0000-0000-0000-000000000001', 112)) = 100,
  'and that month''s principal — interest first, within the instalment');
SELECT ok((SELECT count(*) FROM loan_schedule
            WHERE loan_id = '14000000-0000-0000-0000-000000000001' AND status = 'paid') = 2,
  'two instalments are settled');

-- The lost-update case made deterministic: the second call must see the
-- first one's result. Under the old browser arithmetic both allocations
-- started from the same figures and one payment was lost.
SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 112);
SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 112);
SELECT ok((SELECT sum(paid_amount) FROM loan_schedule
            WHERE loan_id = '14000000-0000-0000-0000-000000000001') = 448,
  'four payments in a row credit four payments, not three');
SELECT ok((SELECT count(*) FROM loan_reconciliation()
            WHERE out_loan_id = '14000000-0000-0000-0000-000000000001') = 0,
  'and the repayments and the schedule agree');

-- A part payment lands on the oldest unpaid instalment, interest first.
SELECT ok((SELECT out_interest FROM record_loan_repayment('14000000-0000-0000-0000-000000000001', 12)) = 12,
  'a part payment clears the interest before it touches principal');
SELECT ok((SELECT status FROM loan_schedule
            WHERE loan_id = '14000000-0000-0000-0000-000000000001' AND installment_no = 5) = 'partial',
  'and the instalment reads as partly paid');

SELECT raises($$SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 0)$$,
  'a repayment of nothing is refused');
SELECT raises($$SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 99999)$$,
  'more than the loan owes is refused rather than quietly swallowed');
SELECT ok((SELECT sum(paid_amount) FROM loan_schedule
            WHERE loan_id = '14000000-0000-0000-0000-000000000001') = 460,
  'and the refusal left the loan alone');

SELECT act_as('nobody@elsewhere.kh');
SELECT raises($$SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 50)$$,
  'somebody who is not an employee cannot take a repayment');
SELECT act_as('officer@mfi.kh');

SELECT raises($$UPDATE loan_repayments SET amount = 1 WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'a repayment cannot be edited after the borrower handed the money over');
SELECT raises($$DELETE FROM loan_repayments WHERE loan_id = '14000000-0000-0000-0000-000000000001'$$,
  'nor deleted');

\echo '== 5. settling the loan closes it'

-- 1344 owed, 460 paid, so 884 settles it exactly.
SELECT ok((SELECT out_loan_status FROM record_loan_repayment('14000000-0000-0000-0000-000000000001', 884)) = 'closed',
  'paying the balance closes the loan');
SELECT ok((SELECT count(*) FROM loan_schedule
            WHERE loan_id = '14000000-0000-0000-0000-000000000001' AND status <> 'paid') = 0,
  'with every instalment settled');
SELECT raises($$SELECT record_loan_repayment('14000000-0000-0000-0000-000000000001', 10)$$,
  'a closed loan takes no more repayments');

\echo '== 6. pawn interest is worked out at the counter by the database'

INSERT INTO pawn_tickets (id, ticket_number, customer_name, pawn_date, principal, interest_rate, status)
VALUES ('15000000-0000-0000-0000-000000000001', 'PW-001', 'Srey Neang',
        (CURRENT_DATE - interval '3 months')::date, 500, 3, 'active');
INSERT INTO pawn_items (ticket_id, description, appraised_value, status)
VALUES ('15000000-0000-0000-0000-000000000001', '22K gold chain', 900, 'in_custody');

-- 500 at 3% a month for three months is 45.
SELECT ok(pawn_accrued_interest('15000000-0000-0000-0000-000000000001') = 45.00,
  'three months at three percent on five hundred is forty-five');

-- A pawn charges for the month it was written in, even redeemed the same
-- week. That is the trade practice the module already followed.
INSERT INTO pawn_tickets (id, ticket_number, customer_name, pawn_date, principal, interest_rate, status)
VALUES ('15000000-0000-0000-0000-000000000002', 'PW-002', 'Vuthy', CURRENT_DATE, 200, 5, 'active');
SELECT ok(pawn_accrued_interest('15000000-0000-0000-0000-000000000002') = 10.00,
  'a ticket redeemed the same day still carries one month');

-- Interest already settled comes off what is still owed.
INSERT INTO pawn_transactions (ticket_id, date, type, amount, principal_portion, interest_portion)
VALUES ('15000000-0000-0000-0000-000000000001', CURRENT_DATE, 'interest', 15, 0, 15);
SELECT ok(pawn_accrued_interest('15000000-0000-0000-0000-000000000001') = 30.00,
  'an interest payment already made reduces what is still owed');

SELECT ok((SELECT out_total FROM redeem_pawn_ticket('15000000-0000-0000-0000-000000000001')) = 530.00,
  'redeeming costs the principal plus the interest still outstanding');
SELECT ok((SELECT status FROM pawn_tickets WHERE id = '15000000-0000-0000-0000-000000000001') = 'redeemed',
  'the ticket is redeemed');
SELECT ok((SELECT status FROM pawn_items WHERE ticket_id = '15000000-0000-0000-0000-000000000001') = 'returned',
  'and the customer has their gold back');
SELECT ok(pawn_accrued_interest('15000000-0000-0000-0000-000000000001') = 0,
  'a redeemed ticket accrues nothing further');
SELECT raises($$SELECT * FROM redeem_pawn_ticket('15000000-0000-0000-0000-000000000001')$$,
  'and it cannot be redeemed twice');

SELECT raises($$SELECT pawn_accrued_interest('15000000-0000-0000-0000-0000000000ff')$$,
  'interest cannot be quoted on a ticket that does not exist');

\echo '== 7. drift is visible'

SELECT ok((SELECT count(*) FROM loan_reconciliation()) = 0,
  'nothing recorded through the repayment path drifts');

-- Reproduce what the old parallel-update path could leave behind: money
-- taken from a borrower that the schedule was never credited with.
INSERT INTO loans (id, borrower_id, principal, interest_rate, term_months, method, status, disbursed_date)
VALUES ('14000000-0000-0000-0000-000000000002', '13000000-0000-0000-0000-000000000001',
        600, 12, 6, 'flat', 'pending', NULL);
SELECT disburse_loan('14000000-0000-0000-0000-000000000002', CURRENT_DATE);
INSERT INTO loan_repayments (loan_id, amount, method)
VALUES ('14000000-0000-0000-0000-000000000002', 106, 'cash');

SELECT ok(EXISTS (SELECT 1 FROM loan_reconciliation()
                   WHERE out_loan_id = '14000000-0000-0000-0000-000000000002'),
  'a payment the schedule was never credited with is named');
SELECT ok((SELECT out_difference FROM loan_reconciliation()
            WHERE out_loan_id = '14000000-0000-0000-0000-000000000002') = 106,
  'and the report says by how much');

\echo '== 8. the guards are on the table, not only in the function'

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'loan_schedule' AND cmd IN ('INSERT','UPDATE','DELETE','ALL')),
  'no client policy grants any write on a loan schedule');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'loan_repayments' AND cmd IN ('UPDATE','DELETE','ALL')),
  'and none grants an edit or delete on a repayment');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_loans_number'),
  'two loans cannot carry the same number');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_loan_schedule_installment'),
  'and one loan cannot have two of the same instalment');

\echo ''
\echo 'ALL LENDING INTEGRITY ASSERTIONS PASSED'
