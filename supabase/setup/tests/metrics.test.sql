-- =====================================================================
-- BUSINESS METRICS — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The dashboard used to carry hard-coded tiles with no target, no
-- history and nothing anybody could add to. The assertions below are
-- about the four things that go wrong once a business starts believing
-- the numbers on a screen.
--
-- ZERO IS NOT "I DON'T KNOW". A gross margin of 0% because nobody
-- marked any cost-of-sales accounts looks exactly like a business with
-- no margin. So every metric can come back NOT COMPUTED with a reason,
-- and the tests check the reason as well as the absence.
--
-- A FLOW THAT IGNORES ITS PERIOD IS A LIE THAT LOOKS RIGHT. "Revenue
-- this month" that quietly sums four years is the single easiest way to
-- ship a confident wrong number, so the schema refuses to store one.
--
-- HISTORY MUST SURVIVE SOMEBODY EDITING A FORMULA. Renaming a metric or
-- rewriting how it is worked out must not change what last quarter
-- reported.
--
-- AND A STORED SELECT IS EXECUTABLE. The guard is checked here for what
-- it actually claims to stop.
--
-- Every figure below is invented so the arithmetic can be checked on
-- paper. None of it is a target, a benchmark or a suggestion.
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
  ('e1100000-0000-0000-0000-000000000001', 'boss@trade.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles, status) VALUES
  ('e1200000-0000-0000-0000-000000000001', 'e1100000-0000-0000-0000-000000000001',
   'Sokha (manager)', 'boss@trade.kh', ARRAY['Manager','Accountant'], 'active'),
  ('e1200000-0000-0000-0000-000000000002', NULL,
   'Dara (storeman)', 'dara@trade.kh', ARRAY['Staff'], 'active'),
  ('e1200000-0000-0000-0000-000000000003', NULL,
   'Chantha (left)', 'chantha@trade.kh', ARRAY['Staff'], 'inactive')
ON CONFLICT DO NOTHING;

SELECT act_as('boss@trade.kh');

-- A small chart of accounts, and two months of trading invented so every
-- total below can be checked by hand.
INSERT INTO chart_of_accounts (id, code, name, type, subtype) VALUES
  ('e1300000-0000-0000-0000-000000000001', '1000', 'Cash',        'asset',     'cash'),
  ('e1300000-0000-0000-0000-000000000002', '1100', 'Receivable',  'asset',     'receivable'),
  ('e1300000-0000-0000-0000-000000000003', '2100', 'Payable',     'liability', 'payable'),
  ('e1300000-0000-0000-0000-000000000004', '4000', 'Sales',       'income',    NULL),
  ('e1300000-0000-0000-0000-000000000005', '5000', 'Cost of sales','expense',  'cogs'),
  ('e1300000-0000-0000-0000-000000000006', '6000', 'Rent',        'expense',   NULL)
ON CONFLICT DO NOTHING;

-- JUNE: sales 1,000 · cost of sales 600 · rent 100
--       so revenue 1,000, expenses 700, net profit 300, margin 40%
INSERT INTO journal_entries (id, date, memo) VALUES
  ('e1400000-0000-0000-0000-000000000001', '2026-06-10', 'June sale'),
  ('e1400000-0000-0000-0000-000000000002', '2026-06-12', 'June costs')
ON CONFLICT DO NOTHING;
INSERT INTO journal_lines (entry_id, account_id, debit, credit) VALUES
  ('e1400000-0000-0000-0000-000000000001', 'e1300000-0000-0000-0000-000000000002', 1000, 0),
  ('e1400000-0000-0000-0000-000000000001', 'e1300000-0000-0000-0000-000000000004', 0, 1000),
  ('e1400000-0000-0000-0000-000000000002', 'e1300000-0000-0000-0000-000000000005', 600, 0),
  ('e1400000-0000-0000-0000-000000000002', 'e1300000-0000-0000-0000-000000000006', 100, 0),
  ('e1400000-0000-0000-0000-000000000002', 'e1300000-0000-0000-0000-000000000003', 0, 700);

-- JULY: sales 500, settled in cash. Revenue 500, no expenses.
INSERT INTO journal_entries (id, date, memo) VALUES
  ('e1400000-0000-0000-0000-000000000003', '2026-07-05', 'July sale')
ON CONFLICT DO NOTHING;
INSERT INTO journal_lines (entry_id, account_id, debit, credit) VALUES
  ('e1400000-0000-0000-0000-000000000003', 'e1300000-0000-0000-0000-000000000001', 500, 0),
  ('e1400000-0000-0000-0000-000000000003', 'e1300000-0000-0000-0000-000000000004', 0, 500);

\set JUN_F '''2026-06-01'''
\set JUN_T '''2026-06-30'''
\set JUL_F '''2026-07-01'''
\set JUL_T '''2026-07-31'''

\echo ''
\echo '== 1. nothing is aimed at by default'

SELECT ok((SELECT count(*) FROM metric_targets) = 0,
  'Kareya ships no targets at all');
SELECT ok((SELECT count(*) FROM metric_definitions WHERE is_system) >= 16,
  'but it does ship the definitions, because those describe your own books');
SELECT ok((SELECT count(*) FROM metric_snapshots) = 0,
  'and nothing has been recorded yet');

\echo ''
\echo '== 2. a flow is measured over its period'

SELECT ok((SELECT out_value FROM compute_metric('revenue', :JUN_F, :JUN_T)) = 1000,
  'June revenue is the 1,000 credited to sales in June');
SELECT ok((SELECT out_value FROM compute_metric('revenue', :JUL_F, :JUL_T)) = 500,
  'July revenue is 500, and June is not in it');
SELECT ok((SELECT out_value FROM compute_metric('expenses', :JUN_F, :JUN_T)) = 700,
  'June expenses are 600 of cost of sales plus 100 rent');
SELECT ok((SELECT out_value FROM compute_metric('net_profit', :JUN_F, :JUN_T)) = 300,
  'so June net profit is 300');
SELECT ok((SELECT out_value FROM compute_metric('gross_margin_pct', :JUN_F, :JUN_T)) = 40.0,
  'and the margin is 40% — revenue less cost of sales, over revenue');
SELECT ok((SELECT out_value FROM compute_metric('expenses', :JUL_F, :JUL_T)) = 0,
  'July had no expenses, and nothing is zero that should not be');

\echo ''
\echo '== 3. a balance is read as at a date, not summed over a period'

-- Cash: nothing until July, then 500. Receivable: 1,000 from June, still there.
SELECT ok((SELECT out_value FROM compute_metric('cash_balance', :JUN_F, :JUN_T)) = 0,
  'there was no cash at the end of June');
SELECT ok((SELECT out_value FROM compute_metric('cash_balance', :JUL_F, :JUL_T)) = 500,
  'and 500 at the end of July');
SELECT ok((SELECT out_value FROM compute_metric('receivables', :JUL_F, :JUL_T)) = 1000,
  'the June receivable is still owed at the end of July — a balance carries forward');
SELECT ok((SELECT out_value FROM compute_metric('payables', :JUL_F, :JUL_T)) = 700,
  'and 700 is still owed to suppliers');

\echo ''
\echo '== 4. what cannot be worked out says so, and never says zero'

SELECT ok((SELECT out_computed FROM compute_metric('revenue', '2020-01-01', '2020-01-31')) = true,
  'a period with no trading is a real zero, and reports as computed');
SELECT ok((SELECT out_value FROM compute_metric('revenue', '2020-01-01', '2020-01-31')) = 0,
  'because no sales genuinely is no revenue');

-- DSO divides by revenue. A month with none has no answer at all.
SELECT ok((SELECT out_computed FROM compute_metric('dso', '2020-01-01', '2020-01-31')) = false,
  'but days-to-collect in a month with no revenue is NOT zero — there is no answer');
SELECT ok((SELECT out_problem FROM compute_metric('dso', '2020-01-01', '2020-01-31'))
            = 'Nothing in this period to work it out from.',
  'and it says why rather than leaving a blank');
SELECT ok((SELECT out_value FROM compute_metric('dso', '2020-01-01', '2020-01-31')) IS NULL,
  'the value is absent, not a confident nought');

-- 1,000 owed against 500 earned across 31 days of July = 62.0 days.
SELECT ok((SELECT out_value FROM compute_metric('dso', :JUL_F, :JUL_T)) = 62.0,
  'with revenue it is worked out: 1,000 owed on 500 earned over 31 days is 62 days');

-- Take the cost-of-sales marking away and the margin stops being knowable.
UPDATE chart_of_accounts SET subtype = NULL WHERE code = '5000';
SELECT ok((SELECT out_computed FROM compute_metric('gross_margin_pct', :JUN_F, :JUN_T)) = false,
  'with no cost-of-sales accounts the margin is unknown, not a flattering 100%');
UPDATE chart_of_accounts SET subtype = 'cogs' WHERE code = '5000';

SELECT ok((SELECT out_computed FROM compute_metric('no_such_metric', :JUN_F, :JUN_T)) = false,
  'asking for a metric that does not exist is answered, not crashed');

-- A definition pointing at something that is not there.
INSERT INTO metric_definitions (code, name, category, unit, basis, sql_body)
VALUES ('broken', 'Points at nothing', 'money', 'amount', 'flow',
        'select count(*) from a_table_that_was_never_installed where d between {from} and {to}');
SELECT ok((SELECT out_computed FROM compute_metric('broken', :JUN_F, :JUN_T)) = false,
  'a metric reading a module this business does not run is reported, not fatal');
SELECT ok((SELECT out_problem FROM compute_metric('broken', :JUN_F, :JUN_T)) ILIKE '%does not exist%',
  'and the database says exactly what was missing');
SELECT ok((SELECT count(*) FROM metric_board(:JUN_F, :JUN_T)) >= 17,
  'and the rest of the board still comes back — one broken metric does not take the page down');

SELECT ok((SELECT out_computed FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = true,
  'revenue is still there beside it');

\echo ''
\echo '== 5. a metric that ignores its own period is refused'

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('alltime', 'All-time revenue wearing this month''s hat', 'flow',
          'select coalesce(sum(credit),0) from journal_lines')$$,
  'a flow metric that never mentions {from} is refused — it would report every year as this month');

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('nodate', 'A balance with no date', 'balance', 'select count(*) from employees')$$,
  'and a balance that never mentions {to} is refused');

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('pretend', 'Stock, pretending to have history', 'current',
          'select count(*) from stock_items where created_at::date <= {to}')$$,
  'a current metric cannot claim to honour a period it has no history for');

