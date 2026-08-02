-- =====================================================================
-- CLIENT PORTAL — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- A company's own client fills in a form without an account, gated by a
-- passcode. This is the first place in Kareya where somebody who is not a
-- user at all can WRITE into a customer's database, so the assertions
-- below are almost entirely about what must NOT happen.
--
-- A WRONG CODE LEARNS NOTHING. Every refusal returns the same message.
-- Telling somebody a prefix is real but the rest is wrong tells an
-- attacker which half to keep.
--
-- A REVOKED PASS IS REVOKED NOW, not when its session happens to expire.
--
-- A TOKEN REACHES ONE FORM AND ONE CLIENT'S OWN SUBMISSIONS. Not the form
-- list, not another client, not one row of anything else.
--
-- AND THE RULES ARE THE SAME FOR BOTH DOORS: a required field is required
-- whether staff or the client is typing, which is why both paths call the
-- same validator rather than each carrying a copy.
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

-- Nobody at all: what an anonymous visitor's connection looks like.
CREATE OR REPLACE FUNCTION act_as_nobody() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '', false);
  PERFORM set_config('request.jwt.claim.sub', '', false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('c1100000-0000-0000-0000-000000000001', 'manager@firm.kh')
ON CONFLICT DO NOTHING;
INSERT INTO employees (id, user_id, name, email, roles, status)
VALUES ('c1200000-0000-0000-0000-000000000001', 'c1100000-0000-0000-0000-000000000001',
        'Sopheak', 'manager@firm.kh', ARRAY['Manager'], 'active')
ON CONFLICT DO NOTHING;

SELECT act_as('manager@firm.kh');

-- One published form with one required field, and one that is not live.
INSERT INTO form_defs (id, name, description, schema, workflow, is_published) VALUES
 ('c1300000-0000-0000-0000-000000000001', 'Service request',
  'Tell us what you need', '[
     {"key":"subject","label":"Subject","type":"text","required":true,"isTitle":true},
     {"key":"detail","label":"Detail","type":"textarea","required":false}]'::jsonb,
  '[]'::jsonb, true),
 ('c1300000-0000-0000-0000-000000000002', 'Draft form', NULL,
  '[{"key":"a","label":"A","type":"text","required":false}]'::jsonb, '[]'::jsonb, false);

-- ------------------------------------------------------- issuing a pass
DO $$
DECLARE r record; v_code text; v_id uuid;
BEGIN
  SELECT * INTO r FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000001', 'Sokha Trading', '012345678', NULL, 'first client',
      ARRAY['submissions', 'shared']);
  v_code := r.out_code; v_id := r.out_id;
  PERFORM set_config('test.code', v_code, false);
  PERFORM set_config('test.pass', v_id::text, false);

  PERFORM ok(v_code ~ '^[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{10}$',
             'a passcode is PREFIX-SECRET from an alphabet with no 0/O and no 1/I/L');
  PERFORM ok((SELECT code_hash FROM client_passes WHERE id = v_id) <> v_code,
             'the code is not stored in clear');
  PERFORM ok((SELECT code_prefix FROM client_passes WHERE id = v_id) = split_part(v_code, '-', 1),
             'only the prefix is kept readable, so a lookup does not hash every row');
  PERFORM ok((SELECT count(*) FROM client_passes WHERE code_hash = v_code) = 0,
             'and the whole code cannot be found by searching for it');
END $$;

SELECT raises(
  $$SELECT issue_client_pass('c1300000-0000-0000-0000-00000000000f', 'Nobody')$$,
  'a passcode cannot be issued against a form that does not exist');

-- ------------------------------------------------------- opening a door
DO $$
DECLARE r record; v_code text := current_setting('test.code');
BEGIN
  PERFORM act_as_nobody();

  SELECT * INTO r FROM open_client_session(v_code);
  PERFORM ok(r.out_ok, 'the right code opens a session for somebody with no account at all');
  PERFORM ok(r.out_form_name = 'Service request', 'and names the form it opens');
  PERFORM ok(r.out_client_name = 'Sokha Trading', 'and the client it belongs to');
  PERFORM set_config('test.token', r.out_token, false);

  -- Typed back the way a person actually types it.
  SELECT * INTO r FROM open_client_session(lower(replace(v_code, '-', '')));
  PERFORM ok(r.out_ok, 'lower case with the dash left out still works — that is a person, not a forgery');
  SELECT * INTO r FROM open_client_session('  ' || v_code || ' ');
  PERFORM ok(r.out_ok, 'and so does a code pasted with spaces around it');

  -- What an attacker gets.
  SELECT * INTO r FROM open_client_session('ZZZZ-ZZZZZZZZZZ');
  PERFORM ok(NOT r.out_ok AND r.out_message = 'not_recognised', 'an invented code is refused');
  PERFORM ok(r.out_token IS NULL, 'and hands back no token');
  SELECT * INTO r FROM open_client_session(split_part(v_code, '-', 1) || '-ZZZZZZZZZZ');
  PERFORM ok(NOT r.out_ok AND r.out_message = 'not_recognised',
             'a REAL prefix with a wrong secret gets the same answer as an invented one');
  SELECT * INTO r FROM open_client_session('');
  PERFORM ok(NOT r.out_ok, 'an empty code is refused');
  SELECT * INTO r FROM open_client_session('ABC');
  PERFORM ok(NOT r.out_ok, 'a too-short code is refused without touching the table');
