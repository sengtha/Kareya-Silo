-- =====================================================================
-- ACCOUNTING INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- Every assertion here guards something an auditor would find rather than
-- a user: an entry that no longer balances, a correction that erased what
-- was originally posted, a journal landing in a month whose return has
-- already been filed, or a sale on screen that is not in the books.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/accounting.test.sql
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

-- A deferred constraint only fires at COMMIT, so a statement that breaks
-- one looks fine until the transaction ends. This wraps the whole thing.
CREATE OR REPLACE FUNCTION raises_at_commit(sql text, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE 'BEGIN';
    EXECUTE sql;
    EXECUTE 'COMMIT';
  EXCEPTION WHEN others THEN
    BEGIN EXECUTE 'ROLLBACK'; EXCEPTION WHEN others THEN NULL; END;
    RAISE NOTICE '  ok   % (refused: %)', label, left(SQLERRM, 70); RETURN;
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
  ('a0000000-0000-0000-0000-000000000001', 'acct@books.kh'),
  ('a0000000-0000-0000-0000-000000000002', 'owner@books.kh'),
  ('a0000000-0000-0000-0000-000000000003', 'sales@books.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'Mony (accountant)', 'acct@books.kh',  ARRAY['Accountant']),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'Sokha (owner)',     'owner@books.kh',  ARRAY['Admin']),
  ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000003', 'Dara (sales)',      'sales@books.kh',  ARRAY['Sales Lead'])
ON CONFLICT DO NOTHING;

SELECT seed_chart_of_accounts();
SELECT act_as('acct@books.kh');

CREATE OR REPLACE FUNCTION acct(p_code text) RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT id FROM chart_of_accounts WHERE code = p_code LIMIT 1;
$$;

\echo '== 1. a journal entry balances, and keeps balancing'

SELECT ok(post_journal(CURRENT_DATE, 'Opening cash', 'OP-1', 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 500, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 500)))
  IS NOT NULL, 'a balanced entry posts');

SELECT raises($$SELECT post_journal(CURRENT_DATE, 'Crooked', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 500, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 400)))$$,
  'an unbalanced entry is refused at the door');

SELECT raises($$SELECT post_journal(CURRENT_DATE, 'Nothing', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 0, 'credit', 0)))$$,
  'an entry with no amounts is refused');

-- The hole this closes. RLS granted Accountant FOR ALL on both tables, so
-- the balance post_journal had just enforced could be edited away and
-- nothing would ever say so.
SELECT raises($$UPDATE journal_lines SET debit = 999 WHERE debit = 500$$,
  'a posted line cannot be edited');
SELECT raises($$DELETE FROM journal_lines WHERE debit = 500$$,
  'a posted line cannot be deleted');
SELECT raises($$DELETE FROM journal_entries WHERE memo = 'Opening cash'$$,
  'a posted entry cannot be deleted');
SELECT raises($$UPDATE journal_entries SET date = CURRENT_DATE - 400 WHERE memo = 'Opening cash'$$,
  'a posted entry cannot be back-dated after the fact');
SELECT raises($$UPDATE journal_entries SET memo = 'Something else' WHERE memo = 'Opening cash'$$,
  'a posted entry cannot be relabelled');

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename IN ('journal_entries','journal_lines')
                         AND cmd IN ('INSERT','UPDATE','DELETE','ALL')),
  'no client policy grants any write on the ledger');

-- Balance is now an invariant, not only a check at the door: even an
-- insert that bypasses post_journal is caught, at COMMIT.
SELECT raises_at_commit($$
  INSERT INTO journal_lines (entry_id, account_id, debit, credit)
  VALUES ((SELECT id FROM journal_entries WHERE memo = 'Opening cash'), acct('1000'), 25, 0)$$,
  'a stray line that unbalances an entry is caught at commit');

\echo '== 2. correcting the books does not erase them'

SELECT raises($$SELECT reverse_journal(
    (SELECT id FROM journal_entries WHERE memo = 'Opening cash'), CURRENT_DATE, '')$$,
  'reversing without a reason is refused');

SELECT act_as('sales@books.kh');
SELECT raises($$SELECT reverse_journal(
    (SELECT id FROM journal_entries WHERE memo = 'Opening cash'), CURRENT_DATE, 'oops')$$,
  'somebody who is not an accountant cannot reverse an entry');
SELECT act_as('acct@books.kh');

SELECT ok(reverse_journal((SELECT id FROM journal_entries WHERE memo = 'Opening cash'),
                          CURRENT_DATE, 'Posted to the wrong account') IS NOT NULL,
  'an accountant reverses it, with a reason');

