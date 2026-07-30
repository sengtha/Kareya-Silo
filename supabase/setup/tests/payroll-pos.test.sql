-- =====================================================================
-- PAYSLIP AND RECEIPT INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- Both tables hold something already handed to a person: a payslip to an
-- employee, a receipt to a customer. Every assertion here is about the
-- system letting somebody change one afterwards, or letting two of them
-- carry the same number.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/payroll-pos.test.sql
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
  ('c0000000-0000-0000-0000-000000000001', 'acct@firm.kh'),
  ('c0000000-0000-0000-0000-000000000002', 'owner@firm.kh'),
  ('c0000000-0000-0000-0000-000000000003', 'cashier@firm.kh'),
  ('c0000000-0000-0000-0000-000000000004', 'staff@firm.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('d1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'Mony (accountant)', 'acct@firm.kh',    ARRAY['Accountant']),
  ('d1000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', 'Sokha (owner)',     'owner@firm.kh',   ARRAY['Admin']),
  ('d1000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000003', 'Dara (cashier)',    'cashier@firm.kh', ARRAY['Reception']),
  ('d1000000-0000-0000-0000-000000000004', 'c0000000-0000-0000-0000-000000000004', 'Nary (staff)',      'staff@firm.kh',   ARRAY['Staff'])
ON CONFLICT DO NOTHING;

SELECT seed_chart_of_accounts();
SELECT act_as('acct@firm.kh');

\echo '== 1. a payslip is a draft until somebody pays it'

INSERT INTO payslips (id, employee_id, period, pay_date, base_salary, gross, tax, net, status)
VALUES ('e1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000004',
        to_char(CURRENT_DATE, 'YYYY-MM'), CURRENT_DATE, 400, 400, 10, 390, 'draft');