END $$;

-- --------------------------------------------------------- the lock-out
DO $$
DECLARE r record; v_code text := current_setting('test.code'); v_prefix text; i integer;
BEGIN
  PERFORM act_as_nobody();
  v_prefix := split_part(v_code, '-', 1);
  -- Four more wrong guesses at a known prefix (one was already spent above).
  FOR i IN 1..4 LOOP PERFORM open_client_session(v_prefix || '-YYYYYYYYYY'); END LOOP;

  SELECT * INTO r FROM open_client_session(v_code);
  PERFORM ok(NOT r.out_ok AND r.out_message = 'locked',
             'five wrong guesses at one prefix locks it, even against the RIGHT code');
  PERFORM ok((SELECT locked_until > now() FROM client_passes WHERE id = current_setting('test.pass')::uuid),
             'and the lock has an end, so a client is not shut out forever');

  -- Wind the clock back rather than wait fifteen minutes.
  UPDATE client_passes SET locked_until = now() - interval '1 minute'
   WHERE id = current_setting('test.pass')::uuid;
  SELECT * INTO r FROM open_client_session(v_code);
  PERFORM ok(r.out_ok, 'once the lock lapses the right code works again');
  PERFORM ok((SELECT failed_attempts = 0 FROM client_passes WHERE id = current_setting('test.pass')::uuid),
             'and a good login clears the count, so yesterday cannot lock out tomorrow');
  PERFORM set_config('test.token', r.out_token, false);
END $$;

-- ------------------------------------------------- what a token reaches
DO $$
DECLARE r record; v_token text := current_setting('test.token'); n integer;
BEGIN
  PERFORM act_as_nobody();

  SELECT * INTO r FROM client_form(v_token);
  PERFORM ok(r.name = 'Service request', 'the token reaches its own form');
  PERFORM ok(jsonb_array_length(r.schema) = 2, 'and the fields to fill in');

  SELECT count(*) INTO n FROM client_form('deadbeef');
  PERFORM ok(n = 0, 'an invented token reaches nothing');

  -- Submitting.
  SELECT * INTO r FROM client_submit_form(v_token, '{"subject":"Broken meter","detail":"No reading"}'::jsonb);
  PERFORM ok(r.out_reference IS NOT NULL, 'a client can submit, with no account and no employee record');
  PERFORM set_config('test.sub', r.out_id::text, false);
  PERFORM ok((SELECT submitted_by IS NULL FROM form_submissions WHERE id = r.out_id),
             'the submission is attributed to no employee, because none was involved');
  PERFORM ok((SELECT client_pass_id = current_setting('test.pass')::uuid FROM form_submissions WHERE id = r.out_id),
             'and to the passcode it came from, so the company knows who sent it');
  PERFORM ok((SELECT title = 'Broken meter' FROM form_submissions WHERE id = r.out_id),
             'the title comes from the field flagged as the title');

  -- The rules are the same for both doors.
  PERFORM ok((SELECT count(*) FROM client_my_submissions(v_token)) = 1,
             'a client sees their own submission');
END $$;