SELECT ok((SELECT reversed_by_entry_id FROM journal_entries WHERE memo = 'Opening cash') IS NOT NULL,
  'the original is linked to its reversal');
SELECT ok((SELECT count(*) FROM journal_entries WHERE reverses_entry_id IS NOT NULL) = 1,
  'and the reversal knows what it reverses');

-- The two together net to nothing on every account they touched.
SELECT ok((SELECT coalesce(sum(l.debit) - sum(l.credit), 0)
             FROM journal_lines l JOIN journal_entries j ON j.id = l.entry_id
            WHERE j.id IN (SELECT id FROM journal_entries WHERE memo = 'Opening cash')
               OR j.reverses_entry_id IN (SELECT id FROM journal_entries WHERE memo = 'Opening cash')) = 0,
  'the original and its reversal net to nothing');

SELECT raises($$SELECT reverse_journal(
    (SELECT id FROM journal_entries WHERE memo = 'Opening cash'), CURRENT_DATE, 'again')$$,
  'an entry cannot be reversed twice');
SELECT raises($$SELECT reverse_journal(
    (SELECT id FROM journal_entries WHERE reverses_entry_id IS NOT NULL), CURRENT_DATE, 'undo')$$,
  'a reversal cannot itself be reversed');

\echo '== 3. one business document, one entry'

INSERT INTO clients (id, name) VALUES ('c0000000-0000-0000-0000-000000000001', 'Sok Trading')
ON CONFLICT DO NOTHING;
INSERT INTO invoices (id, client_id, invoice_number, date, amount)
VALUES ('11110000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
        'INV-0001', CURRENT_DATE, 300);

SELECT ok(post_journal(CURRENT_DATE, 'Invoice INV-0001', 'INV-0001', 'invoice',
    '11110000-0000-0000-0000-000000000001',
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1100'), 'debit', 300, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 300)))
  IS NOT NULL, 'the invoice goes into the books');

SELECT raises($$SELECT post_journal(CURRENT_DATE, 'Invoice INV-0001 again', 'INV-0001', 'invoice',
    '11110000-0000-0000-0000-000000000001',
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1100'), 'debit', 300, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 300)))$$,
  'clicking Save twice does not put the same invoice in the books twice');

-- A manual entry carries no source, so two of them are simply two entries.
SELECT ok(post_journal(CURRENT_DATE, 'Petty cash A', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 5, 'credit', 0),
      jsonb_build_object('account_id', acct('5400'), 'debit', 0, 'credit', 5)))
  IS NOT NULL, 'two manual entries are not mistaken for a duplicate');

\echo '== 4. what is on screen but not in the books'

INSERT INTO invoices (id, client_id, invoice_number, date, amount)
VALUES ('11110000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001',
        'INV-0002', CURRENT_DATE, 150);

SELECT ok(EXISTS (SELECT 1 FROM unposted_documents()
                   WHERE out_kind = 'invoice' AND out_reference = 'INV-0002'),
  'an invoice nobody posted is named, instead of quietly missing');
SELECT ok(NOT EXISTS (SELECT 1 FROM unposted_documents()
                       WHERE out_reference = 'INV-0001'),
  'an invoice that is in the books is not on the list');

-- A voided invoice was withdrawn, not forgotten.
UPDATE invoices SET voided = true, void_reason = 'Issued in error' WHERE invoice_number = 'INV-0002';
SELECT ok(NOT EXISTS (SELECT 1 FROM unposted_documents() WHERE out_reference = 'INV-0002'),
  'a voided invoice is not reported as missing from the books');
UPDATE invoices SET voided = false, void_reason = NULL WHERE invoice_number = 'INV-0002';

-- A POS sale with no journal is the case that actually happens: the sale
-- saves, the posting fails because nobody seeded a chart of accounts, and
-- until now nothing anywhere mentioned it.
INSERT INTO pos_sales (id, sale_number, items, subtotal, total)
VALUES ('22220000-0000-0000-0000-000000000001', 'POS-000001', '[]'::jsonb, 40, 40);
SELECT ok(EXISTS (SELECT 1 FROM unposted_documents() WHERE out_kind = 'pos_sale'),
  'a till sale that never reached the ledger is named too');

\echo '== 5. closing a period'

SELECT act_as('sales@books.kh');
SELECT raises($$SELECT close_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'))$$,
  'somebody who is not an accountant cannot close a period');
SELECT act_as('acct@books.kh');

SELECT raises($$SELECT close_accounting_period('2026/03')$$,
  'a period written the wrong way is refused');
SELECT raises($$SELECT close_accounting_period(to_char(CURRENT_DATE + interval '2 months', 'YYYY-MM'))$$,
  'a period that has not happened yet cannot be closed');

