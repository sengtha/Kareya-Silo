-- =====================================================================
-- CIRCULATION INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The original vertical already had a partial unique index that stops one
-- physical copy being on two loans at once, and that still holds — the
-- first assertions below confirm it rather than replacing it.
--
-- What these guard is everything around that index: the copy's status
-- drifting away from its loan record, a borrowing limit counted in the
-- browser so two desks could both issue past it, a fine computed from a
-- policy rate held in React state, collecting money without recording
-- who took it, deleting a copy and taking its whole borrowing history
-- with it, and a hold shelf that never cleared.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/library.test.sql
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
  ('e0000000-0000-0000-0000-000000000001', 'sokha@library.kh'),
  ('e0000000-0000-0000-0000-000000000002', 'chantha@library.kh'),
  ('e0000000-0000-0000-0000-000000000003', 'rithy@library.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('f0000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'Sokha (librarian)', 'sokha@library.kh',   ARRAY['Librarian']),
  ('f0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000002', 'Chantha (manager)', 'chantha@library.kh', ARRAY['Manager']),
  ('f0000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000003', 'Rithy (driver)',    'rithy@library.kh',   ARRAY['Driver'])
ON CONFLICT DO NOTHING;

UPDATE library_policy SET loan_days = 14, max_renewals = 2, max_items_per_member = 3,
                          fine_per_day = 0.10, grace_days = 0, hold_shelf_days = 3 WHERE id;

INSERT INTO library_items (id, title, authors, language) VALUES
  ('11110000-0000-0000-0000-000000000001', 'A History of Cambodia', 'David Chandler', 'en'),
  ('11110000-0000-0000-0000-000000000002', 'Khmer Grammar',         'Various',        'km')
ON CONFLICT DO NOTHING;

INSERT INTO library_copies (id, item_id, accession_no, cost) VALUES
  ('22220000-0000-0000-0000-000000000001', '11110000-0000-0000-0000-000000000001', 'ACC-0001', 25),
  ('22220000-0000-0000-0000-000000000002', '11110000-0000-0000-0000-000000000001', 'ACC-0002', 25),
  ('22220000-0000-0000-0000-000000000003', '11110000-0000-0000-0000-000000000002', 'ACC-0003', 12),
  ('22220000-0000-0000-0000-000000000004', '11110000-0000-0000-0000-000000000002', 'ACC-0004', 12),
  ('22220000-0000-0000-0000-000000000005', '11110000-0000-0000-0000-000000000002', 'ACC-0005', 12)
ON CONFLICT DO NOTHING;

INSERT INTO library_members (id, member_no, name, member_type) VALUES
  ('33330000-0000-0000-0000-000000000001', 'M-001', 'Sreymom', 'public'),
  ('33330000-0000-0000-0000-000000000002', 'M-002', 'Pisach',  'public'),
  ('33330000-0000-0000-0000-000000000003', 'M-003', 'Chenda',  'public')
ON CONFLICT DO NOTHING;

SELECT act_as('sokha@library.kh');

\echo ''
\echo '== 1. issuing is one transaction, and the catalogue follows the loan'

SELECT checkout_library_copy('22220000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000001');

SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0001') = 'on_loan',
  'the copy reads as on loan without anybody updating it separately');
SELECT ok((SELECT count(*) FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan') = 1,
  'and there is exactly one open loan for it');
SELECT ok((SELECT due_date FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')
          = CURRENT_DATE + 14,
  'the due date is snapshotted from the policy at issue');
SELECT ok((SELECT issued_by FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')
          = 'f0000000-0000-0000-0000-000000000001',
  'and who issued it is recorded from the session, not passed in by the caller');

SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000002')$$,
  'the same copy cannot be issued to a second member');

\echo ''
\echo '== 2. the catalogue cannot be edited out of step with the loan'

-- This is the drift the three-round-trip version left behind: a copy that
-- is on loan and reads as available, so the shelf list is a lie.
SELECT raises($$UPDATE library_copies SET status = 'available' WHERE accession_no = 'ACC-0001'$$,
  'a copy on loan cannot be marked available by editing it');
SELECT raises($$UPDATE library_copies SET status = 'on_loan' WHERE accession_no = 'ACC-0002'$$,
  'nor can a copy be put on loan by editing it');
SELECT raises($$UPDATE library_copies SET status = 'on_hold_shelf' WHERE accession_no = 'ACC-0002'$$,
  'nor set aside on the hold shelf by editing it');

SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0001') = 'on_loan',
  'and the refused edits changed nothing');

UPDATE library_copies SET status = 'repair' WHERE accession_no = 'ACC-0002';
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0002') = 'repair',
  'sending a copy for repair is still an ordinary edit');