-- ------------------------------------------- what the company may share
-- A client never reads the company's own tables. Staff copy an item into
-- a table that exists only for this, and that copy is all there is.
DO $$
DECLARE v_item uuid; r record; n integer; v_token text := current_setting('test.token');
BEGIN
  PERFORM act_as('manager@firm.kh');
  INSERT INTO clients (id, name) VALUES ('c1400000-0000-0000-0000-000000000001', 'Sokha Trading')
    ON CONFLICT DO NOTHING;
  INSERT INTO invoices (id, client_id, invoice_number, amount, status)
    VALUES ('c1500000-0000-0000-0000-000000000001', 'c1400000-0000-0000-0000-000000000001',
            'INV-001', 250, 'pending')
    ON CONFLICT DO NOTHING;
  -- A second invoice for the SAME customer that is never shared.
  INSERT INTO invoices (id, client_id, invoice_number, amount, status)
    VALUES ('c1500000-0000-0000-0000-000000000002', 'c1400000-0000-0000-0000-000000000001',
            'INV-002', 999, 'pending')
    ON CONFLICT DO NOTHING;

  v_item := share_with_client(current_setting('test.pass')::uuid, 'invoice', 'Invoice INV-001',
                              'INV-001', NULL, 250, 'USD', 'pending', NULL,
                              'invoices', 'c1500000-0000-0000-0000-000000000001');
  PERFORM set_config('test.item', v_item::text, false);

  PERFORM act_as_nobody();
  SELECT count(*) INTO n FROM client_shared(v_token);
  PERFORM ok(n = 1, 'a client sees the one item that was shared with them');
  PERFORM ok(n = 1, 'and NOT the second invoice of the same customer, which nobody shared');

  SELECT * INTO r FROM client_shared(v_token) LIMIT 1;
  PERFORM ok(r.reference = 'INV-001' AND r.amount = 250, 'with the values as they were when it was shared');

  -- The copy is frozen. This is the cost of not joining, stated as a test.
  PERFORM act_as('manager@firm.kh');
  UPDATE invoices SET status = 'paid' WHERE id = 'c1500000-0000-0000-0000-000000000001';
  PERFORM act_as_nobody();
  SELECT * INTO r FROM client_shared(v_token) LIMIT 1;
  PERFORM ok(r.status = 'pending',
             'the copy does not follow the original — a shared item is a snapshot, not a window');

  PERFORM act_as('manager@firm.kh');
  SELECT count INTO n FROM client_portal_reconciliation() WHERE issue = 'shared_invoice_moved';
  PERFORM ok(n = 1, 'and the check names it, so staff know to re-share');

  -- Withdrawing.
  PERFORM unshare_from_client(current_setting('test.item')::uuid);
  PERFORM act_as_nobody();
  SELECT count(*) INTO n FROM client_shared(v_token);
  PERFORM ok(n = 0, 'withdrawing a shared item takes it off the client''s screen');
END $$;

-- A pass without the 'shared' scope sees nothing, even if something was
-- shared with it by mistake.
DO $$
DECLARE v_code text; v_token text; v_pass uuid; n integer;
BEGIN
  PERFORM act_as('manager@firm.kh');
  SELECT out_id, out_code INTO v_pass, v_code FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000001', 'Form Only');   -- default scopes: form
  PERFORM share_with_client(v_pass, 'note', 'Should not be visible');

  PERFORM act_as_nobody();
  SELECT out_token INTO v_token FROM open_client_session(v_code);
  SELECT count(*) INTO n FROM client_shared(v_token);
  PERFORM ok(n = 0, 'a pass without the shared scope sees nothing, even when something was shared to it');
  SELECT count(*) INTO n FROM client_my_submissions(v_token);
  PERFORM ok(n = 0, 'and one without the submissions scope sees no submissions');
END $$;

SELECT raises(
  $$SELECT client_submit_form(current_setting('test.token'), '{"detail":"no subject"}'::jsonb)$$,
  'a required field is required for the client too, not only in the browser');

SELECT raises(
  $$SELECT client_submit_form('deadbeef', '{"subject":"x"}'::jsonb)$$,
  'an invented token cannot submit anything');

-- ------------------------------------------- one client, one form, only
DO $$
DECLARE r record; v_other text; v_token2 text; n integer;
BEGIN
  PERFORM act_as('manager@firm.kh');
  SELECT out_code INTO v_other FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000001', 'Rival Traders');

  PERFORM act_as_nobody();
  SELECT out_token INTO v_token2 FROM open_client_session(v_other);

  SELECT count(*) INTO n FROM client_my_submissions(v_token2);
  PERFORM ok(n = 0, 'a second client on the SAME form sees none of the first client''s submissions');

  PERFORM ok((SELECT count(*) FROM client_form(v_token2)) = 1,
             'but does reach the form itself');
END $$;

-- --------------------------------------------------- a form not on sale
DO $$
DECLARE r record; v_code text;
BEGIN
  PERFORM act_as('manager@firm.kh');
  SELECT out_code INTO v_code FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000002', 'Early Bird');

  PERFORM act_as_nobody();
  SELECT * INTO r FROM open_client_session(v_code);
  PERFORM ok(NOT r.out_ok AND r.out_message = 'form_closed',
             'a good code for an unpublished form says so plainly — the holder is legitimate');
END $$;

-- ------------------------------------------------------------- revoking
DO $$
DECLARE r record; v_token text := current_setting('test.token'); n integer;
BEGIN
  PERFORM act_as('manager@firm.kh');
  PERFORM revoke_client_pass(current_setting('test.pass')::uuid, 'contract ended');

  PERFORM act_as_nobody();
  SELECT count(*) INTO n FROM client_form(v_token);
  PERFORM ok(n = 0, 'revoking cuts the session that is already open, not just the next one');

  SELECT * INTO r FROM open_client_session(current_setting('test.code'));
  PERFORM ok(NOT r.out_ok AND r.out_message = 'not_recognised',
             'and a revoked code is refused the same way an invented one is');