\echo ''
\echo '== 6. a stored SELECT is executable, and the guard says what it stops'

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('evil1', 'Not a query', 'flow', 'delete from invoices where date > {from}')$$,
  'a body that is not a SELECT is refused');

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('evil2', 'Two statements', 'flow',
          'select 1 where {from} is not null; drop table invoices')$$,
  'a second statement smuggled in behind a semicolon is refused');

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('evil3', 'A writable CTE', 'flow',
          'with gone as (delete from invoices returning 1) select count(*) from gone where {from} is not null')$$,
  'and a data-modifying CTE, which IS a single SELECT statement, is refused too');

SELECT raises($$INSERT INTO metric_definitions (code, name, basis, sql_body)
  VALUES ('evil4', 'Reaching outside', 'flow',
          'select length(pg_read_file(''/etc/passwd'')) where {from} is not null')$$,
  'reading a file off the machine is refused');

-- A trailing semicolon is a typo, not an attack.
INSERT INTO metric_definitions (code, name, basis, sql_body)
VALUES ('trailing', 'Typed with a semicolon', 'flow',
        'select count(*) from employees where created_at::date >= {from};');
SELECT ok((SELECT sql_body FROM metric_definitions WHERE code = 'trailing') NOT LIKE '%;%',
  'but a trailing semicolon is trimmed rather than refused — it is a typo, not a second statement');