UPDATE library_copies SET status = 'available' WHERE accession_no = 'ACC-0002';

\echo ''
\echo '== 3. the borrowing limit is counted in the database'

-- The copy was protected by an index; the member was not. Two librarians
-- both looking at a member with 2 of 3 out both issued, and the member
-- walked out with 4.
SELECT checkout_library_copy('22220000-0000-0000-0000-000000000003', '33330000-0000-0000-0000-000000000001');
SELECT checkout_library_copy('22220000-0000-0000-0000-000000000004', '33330000-0000-0000-0000-000000000001');

SELECT ok((SELECT count(*) FROM library_loans WHERE member_id = '33330000-0000-0000-0000-000000000001' AND status = 'on_loan') = 3,
  'the member is at the limit of 3');
SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000005', '33330000-0000-0000-0000-000000000001')$$,
  'a fourth is refused, whatever the browser last counted');
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0005') = 'available',
  'and the refused copy is still on the shelf');

-- A member's own allowance overrides the library default.
UPDATE library_members SET max_items = 4 WHERE id = '33330000-0000-0000-0000-000000000001';
SELECT checkout_library_copy('22220000-0000-0000-0000-000000000005', '33330000-0000-0000-0000-000000000001');
SELECT ok((SELECT count(*) FROM library_loans WHERE member_id = '33330000-0000-0000-0000-000000000001' AND status = 'on_loan') = 4,
  'a member with their own allowance of 4 may take a fourth');
UPDATE library_members SET max_items = NULL WHERE id = '33330000-0000-0000-0000-000000000001';

\echo ''
\echo '== 4. a suspended or expired member does not borrow'

UPDATE library_members SET status = 'suspended' WHERE id = '33330000-0000-0000-0000-000000000002';
SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000002')$$,
  'a suspended member is refused');
UPDATE library_members SET status = 'active', expires_date = CURRENT_DATE - 1 WHERE id = '33330000-0000-0000-0000-000000000002';
SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000002')$$,
  'a membership that lapsed yesterday is refused even while the status says active');
UPDATE library_members SET expires_date = NULL WHERE id = '33330000-0000-0000-0000-000000000002';

\echo ''
\echo '== 5. returning: the fine comes from the policy, now, not from the browser'

-- Backdate one loan so it is genuinely 10 days late.
SELECT set_config('kareya.library_loan_apply', 'on', false);  -- session-level: psql commits each statement
UPDATE library_loans SET loaned_at = CURRENT_DATE - 24, due_date = CURRENT_DATE - 10
 WHERE copy_id = '22220000-0000-0000-0000-000000000001';
SELECT set_config('kareya.library_loan_apply', '', false);