END $$;

SELECT raises(
  $$SELECT client_submit_form(current_setting('test.token'), '{"subject":"after revoke"}'::jsonb)$$,
  'a revoked client cannot submit with the token they still hold');

-- ------------------------------------------------------------- expiring
DO $$
DECLARE r record; v_code text;
BEGIN
  PERFORM act_as('manager@firm.kh');
  SELECT out_code INTO v_code FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000001', 'Short Stay', NULL, now() - interval '1 day');

  PERFORM act_as_nobody();
  SELECT * INTO r FROM open_client_session(v_code);
  PERFORM ok(NOT r.out_ok, 'a passcode past its expiry does not open');
END $$;

DO $$
DECLARE r record; v_code text; v_token text; n integer;
BEGIN
  PERFORM act_as('manager@firm.kh');
  SELECT out_code INTO v_code FROM issue_client_pass(
      'c1300000-0000-0000-0000-000000000001', 'Session Expiry');
  PERFORM act_as_nobody();
  SELECT out_token INTO v_token FROM open_client_session(v_code);
  UPDATE client_sessions SET expires_at = now() - interval '1 minute'
   WHERE token_hash = encode(digest(v_token, 'sha256'), 'hex');
  SELECT count(*) INTO n FROM client_form(v_token);
  PERFORM ok(n = 0, 'a session that has run out reaches nothing, and the code must be typed again');
END $$;

-- --------------------------------------- a client is not staff, at all
-- Run as the REAL anon role rather than as the test's superuser, which
-- bypasses row-level security outright. Without this the assertions below
-- would pass while testing nothing — the mistake is easy to make and
-- invisible once made.
SET ROLE anon;

SELECT raises($$SELECT count(*) FROM client_passes$$,
              'an anonymous visitor cannot read the passcode table at all');
SELECT raises($$SELECT count(*) FROM form_defs$$,
              'and cannot list the forms');
SELECT raises($$SELECT count(*) FROM form_submissions$$,
              'and cannot read submissions');
SELECT raises($$SELECT count(*) FROM client_sessions$$,
              'and cannot read the open sessions');
SELECT raises($$SELECT count(*) FROM client_shared_items$$,
              'and cannot read the shared-items table directly');
SELECT raises($$SELECT count(*) FROM invoices$$,
              'and above all cannot read the invoices — the company data is never joined to');
SELECT raises($$SELECT count(*) FROM clients$$,
              'nor the customer list');
SELECT raises($$SELECT share_with_client('c1300000-0000-0000-0000-000000000001', 'note', 'x')$$,
              'and cannot share anything with themselves');
SELECT raises($$SELECT issue_client_pass('c1300000-0000-0000-0000-000000000001', 'Myself')$$,
              'and cannot issue themselves a passcode');
SELECT raises($$SELECT revoke_client_pass('c1300000-0000-0000-0000-000000000001')$$,
              'and cannot revoke anybody else''s');
SELECT raises($$SELECT client_session_pass('anything')$$,
              'and cannot use the token resolver to test tokens by hand');

-- What anon IS allowed: the front door, and nothing else.
SELECT ok((SELECT count(*) FROM open_client_session('ZZZZ-ZZZZZZZZZZ')) = 1,
          'but CAN knock on the front door, which is the whole design');

RESET ROLE;

-- ------------------------------------------ the staff door still works
SELECT act_as('manager@firm.kh');
DO $$
DECLARE v_sub form_submissions;
BEGIN
  v_sub := submit_form('c1300000-0000-0000-0000-000000000001',
                       '{"subject":"Taken at the counter"}'::jsonb, 'Walk-in', '011222333');
  PERFORM ok(v_sub.reference IS NOT NULL, 'staff can still take a submission at the counter');
  PERFORM ok(v_sub.submitted_by IS NOT NULL, 'and it is attributed to the employee who typed it');
  PERFORM ok(v_sub.client_pass_id IS NULL, 'with no passcode against it');
  PERFORM ok(v_sub.title = 'Taken at the counter', 'and the shared title rule applied');
END $$;

SELECT raises(
  $$SELECT submit_form('c1300000-0000-0000-0000-000000000001', '{"detail":"no subject"}'::jsonb)$$,
  'and the shared required-field rule applied — one validator, both doors');

-- ------------------------------------------------------------ the check
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM client_portal_reconciliation();
  PERFORM ok(n = 6, 'the check reports six things worth looking at');
  SELECT count INTO n FROM client_portal_reconciliation() WHERE issue = 'form_unpublished';
  PERFORM ok(n >= 1, 'and names the live passcode whose form was never published');
  SELECT count INTO n FROM client_portal_reconciliation() WHERE issue = 'expired_not_revoked';
  PERFORM ok(n >= 1, 'and the expired passcode nobody tidied up');
END $$;

SELECT 'client-portal tests complete';