-- Two documents are still unposted, so the month is not closeable.
SELECT raises($$SELECT close_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'))$$,
  'a month with documents missing from the books cannot be closed');

-- Post them and try again.
SELECT post_journal(CURRENT_DATE, 'Invoice INV-0002', 'INV-0002', 'invoice',
    '11110000-0000-0000-0000-000000000002',
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1100'), 'debit', 150, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 150)));
SELECT post_journal(CURRENT_DATE, 'POS-000001', 'POS-000001', 'invoice',
    '22220000-0000-0000-0000-000000000001',
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 40, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 40)));

SELECT ok((SELECT count(*) FROM unposted_documents()) = 0,
  'nothing is left off the books');
SELECT ok((close_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'), 'Month end')).status = 'closed',
  'and now the month closes');

SELECT ok((SELECT closed_debit FROM accounting_periods WHERE period = to_char(CURRENT_DATE, 'YYYY-MM'))
        = (SELECT closed_credit FROM accounting_periods WHERE period = to_char(CURRENT_DATE, 'YYYY-MM')),
  'the totals as at closing are recorded, and they balance');

SELECT raises($$SELECT close_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'))$$,
  'a closed month cannot be closed again');

\echo '== 6. a closed period stays the period that was filed'

SELECT raises($$SELECT post_journal(CURRENT_DATE, 'Late entry', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 10, 'credit', 0),
      jsonb_build_object('account_id', acct('5400'), 'debit', 0, 'credit', 10)))$$,
  'nothing can be posted into a closed month');

SELECT raises($$SELECT reverse_journal(
    (SELECT id FROM journal_entries WHERE memo = 'Petty cash A'), CURRENT_DATE, 'wrong')$$,
  'and a correction cannot be dated back inside it either');

SELECT ok(period_is_closed(CURRENT_DATE), 'the month reads as closed');
SELECT ok(NOT period_is_closed((CURRENT_DATE + interval '40 days')::date),
  'a month nobody has closed is open — no row needed');

\echo '== 7. reopening is allowed, and never quiet'

SELECT raises($$SELECT reopen_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'), 'because')$$,
  'an accountant alone cannot reopen a closed month');

SELECT act_as('owner@books.kh');
SELECT raises($$SELECT reopen_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'), '  ')$$,
  'reopening without a reason is refused');
SELECT raises($$SELECT reopen_accounting_period(to_char(CURRENT_DATE - interval '1 month', 'YYYY-MM'), 'x')$$,
  'a month that was never closed cannot be reopened');

SELECT ok((reopen_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'),
                                    'Supplier invoice arrived late')).status = 'open',
  'an administrator reopens it, with a reason');
SELECT ok((SELECT reopen_reason FROM accounting_periods WHERE period = to_char(CURRENT_DATE, 'YYYY-MM'))
          = 'Supplier invoice arrived late',
  'the reason is on the record');
SELECT ok((SELECT closed_debit FROM accounting_periods WHERE period = to_char(CURRENT_DATE, 'YYYY-MM')) IS NOT NULL,
  'the totals as at closing survive the reopen, so anybody can tell whether the figures moved');

SELECT act_as('acct@books.kh');
SELECT ok(post_journal(CURRENT_DATE, 'The late supplier bill', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('5400'), 'debit', 20, 'credit', 0),
      jsonb_build_object('account_id', acct('2000'), 'debit', 0, 'credit', 20)))
  IS NOT NULL, 'and posting works again once it is open');

\echo '== 8. periods close oldest first'

SELECT post_journal((CURRENT_DATE - interval '70 days')::date, 'Old entry', NULL, 'manual', NULL,
    jsonb_build_array(
      jsonb_build_object('account_id', acct('1000'), 'debit', 30, 'credit', 0),
      jsonb_build_object('account_id', acct('4000'), 'debit', 0, 'credit', 30)));

SELECT raises($$SELECT close_accounting_period(to_char(CURRENT_DATE, 'YYYY-MM'))$$,
  'a month cannot be closed while an earlier one is still open');

SELECT ok((SELECT count(*) FROM period_status(6)) = 6,
  'the month-end view lists the months asked for');
SELECT ok((SELECT out_status FROM period_status(3) WHERE out_period = to_char(CURRENT_DATE, 'YYYY-MM')) = 'open',
  'and shows this month as open again');
SELECT ok((SELECT out_reopened FROM period_status(3) WHERE out_period = to_char(CURRENT_DATE, 'YYYY-MM')),
  'flagging that it was reopened rather than never closed');

\echo ''
\echo 'ALL ACCOUNTING INTEGRITY ASSERTIONS PASSED'