SELECT ok(library_days_overdue((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')) = 10,
  'ten days late is ten days late');
SELECT ok(library_fine_for((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')) = 1.00,
  'at 0.10 a day that is 1.00');

-- The rate changes. The browser would have used whatever it last loaded.
UPDATE library_policy SET fine_per_day = 0.25 WHERE id;
SELECT ok(library_fine_for((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')) = 2.50,
  'raising the rate to 0.25 changes what is owed, because the rate is read now');
UPDATE library_policy SET grace_days = 3 WHERE id;
SELECT ok(library_days_overdue((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')) = 7,
  'a three-day grace period comes off the days late');
UPDATE library_policy SET fine_per_day = 0.10, grace_days = 0 WHERE id;

SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001'));

SELECT ok((SELECT fine_amount FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001') = 1.00,
  'the fine is frozen onto the loan at return');
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0001') = 'available',
  'and the copy goes back on the shelf without a second call');
SELECT ok((SELECT returned_by FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001')
          = 'f0000000-0000-0000-0000-000000000001',
  'who took it back is recorded');

SELECT raises($$SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001'))$$,
  'returning the same loan twice is refused');

\echo ''
\echo '== 6. an overdue item blocks the next loan'

SELECT set_config('kareya.library_loan_apply', 'on', false);  -- session-level: psql commits each statement
UPDATE library_loans SET loaned_at = CURRENT_DATE - 19, due_date = CURRENT_DATE - 5
 WHERE copy_id = '22220000-0000-0000-0000-000000000003' AND status = 'on_loan';
SELECT set_config('kareya.library_loan_apply', '', false);

SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000001')$$,
  'a member with something overdue cannot take another book');

SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000003' AND status = 'on_loan'));
SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000004' AND status = 'on_loan'));
SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000005' AND status = 'on_loan'));

\echo ''
\echo '== 7. renewing'

SELECT checkout_library_copy('22220000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000002');
SELECT renew_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan'));

SELECT ok((SELECT due_date FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan')
          = CURRENT_DATE + 28,
  'renewing an in-date loan extends from the due date, not from today');
SELECT ok((SELECT renew_count FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan') = 1,
  'and the renewal is counted');

SELECT renew_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan'));
SELECT raises($$SELECT renew_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan'))$$,
  'a third renewal is refused at a limit of two');

\echo ''
\echo '== 8. a loan is a record, not a form'

SELECT raises($$DELETE FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001'$$,
  'a loan cannot be deleted — it is the record of who had the book');
SELECT raises($$UPDATE library_loans SET due_date = CURRENT_DATE + 365 WHERE status = 'on_loan'$$,
  'a due date cannot be pushed out by editing the row');
SELECT raises($$UPDATE library_loans SET fine_amount = 0 WHERE fine_amount > 0$$,
  'a fine cannot be erased by editing the row');
SELECT raises($$UPDATE library_loans SET status = 'returned' WHERE status = 'on_loan'$$,
  'a loan cannot be closed by editing the row');
SELECT raises($$UPDATE library_loans SET member_id = '33330000-0000-0000-0000-000000000003' WHERE status = 'on_loan'$$,
  'and a book cannot be moved onto somebody else afterwards');

UPDATE library_loans SET notes = 'Cover slightly torn on return' WHERE status = 'on_loan';
SELECT ok((SELECT count(*) FROM library_loans WHERE notes = 'Cover slightly torn on return') >= 1,
  'a note is still the librarian''s to write');

\echo ''
\echo '== 9. deleting a copy does not take its borrowing history with it'

-- library_loans.copy_id was ON DELETE CASCADE. One click erased every
-- record of who had borrowed it.
SELECT ok((SELECT confdeltype FROM pg_constraint WHERE conname = 'library_loans_copy_id_fkey') = 'r',
  'the loan-to-copy link no longer cascades on delete');
SELECT raises($$DELETE FROM library_copies WHERE accession_no = 'ACC-0001'$$,
  'a copy that has been borrowed cannot be deleted');
SELECT ok((SELECT count(*) FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001') >= 2,
  'and its loans are all still there');
SELECT raises($$DELETE FROM library_members WHERE id = '33330000-0000-0000-0000-000000000001'$$,
  'a member who has borrowed cannot be deleted either');

-- A copy nobody has borrowed is still removable: this is not hoarding.
INSERT INTO library_copies (id, item_id, accession_no) VALUES
  ('22220000-0000-0000-0000-000000000009', '11110000-0000-0000-0000-000000000002', 'ACC-0009');
DELETE FROM library_copies WHERE accession_no = 'ACC-0009';
SELECT ok(NOT EXISTS (SELECT 1 FROM library_copies WHERE accession_no = 'ACC-0009'),
  'a copy with no history can still be removed');

\echo ''
\echo '== 10. lost books'

SELECT checkout_library_copy('22220000-0000-0000-0000-000000000003', '33330000-0000-0000-0000-000000000003');
SELECT set_config('kareya.library_loan_apply', 'on', false);  -- session-level: psql commits each statement
UPDATE library_loans SET loaned_at = CURRENT_DATE - 34, due_date = CURRENT_DATE - 20
 WHERE copy_id = '22220000-0000-0000-0000-000000000003' AND status = 'on_loan';
SELECT set_config('kareya.library_loan_apply', '', false);

SELECT mark_library_loan_lost((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000003' AND status = 'on_loan'));

SELECT ok((SELECT fine_amount FROM library_loans
            WHERE copy_id = '22220000-0000-0000-0000-000000000003' AND status = 'lost') = 14.00,
  'a lost book costs the accrued fine plus the replacement value (2.00 + 12.00)');
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0003') = 'lost',
  'and the copy leaves circulation rather than going back on the shelf');

\echo ''
\echo '== 11. a fine is money, and it is recorded like money'

SELECT ok((SELECT fine_paid_amount FROM library_loans
            WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00) = 0,
  'nothing has been collected yet');

SELECT raises($$SELECT collect_library_fine(
    (SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00), 5.00)$$,
  'collecting more than is owed is refused');
SELECT raises($$SELECT collect_library_fine(
    (SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00), 0.40)$$,
  'and a part payment is refused rather than silently recorded as settled');

SELECT collect_library_fine((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00));

SELECT ok((SELECT fine_paid_amount FROM library_loans
            WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00) = 1.00,
  'how much was taken is recorded, not just that something was');
SELECT ok((SELECT fine_collected_by FROM library_loans
            WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00)
          = 'f0000000-0000-0000-0000-000000000001',
  'and who took it');
SELECT ok((SELECT fine_paid_at FROM library_loans
            WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00) IS NOT NULL,
  'and when');

SELECT raises($$SELECT collect_library_fine(
    (SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND fine_amount = 1.00))$$,
  'collecting the same fine twice is refused');

\echo ''
\echo '== 12. forgiving a fine takes more authority than lending a book'

SELECT raises($$SELECT waive_library_fine(
    (SELECT id FROM library_loans WHERE status = 'lost'), 'Book was returned damaged by flooding')$$,
  'a librarian cannot write off money owed');

SELECT act_as('chantha@library.kh');
SELECT raises($$SELECT waive_library_fine((SELECT id FROM library_loans WHERE status = 'lost'), '   ')$$,
  'a manager cannot write it off without saying why');

SELECT waive_library_fine((SELECT id FROM library_loans WHERE status = 'lost'),
                          'Destroyed in the July flood, confirmed by the commune');

SELECT ok((SELECT fine_waived FROM library_loans WHERE status = 'lost') = true,
  'a manager can, with a reason');
SELECT ok((SELECT fine_waived_reason FROM library_loans WHERE status = 'lost')
          = 'Destroyed in the July flood, confirmed by the commune',
  'and the reason is on the record');
SELECT ok((SELECT fine_waived_by FROM library_loans WHERE status = 'lost')
          = 'f0000000-0000-0000-0000-000000000002',
  'with who decided it');

SELECT act_as('sokha@library.kh');

\echo ''
\echo '== 13. reservations'

-- ACC-0004 and ACC-0005 are on the shelf for Khmer Grammar, so a hold
-- makes no sense yet.
SELECT raises($$SELECT place_library_hold('11110000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000002')$$,
  'reserving a title with a copy on the shelf is refused — issue it instead');

SELECT checkout_library_copy('22220000-0000-0000-0000-000000000004', '33330000-0000-0000-0000-000000000001');
SELECT checkout_library_copy('22220000-0000-0000-0000-000000000005', '33330000-0000-0000-0000-000000000002');

SELECT place_library_hold('11110000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000003');
SELECT ok((SELECT count(*) FROM library_holds WHERE status = 'waiting') = 1,
  'with every copy out, a reservation is accepted');
SELECT raises($$SELECT place_library_hold('11110000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000003')$$,
  'the same member cannot join the queue twice for the same title');
SELECT raises($$SELECT place_library_hold('11110000-0000-0000-0000-000000000002', '33330000-0000-0000-0000-000000000001')$$,
  'and somebody already holding a copy of the title cannot reserve another');

SELECT raises($$SELECT renew_library_loan(
    (SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000004' AND status = 'on_loan'))$$,
  'a loan cannot be renewed while somebody is waiting for the title');

\echo ''
\echo '== 14. a returned copy goes to whoever is waiting'

SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000004' AND status = 'on_loan'));

SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0004') = 'on_hold_shelf',
  'the returned copy is set aside rather than shelved');
SELECT ok((SELECT status FROM library_holds WHERE member_id = '33330000-0000-0000-0000-000000000003') = 'ready',
  'and the reservation is ready');
SELECT ok((SELECT copy_id FROM library_holds WHERE member_id = '33330000-0000-0000-0000-000000000003')
          = '22220000-0000-0000-0000-000000000004',
  'against the copy that came back');
SELECT ok((SELECT expires_at FROM library_holds WHERE member_id = '33330000-0000-0000-0000-000000000003')
          = CURRENT_DATE + 3,
  'with a date the hold shelf keeps it until');

SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000004', '33330000-0000-0000-0000-000000000002')$$,
  'a copy on the hold shelf cannot be issued to somebody else');

\echo ''
\echo '== 15. THE HOLD SHELF CLEARS'

-- A ready hold was given an expires_at and nothing ever looked at it
-- again. The member who reserved the book and did not come back kept that
-- copy off the shelf for everybody, for good.
SELECT ok((SELECT count(*) FROM expire_library_holds()) = 0,
  'a hold that is still in date is not swept');

UPDATE library_holds SET expires_at = CURRENT_DATE - 1 WHERE status = 'ready';

SELECT ok((SELECT count(*) FROM expire_library_holds()) = 1,
  'a hold past its date is swept');
SELECT ok((SELECT status FROM library_holds WHERE member_id = '33330000-0000-0000-0000-000000000003') = 'expired',
  'the reservation is marked expired rather than left ready for ever');
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0004') = 'available',
  'AND THE COPY GOES BACK ON THE SHELF — this is what never happened before');

-- The sweep says what it did, rather than the shelf silently rearranging.
-- ACC-0002 goes for repair so nothing of this title is on the shelf and a
-- queue can form behind the one copy that is out.
UPDATE library_copies SET status = 'repair' WHERE accession_no = 'ACC-0002';

SELECT place_library_hold('11110000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000003');
SELECT place_library_hold('11110000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000001');
SELECT return_library_loan((SELECT id FROM library_loans WHERE copy_id = '22220000-0000-0000-0000-000000000001' AND status = 'on_loan'));

SELECT ok((SELECT member_id FROM library_holds
            WHERE item_id = '11110000-0000-0000-0000-000000000001' AND status = 'ready')
          = '33330000-0000-0000-0000-000000000003',
  'the first in the queue gets it');

UPDATE library_holds SET expires_at = CURRENT_DATE - 1
 WHERE item_id = '11110000-0000-0000-0000-000000000001' AND status = 'ready';

SELECT ok((SELECT out_passed_to FROM expire_library_holds()) = 'Sreymom',
  'sweeping a lapsed hold passes the copy to the next member waiting, and says so');
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0001') = 'on_hold_shelf',
  'so the copy stays set aside rather than going back to the shelf past the queue');
SELECT ok((SELECT member_id FROM library_holds
            WHERE item_id = '11110000-0000-0000-0000-000000000001' AND status = 'ready')
          = '33330000-0000-0000-0000-000000000001',
  'and the next member is the one it is now waiting for');

\echo ''
\echo '== 16. cancelling a reservation releases the copy'

SELECT cancel_library_hold((SELECT id FROM library_holds
                             WHERE item_id = '11110000-0000-0000-0000-000000000001' AND status = 'ready'));
SELECT ok((SELECT status FROM library_copies WHERE accession_no = 'ACC-0001') = 'available',
  'cancelling a ready reservation puts its copy back into circulation');
SELECT raises($$SELECT cancel_library_hold((SELECT id FROM library_holds WHERE status = 'cancelled' LIMIT 1))$$,
  'cancelling the same reservation twice is refused');

\echo ''
\echo '== 17. who may work the desk'

SELECT act_as('rithy@library.kh');
SELECT raises($$SELECT checkout_library_copy('22220000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000002')$$,
  'a driver cannot issue a book');
SELECT raises($$SELECT return_library_loan((SELECT id FROM library_loans WHERE status = 'on_loan' LIMIT 1))$$,
  'nor take one back');
SELECT raises($$SELECT place_library_hold('11110000-0000-0000-0000-000000000001', '33330000-0000-0000-0000-000000000002')$$,
  'nor place a reservation');
SELECT act_as('sokha@library.kh');

\echo ''
\echo '== 18. reconciliation names drift, it does not paper over it'

SELECT ok(NOT EXISTS (SELECT 1 FROM library_reconciliation() WHERE out_kind = 'copy'),
  'after everything above, no copy disagrees with its loan record');

-- Money owed and never settled either way is the one thing that should
-- still be showing.
SELECT ok(EXISTS (SELECT 1 FROM library_reconciliation() WHERE out_kind = 'fine'),
  'an unsettled fine is reported until somebody collects or writes it off');

SELECT ok(NOT EXISTS (SELECT 1 FROM library_reconciliation() WHERE out_kind = 'hold'),
  'and no reservation is sitting past its date on the hold shelf');

\echo ''
\echo '===================================================================='
\echo ' LIBRARY: all assertions passed'
\echo '===================================================================='