DELETE FROM metric_definitions WHERE code = 'trailing';

\echo ''
\echo '== 7. a target, and whether it was met'

INSERT INTO metric_targets (metric_code, period_start, period_end, target_value, note)
VALUES ('revenue', '2026-06-01', '2026-06-30', 800, 'Invented for this test');

SELECT ok((SELECT out_target FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = 800,
  'the target shows against the month it was set for');
SELECT ok((SELECT out_on_track FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = true,
  '1,000 against 800 is ahead');
SELECT ok((SELECT out_variance FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = 200,
  'by 200');
SELECT ok((SELECT out_variance_pct FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = 25.0,
  'which is 25% ahead');
SELECT ok((SELECT out_target FROM metric_board(:JUL_F, :JUL_T) WHERE out_code = 'revenue') IS NULL,
  'and a June target does not quietly apply to July');

-- Lower is better for money owed: the comparison has to flip.
INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
VALUES ('receivables', '2026-06-01', '2026-06-30', 1500);
SELECT ok((SELECT out_on_track FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'receivables') = true,
  'owing 1,000 against a 1,500 ceiling is on track, because less is better here');

INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
VALUES ('dso', '2026-06-01', '2026-06-30', 20);
SELECT ok((SELECT out_on_track FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'dso') = false,
  'and 30 days to collect against a 20-day target is not');

-- A missing number must never be read as a pass.
SELECT ok((SELECT out_on_track FROM metric_board('2020-01-01', '2020-01-31') WHERE out_code = 'dso') IS NULL,
  'a month with no answer is neither on track nor off it — a red month must not read as green');

SELECT raises($$INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
  VALUES ('revenue', '2026-06-01', '2026-06-30', 900)$$,
  'one target per metric per period — two answers to one question is not a plan');

SELECT raises($$INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
  VALUES ('revenue', '2026-06-30', '2026-06-01', 900)$$,
  'and a period that ends before it begins is refused');

\echo ''
\echo '== 8. closing a period'

-- The broken metric is left in place on purpose: closing a period must
-- not depend on every metric working.
SELECT ok((SELECT out_taken FROM snapshot_metrics(:JUN_F, :JUN_T)) >= 10,
  'closing June records what the books said');
SELECT ok((SELECT out_failed FROM snapshot_metrics(:JUN_F, :JUN_T)) >= 1,
  'counts the ones it could not work out separately');
SELECT ok((SELECT out_skipped FROM snapshot_metrics(:JUN_F, :JUN_T)) = 3,
  'and skips the three that have no history behind them, rather than filing today under June');

SELECT ok((SELECT value FROM metric_snapshots
            WHERE metric_code = 'revenue' AND period_start = '2026-06-01') = 1000,
  'June revenue is on the record');
SELECT ok((SELECT target_value FROM metric_snapshots
            WHERE metric_code = 'revenue' AND period_start = '2026-06-01') = 800,
  'with the target it was judged against');
SELECT ok(NOT EXISTS (SELECT 1 FROM metric_snapshots WHERE metric_code = 'stock_value'),
  'stock on hand was NOT recorded into June — it has no June figure to record');
SELECT ok((SELECT computed FROM metric_snapshots WHERE metric_code = 'broken') = false,
  'the broken metric is recorded as unanswered rather than left out silently');
SELECT ok((SELECT problem FROM metric_snapshots WHERE metric_code = 'broken') IS NOT NULL,
  'and keeps the reason');

\echo ''
\echo '== 9. history survives somebody editing the formula'

UPDATE metric_definitions
   SET name = 'Turnover', sql_body = 'select 0 where {from} is not null'
 WHERE code = 'revenue';

SELECT ok((SELECT value FROM metric_snapshots
            WHERE metric_code = 'revenue' AND period_start = '2026-06-01') = 1000,
  'rewriting how revenue is worked out does not rewrite what June reported');
SELECT ok((SELECT name FROM metric_snapshots
            WHERE metric_code = 'revenue' AND period_start = '2026-06-01') = 'Revenue',
  'and the snapshot still carries the name it had at the time');
SELECT ok((SELECT out_value FROM compute_metric('revenue', :JUN_F, :JUN_T)) = 0,
  'while the live board follows the new formula, which is the point of having both');

-- Put it back.
UPDATE metric_definitions
   SET name = 'Revenue',
       sql_body = 'select coalesce(sum(l.credit - l.debit), 0) from journal_lines l join journal_entries e on e.id = l.entry_id join chart_of_accounts a on a.id = l.account_id where a.type = ''income'' and e.date between {from} and {to}'
 WHERE code = 'revenue';
SELECT ok((SELECT out_value FROM compute_metric('revenue', :JUN_F, :JUN_T)) = 1000,
  'and putting the formula back gives the old answer again');

SELECT raises($$DELETE FROM metric_definitions WHERE code = 'revenue'$$,
  'a shipped metric cannot be deleted — a snapshot from last year names it');

UPDATE metric_definitions SET is_active = false WHERE code = 'revenue';
SELECT ok(NOT EXISTS (SELECT 1 FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue'),
  'but it can be switched off, and then it leaves the board');
SELECT ok((SELECT value FROM metric_snapshots
            WHERE metric_code = 'revenue' AND period_start = '2026-06-01') = 1000,
  'without taking June with it');
SELECT ok((SELECT out_computed FROM compute_metric('revenue', :JUN_F, :JUN_T)) = false,
  'and asking for it directly says it is switched off');
UPDATE metric_definitions SET is_active = true WHERE code = 'revenue';

\echo ''
\echo '== 10. the trend'

SELECT snapshot_metrics(:JUL_F, :JUL_T);

SELECT ok((SELECT count(*) FROM metric_trend('revenue', 12)) = 2,
  'two months closed gives two points on the trend');
SELECT ok((SELECT out_value FROM metric_trend('revenue', 12) LIMIT 1) = 500,
  'newest first — July');
SELECT ok((SELECT out_on_track FROM metric_trend('revenue', 12) LIMIT 1) IS NULL,
  'and July has no verdict, because nobody set July a target');
SELECT ok((SELECT count(*) FROM metric_trend('stock_value', 12)) = 0,
  'a current metric has no trend at all, which is honest rather than empty-looking');

\echo ''
\echo '== 11. things with no history are still worth seeing'

SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'headcount') = 2,
  'two staff are active — the one who left is not counted');
SELECT ok((SELECT out_basis FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'headcount') = 'current',
  'and it is labelled current, so nobody reads it as a June figure');

-- Stock arrives through movements, not by typing a quantity onto the
-- item — the inventory vertical guards that, and this metric has to read
-- what that guard actually produces.
INSERT INTO stock_items (id, name, cost_price, reorder_level) VALUES
  ('e1600000-0000-0000-0000-000000000001', 'Cement 50kg', 5, 20),
  ('e1600000-0000-0000-0000-000000000002', 'Sand m3', 10, 10),
  ('e1600000-0000-0000-0000-000000000003', 'Nails box', 2, 5);
INSERT INTO stock_movements (item_id, type, quantity, unit_cost, date) VALUES
  ('e1600000-0000-0000-0000-000000000001', 'in', 100, 5, '2026-06-02'),
  ('e1600000-0000-0000-0000-000000000002', 'in', 3, 10, '2026-06-02');
SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'stock_value') = 530,
  'stock at cost is 100x5 plus 3x10 plus nothing');
SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'low_stock_items') = 2,
  'two lines are at or under their reorder level');