UPDATE payslips SET gross = 420, net = 410 WHERE id = 'e1000000-0000-0000-0000-000000000001';
SELECT ok((SELECT gross FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001') = 420,
  'a draft payslip can still be corrected');

SELECT ok((SELECT status FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001') = 'draft',
  'and it is still a draft');

\echo '== 2. paid is terminal'

SELECT act_as('staff@firm.kh');
SELECT raises($$SELECT mark_payslip_paid('e1000000-0000-0000-0000-000000000001')$$,
  'somebody who is not an accountant cannot mark a payslip paid');

SELECT act_as('acct@firm.kh');
SELECT ok((mark_payslip_paid('e1000000-0000-0000-0000-000000000001')).status = 'paid',
  'the accountant marks it paid');
SELECT ok((SELECT paid_by FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001')
          = 'd1000000-0000-0000-0000-000000000001',
  'and the record says who did it — nothing did before');
SELECT ok((SELECT paid_at FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001') IS NOT NULL,
  'and when');

-- The hole this closes: RLS granted Accountant FOR ALL, so the figures
-- could be changed after the employee was paid and the month filed.
SELECT raises($$UPDATE payslips SET gross = 9999 WHERE id = 'e1000000-0000-0000-0000-000000000001'$$,
  'a paid payslip cannot have its gross changed');
SELECT raises($$UPDATE payslips SET net = 1 WHERE id = 'e1000000-0000-0000-0000-000000000001'$$,
  'nor its net');
SELECT raises($$UPDATE payslips SET period = '1999-01' WHERE id = 'e1000000-0000-0000-0000-000000000001'$$,
  'nor the month it belongs to');
SELECT raises($$DELETE FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001'$$,
  'and it cannot be deleted');
SELECT raises($$SELECT mark_payslip_paid('e1000000-0000-0000-0000-000000000001')$$,
  'it cannot be paid twice');

-- Notes are commentary, not the figures somebody was paid.
UPDATE payslips SET notes = 'Paid by transfer' WHERE id = 'e1000000-0000-0000-0000-000000000001';
SELECT ok((SELECT notes FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001') = 'Paid by transfer',
  'a note can still be added to a paid payslip');

\echo '== 3. one payslip per person per month'

SELECT raises($$
  INSERT INTO payslips (employee_id, period, gross, net, status)
  VALUES ('d1000000-0000-0000-0000-000000000004', to_char(CURRENT_DATE, 'YYYY-MM'), 400, 390, 'draft')$$,
  'a second payslip for the same person and month is refused');

INSERT INTO payslips (id, employee_id, period, gross, net, status)
VALUES ('e1000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000004',
        to_char(CURRENT_DATE - interval '1 month', 'YYYY-MM'), 400, 390, 'draft');
SELECT ok((SELECT count(*) FROM payslips WHERE employee_id = 'd1000000-0000-0000-0000-000000000004') = 2,
  'a different month is fine');

\echo '== 4. nobody pays themselves'

INSERT INTO payslips (id, employee_id, period, gross, net, status)
VALUES ('e1000000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000001',
        to_char(CURRENT_DATE, 'YYYY-MM'), 900, 880, 'draft');

SELECT raises($$SELECT mark_payslip_paid('e1000000-0000-0000-0000-000000000003')$$,
  'the accountant cannot mark their own payslip paid');

SELECT act_as('owner@firm.kh');
SELECT ok((mark_payslip_paid('e1000000-0000-0000-0000-000000000003')).status = 'paid',
  'the owner can, which is what makes it visible rather than impossible');
SELECT act_as('acct@firm.kh');

\echo '== 5. a payslip that was wrong is voided, not rewritten'

SELECT raises($$SELECT void_payslip('e1000000-0000-0000-0000-000000000001', 'wrong')$$,
  'an accountant alone cannot void a payslip');

SELECT act_as('owner@firm.kh');
SELECT raises($$SELECT void_payslip('e1000000-0000-0000-0000-000000000001', '  ')$$,
  'voiding without a reason is refused');

-- Put the payroll entry in the books, as marking it paid would.
SELECT act_as('acct@firm.kh');
SELECT post_journal(CURRENT_DATE, 'Payslip', NULL, 'payroll', 'e1000000-0000-0000-0000-000000000001',
  jsonb_build_array(
    jsonb_build_object('account_id', (SELECT id FROM chart_of_accounts WHERE code = '5100'), 'debit', 420, 'credit', 0),
    jsonb_build_object('account_id', (SELECT id FROM chart_of_accounts WHERE code = '1010'), 'debit', 0, 'credit', 420)));

SELECT act_as('owner@firm.kh');
SELECT raises($$SELECT void_payslip('e1000000-0000-0000-0000-000000000001', 'Wrong salary applied')$$,
  'a payslip whose payroll entry is still in the books cannot be voided');

SELECT act_as('acct@firm.kh');
SELECT reverse_journal(
  (SELECT id FROM journal_entries WHERE source_type = 'payroll'
     AND source_id = 'e1000000-0000-0000-0000-000000000001' AND reverses_entry_id IS NULL),
  CURRENT_DATE, 'Payslip withdrawn');

SELECT act_as('owner@firm.kh');
SELECT ok((void_payslip('e1000000-0000-0000-0000-000000000001', 'Wrong salary applied')).status = 'void',
  'once the entry is reversed the payslip can be voided, with a reason');
SELECT ok((SELECT void_reason FROM payslips WHERE id = 'e1000000-0000-0000-0000-000000000001')
          = 'Wrong salary applied',
  'and the reason is on the record');

-- A void payslip frees the month, so a corrected one can be issued.
SELECT act_as('acct@firm.kh');
INSERT INTO payslips (id, employee_id, period, gross, net, status)
VALUES ('e1000000-0000-0000-0000-000000000004', 'd1000000-0000-0000-0000-000000000004',
        to_char(CURRENT_DATE, 'YYYY-MM'), 400, 390, 'draft');
SELECT ok((SELECT count(*) FROM payslips
            WHERE employee_id = 'd1000000-0000-0000-0000-000000000004'
              AND period = to_char(CURRENT_DATE, 'YYYY-MM') AND status <> 'void') = 1,
  'a corrected payslip can be issued for the month once the wrong one is void');

\echo '== 6. till receipts are numbered by the database'

INSERT INTO pos_sales (id, sale_number, cashier_id, subtotal, total)
VALUES ('f1000000-0000-0000-0000-000000000001', 'WHATEVER-THE-BROWSER-SAID',
        'd1000000-0000-0000-0000-000000000003', 10, 10);

SELECT ok((SELECT sale_number FROM pos_sales WHERE id = 'f1000000-0000-0000-0000-000000000001')
          <> 'WHATEVER-THE-BROWSER-SAID',
  'the number a browser sent is ignored');
SELECT ok((SELECT sale_number FROM pos_sales WHERE id = 'f1000000-0000-0000-0000-000000000001')
          = 'POS-' || to_char(CURRENT_DATE, 'YYYY') || '-000001',
  'and the database issues the first one');

INSERT INTO pos_sales (id, sale_number, subtotal, total)
VALUES ('f1000000-0000-0000-0000-000000000002', 'POS-000001', 20, 20);
SELECT ok((SELECT sale_number FROM pos_sales WHERE id = 'f1000000-0000-0000-0000-000000000002')
          = 'POS-' || to_char(CURRENT_DATE, 'YYYY') || '-000002',
  'the next sale takes the next number, whatever the browser thought');

-- The old scheme was `POS-` plus six digits of a millisecond clock with no
-- unique index at all. A duplicate cannot even be attempted now — the
-- trigger replaces whatever was sent — so the guarantee is tested by what
-- it produces rather than by trying to break it.
INSERT INTO pos_sales (subtotal, total)
SELECT 5, 5 FROM generate_series(1, 50);
SELECT ok((SELECT count(DISTINCT sale_number) FROM pos_sales) = (SELECT count(*) FROM pos_sales),
  'fifty rapid sales carry fifty different numbers');
SELECT ok((SELECT count(*) FROM pos_sales) = 52,
  'and none of them was lost');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uq_pos_sales_number'),
  'with a unique index behind it, which there was not before');
SELECT ok((SELECT last_no FROM pos_receipt_series WHERE id) = 52,
  'the counter records exactly what was issued');

\echo '== 7. a receipt is what the customer is holding'

SELECT raises($$UPDATE pos_sales SET total = 1 WHERE id = 'f1000000-0000-0000-0000-000000000001'$$,
  'a receipt total cannot be edited after the fact');
SELECT raises($$UPDATE pos_sales SET items = '[{"x":1}]'::jsonb WHERE id = 'f1000000-0000-0000-0000-000000000001'$$,
  'nor what was on it');
SELECT raises($$DELETE FROM pos_sales WHERE id = 'f1000000-0000-0000-0000-000000000001'$$,
  'and it cannot be deleted');

SELECT act_as('cashier@firm.kh');
SELECT raises($$SELECT void_pos_sale('f1000000-0000-0000-0000-000000000001', 'mistake')$$,
  'a cashier cannot void their own till');

SELECT act_as('owner@firm.kh');
SELECT raises($$SELECT void_pos_sale('f1000000-0000-0000-0000-000000000001', '')$$,
  'voiding a receipt without a reason is refused');
SELECT ok((void_pos_sale('f1000000-0000-0000-0000-000000000001', 'Rung up twice')).voided,
  'a manager voids it, with a reason');
SELECT ok((SELECT sale_number FROM pos_sales WHERE id = 'f1000000-0000-0000-0000-000000000001') IS NOT NULL,
  'and the number stays in the series');
SELECT raises($$SELECT void_pos_sale('f1000000-0000-0000-0000-000000000001', 'again')$$,
  'it cannot be voided twice');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'pos_sales' AND cmd IN ('DELETE','ALL')),
  'no client policy grants a delete on the till');

\echo '== 8. the period rule applies only once the accounting vertical is there'

SELECT act_as('acct@firm.kh');
SELECT ok(period_closed_if_known(CURRENT_DATE) = false,
  'an open month does not block a payment');

SELECT close_accounting_period(to_char(CURRENT_DATE - interval '2 months', 'YYYY-MM'), 'test');
INSERT INTO payslips (id, employee_id, period, pay_date, gross, net, status)
VALUES ('e1000000-0000-0000-0000-000000000005', 'd1000000-0000-0000-0000-000000000003',
        to_char(CURRENT_DATE - interval '2 months', 'YYYY-MM'),
        (CURRENT_DATE - interval '2 months')::date, 300, 300, 'draft');

SELECT raises($$SELECT mark_payslip_paid('e1000000-0000-0000-0000-000000000005')$$,
  'a payslip cannot be paid into a month whose books are closed');

\echo ''
\echo 'ALL PAYSLIP AND RECEIPT ASSERTIONS PASSED'