\echo ''
\echo '== 12. selling'

INSERT INTO clients (id, name, created_at) VALUES
  ('e1500000-0000-0000-0000-000000000001', 'Mekong Traders', '2026-06-04'),
  ('e1500000-0000-0000-0000-000000000002', 'Tonle Supplies', '2026-07-20');
SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'new_customers') = 1,
  'one customer was added in June');

INSERT INTO invoices (invoice_number, date, due_date, amount, status) VALUES
  ('INV-1', '2026-06-05', '2026-06-20', 600, 'paid'),
  ('INV-2', '2026-06-15', '2026-06-25', 400, 'pending'),
  ('INV-3', '2026-06-18', '2026-07-30', 200, 'pending');
-- A void has to say why; the GDT vertical enforces that, and the metric
-- has to agree with the real void path rather than a shortcut.
UPDATE invoices SET voided = true, void_reason = 'Raised on the wrong customer'
 WHERE invoice_number = 'INV-3';

SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'invoices_issued') = 2,
  'a voided invoice was never issued, so it is not counted');
SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'average_invoice') = 500,
  'and the average of 600 and 400 is 500, with the voided one left out of that too');
SELECT ok((SELECT out_value FROM compute_metric('overdue_receivables', :JUN_F, :JUN_T)) = 400,
  'only INV-2 was past its due date and unpaid at the end of June');

INSERT INTO quotes (quote_number, date, amount, status) VALUES
  ('Q-1', '2026-06-02', 900, 'accepted'),
  ('Q-2', '2026-06-08', 700, 'declined'),
  ('Q-3', '2026-06-09', 300, 'invoiced'),
  ('Q-4', '2026-06-11', 500, 'draft');
SELECT ok((SELECT out_value FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'quote_win_rate') = 66.7,
  'two of the three quotes actually sent were won — the draft was never lost');

\echo ''
\echo '== 13. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM metric_reconciliation()
                   WHERE out_kind = 'metric' AND out_ref = 'broken'),
  'a metric that could not be worked out is reported');

-- A target on a period that has finished, with nothing recorded.
INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
VALUES ('net_profit', '2026-05-01', '2026-05-31', 400);
SELECT ok(EXISTS (SELECT 1 FROM metric_reconciliation()
                   WHERE out_kind = 'target' AND out_ref = 'net_profit'
                     AND out_issue ILIKE '%no result was recorded%'),
  'a target for a month nobody ever closed is reported — a target nobody looks back at is a wish');

SELECT ok(EXISTS (SELECT 1 FROM metric_reconciliation()
                   WHERE out_ref = 'dso' AND out_issue ILIKE '%Missed its target%'),
  'and a missed target in the latest closed month is named with both figures');

UPDATE metric_definitions SET is_active = false WHERE code = 'receivables';
INSERT INTO metric_targets (metric_code, period_start, period_end, target_value)
VALUES ('receivables', CURRENT_DATE, CURRENT_DATE + 30, 900);
SELECT ok(EXISTS (SELECT 1 FROM metric_reconciliation()
                   WHERE out_ref = 'receivables' AND out_issue ILIKE '%switched off%'),
  'a live target on a metric nobody shows any more is reported');
UPDATE metric_definitions SET is_active = true WHERE code = 'receivables';

SELECT ok(NOT EXISTS (SELECT 1 FROM metric_reconciliation() WHERE out_ref = 'snapshots'),
  'and now that periods have been closed, it stops asking for that');

\echo ''
\echo '== 14. the board itself'

SELECT ok((SELECT count(*) FROM metric_board(:JUN_F, :JUN_T, 'money')) >= 8,
  'the board can be asked for one category at a time');
SELECT ok(NOT EXISTS (SELECT 1 FROM metric_board(:JUN_F, :JUN_T, 'money') WHERE out_category <> 'money'),
  'and gives back only that category');
SELECT ok((SELECT out_source FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = 'Accounting',
  'every metric names the module its number comes from, so "where did this come from?" has an answer');
SELECT ok((SELECT out_name_kh FROM metric_board(:JUN_F, :JUN_T) WHERE out_code = 'revenue') = 'ចំណូល',
  'and carries its Khmer name');

SELECT raises($$SELECT * FROM compute_metric('revenue', '2026-06-30', '2026-06-01')$$,
  'a backwards period is refused rather than quietly returning nothing');

\echo ''
\echo '===================================================================='
\echo ' METRICS: all assertions passed'
\echo '===================================================================='
