-- =====================================================================
-- DOCUMENT REGISTER — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- Each assertion here guards something that, if it broke, would send an
-- office straight back to the paper register the module was supposed to
-- replace: a number issued twice, a number that vanished, a template edit
-- that quietly re-routed work already in flight, an approval taken by
-- somebody who was not entitled to take it.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/documents.test.sql
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

-- Act as a given employee. Both claims are set, not just the email: the
-- RPCs identify the caller by user_id OR email, but the RLS helper
-- current_employee_id() matches on user_id alone, so a test that only set
-- the email would exercise the functions and quietly skip the policies.
CREATE OR REPLACE FUNCTION act_as(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT user_id INTO v_uid FROM employees WHERE email = p_email;
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_email)::text, false);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('e0000000-0000-0000-0000-00000000000a', 'clerk@office.kh'),
  ('e0000000-0000-0000-0000-00000000000b', 'manager@office.kh'),
  ('e0000000-0000-0000-0000-00000000000c', 'director@office.kh'),
  ('e0000000-0000-0000-0000-00000000000d', 'admin@office.kh'),
  ('e0000000-0000-0000-0000-00000000000e', 'deputy@office.kh'),
  ('e0000000-0000-0000-0000-00000000000f', 'acct@office.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('d0000000-0000-0000-0000-00000000000a', 'e0000000-0000-0000-0000-00000000000a', 'Chanthou (clerk)',  'clerk@office.kh',   ARRAY['Reception']),
  ('d0000000-0000-0000-0000-00000000000b', 'e0000000-0000-0000-0000-00000000000b', 'Sopheak (manager)', 'manager@office.kh', ARRAY['Manager']),
  ('d0000000-0000-0000-0000-00000000000c', 'e0000000-0000-0000-0000-00000000000c', 'Rithy (director)',  'director@office.kh',ARRAY['Director']),
  ('d0000000-0000-0000-0000-00000000000d', 'e0000000-0000-0000-0000-00000000000d', 'Sokha (admin)',     'admin@office.kh',   ARRAY['Admin']),
  ('d0000000-0000-0000-0000-00000000000e', 'e0000000-0000-0000-0000-00000000000e', 'Vanna (deputy)',    'deputy@office.kh',  ARRAY['Reception'])
ON CONFLICT DO NOTHING;

\echo '== 1. numbering series'

SELECT ok(allocate_document_number('IN', DATE '2026-03-04') = 'IN-0001/2026',
          'the first incoming number is IN-0001/2026');
SELECT ok(allocate_document_number('IN', DATE '2026-07-30') = 'IN-0002/2026',
          'the next one continues the same year series');
SELECT ok(allocate_document_number('OUT', DATE '2026-03-04') = 'OUT-0001/2026',
          'outgoing runs its own series, not a shared counter');
SELECT ok(allocate_document_number('IN', DATE '2027-01-02') = 'IN-0001/2027',
          'a new year restarts the series when the series says to');
SELECT ok(allocate_document_number('IN', DATE '2026-12-31') = 'IN-0003/2026',
          'a late 2026 registration takes the next 2026 number, not a 2027 one');

SELECT raises($$SELECT allocate_document_number('NOPE')$$,
              'an unknown series is refused rather than invented');

INSERT INTO document_series (code, name, prefix, width, reset_yearly, is_active)
VALUES ('OLD', 'Retired series', 'OLD-', 3, false, false);
SELECT raises($$SELECT allocate_document_number('OLD')$$,
              'a closed series issues no more numbers');

INSERT INTO document_series (code, name, prefix, suffix, width, reset_yearly)
VALUES ('CONT', 'Continuous series', 'C', '', 6, false);
SELECT ok(allocate_document_number('CONT', DATE '2026-01-01') = 'C000001',
          'a continuous series carries no year and honours its own width');
SELECT ok(allocate_document_number('CONT', DATE '2030-01-01') = 'C000002',
          'a continuous series does not reset across years');

-- The counter is the series. Nothing may hand out a number except the
-- allocator, which is why the counter table has no write policy at all.
SELECT ok((SELECT last_no FROM document_series_counters WHERE series_code = 'IN' AND period = '2026') = 3,
          'the counter records exactly what was issued');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE tablename = 'document_series_counters' AND cmd IN ('INSERT','UPDATE','ALL')),
          'no client policy can move a counter by hand');

\echo '== 2. registering a document'

SELECT act_as('clerk@office.kh');

-- An incoming letter: it arrived, it is somebody's to answer, by a date.
SELECT ok((register_document(
    p_direction          => 'incoming',
    p_title              => 'Request for staffing figures',
    p_correspondent_name => 'Mr Dara',
    p_correspondent_org  => 'Provincial Department',
    p_their_ref          => '០៤៥/២៦',
    p_document_date      => CURRENT_DATE - 2,
    p_received_at        => CURRENT_DATE - 1,
    p_action_officer     => 'd0000000-0000-0000-0000-00000000000b',
    p_due_date           => CURRENT_DATE + 5
  )).reference LIKE 'IN-%',
          'an incoming letter is registered and numbered');

SELECT ok((SELECT count(*) FROM document_requests WHERE direction = 'incoming') = 1,
          'the incoming letter is in the register');
SELECT ok((SELECT their_ref FROM document_requests WHERE direction = 'incoming')
          = '០៤៥/២៦',
          'the sender''s own number is kept, so a reply can cite it');
SELECT ok((SELECT current_step_id FROM document_requests WHERE direction = 'incoming') IS NULL,
          'an incoming letter has no approval chain to walk');

SELECT raises($$SELECT register_document('sideways', 'Nowhere')$$,
              'a direction that is not in/out/internal is refused');
SELECT raises($$SELECT register_document('incoming', '   ')$$,
              'a document with no subject is refused');

SELECT act_as('nobody@elsewhere.kh');
SELECT raises($$SELECT register_document('incoming', 'From an outsider')$$,
              'somebody who is not an employee cannot register anything');
SELECT act_as('clerk@office.kh');

-- Two documents may never share a number, whatever route they took in.
SELECT raises($$
  INSERT INTO document_requests (title, reference, requester_id)
  VALUES ('Forged duplicate', (SELECT reference FROM document_requests WHERE reference IS NOT NULL LIMIT 1),
          'd0000000-0000-0000-0000-00000000000a')$$,
              'a second document cannot take a number already issued');

\echo '== 3. template versioning pins work already in flight'

INSERT INTO document_templates (id, name, description, content, workflow, series_code, default_due_days)
VALUES ('d1000000-0000-0000-0000-000000000001', 'Leave Request', 'Annual leave', '<p>Leave</p>',
        '[{"id":"s1","name":"Manager review","type":"approval","order":1,"allowedRoles":["Manager"]},
          {"id":"s2","name":"Director sign-off","type":"approval","order":2,"allowedRoles":["Director"]}]'::jsonb,
        'INT', 7);

SELECT ok((SELECT version FROM document_templates WHERE id = 'd1000000-0000-0000-0000-000000000001') = 1,
          'a new template starts at version 1');
SELECT ok(EXISTS (SELECT 1 FROM document_template_versions
                   WHERE template_id = 'd1000000-0000-0000-0000-000000000001' AND version = 1),
          'version 1 is archived the moment the template exists');

SELECT act_as('clerk@office.kh');
SELECT ok((register_document('internal', 'Leave — Chanthou',
             p_template_id => 'd1000000-0000-0000-0000-000000000001')).current_step_id = 's1',
          'an internal request starts on the first step of its template');

SELECT ok((SELECT due_date FROM document_requests WHERE title = 'Leave — Chanthou')
          = CURRENT_DATE + 7,
          'the template''s default turnaround becomes a real due date');
SELECT ok((SELECT jsonb_array_length(workflow_snapshot) FROM document_requests WHERE title = 'Leave — Chanthou') = 2,
          'the request freezes the two steps it was raised under');
SELECT ok((SELECT template_version FROM document_requests WHERE title = 'Leave — Chanthou') = 1,
          'the request records which version of the template it followed');

-- Now somebody edits the template. This used to re-route everything that
-- was already halfway through it.
UPDATE document_templates
   SET workflow = '[{"id":"s9","name":"New single step","type":"approval","order":1,"allowedRoles":["Admin"]}]'::jsonb
 WHERE id = 'd1000000-0000-0000-0000-000000000001';

SELECT ok((SELECT version FROM document_templates WHERE id = 'd1000000-0000-0000-0000-000000000001') = 2,
          'editing the workflow bumps the template version');
SELECT ok((SELECT count(*) FROM document_template_versions
            WHERE template_id = 'd1000000-0000-0000-0000-000000000001') = 2,
          'both versions are on record');
SELECT ok((SELECT jsonb_array_length(workflow_snapshot) FROM document_requests WHERE title = 'Leave — Chanthou') = 2,
          'the in-flight request still carries the steps it started with');
SELECT ok((SELECT current_step_id FROM document_requests WHERE title = 'Leave — Chanthou') = 's1',
          'and it is still sitting on a step that exists for it');

-- Renaming a template is not a rule change and must not bump the version.
UPDATE document_templates SET name = 'Leave Request (annual)'
 WHERE id = 'd1000000-0000-0000-0000-000000000001';
SELECT ok((SELECT version FROM document_templates WHERE id = 'd1000000-0000-0000-0000-000000000001') = 2,
          'renaming a template does not bump its version');

\echo '== 4. delegation — the acting officer'

SELECT ok('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000b')),
          'a manager holds their own role');
SELECT ok(NOT ('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000e'))),
          'the deputy does not hold it yet');

INSERT INTO approval_delegations (id, delegator_id, delegate_id, from_date, to_date, reason)
VALUES ('d2000000-0000-0000-0000-000000000001',
        'd0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-00000000000e',
        CURRENT_DATE - 1, CURRENT_DATE + 3, 'Manager on mission');

SELECT ok('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000e', CURRENT_DATE)),
          'inside the window the deputy acts with the manager''s role');
SELECT ok(NOT ('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000e', CURRENT_DATE + 10))),
          'after the window it lapses on its own');
SELECT ok(NOT ('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000e', CURRENT_DATE - 5))),
          'and it did not apply before the window either');
SELECT ok('Reception' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000e')),
          'delegation adds to the deputy''s own roles rather than replacing them');
SELECT ok('Manager' = ANY (effective_roles('d0000000-0000-0000-0000-00000000000b')),
          'the manager does not lose the role by delegating it');

SELECT raises($$
  INSERT INTO approval_delegations (delegator_id, delegate_id, from_date, to_date)
  VALUES ('d0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-00000000000a',
          CURRENT_DATE, CURRENT_DATE + 1)$$,
              'one person cannot have two overlapping delegations out');
SELECT raises($$
  INSERT INTO approval_delegations (delegator_id, delegate_id, from_date, to_date)
  VALUES ('d0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-00000000000b',
          CURRENT_DATE + 90, CURRENT_DATE + 91)$$,
              'delegating to yourself is meaningless and refused');
SELECT raises($$
  INSERT INTO approval_delegations (delegator_id, delegate_id, from_date, to_date)
  VALUES ('d0000000-0000-0000-0000-00000000000c', 'd0000000-0000-0000-0000-00000000000a',
          CURRENT_DATE + 5, CURRENT_DATE)$$,
              'a delegation cannot end before it starts');

-- A non-overlapping second window is fine — that is just the next trip.
INSERT INTO approval_delegations (delegator_id, delegate_id, from_date, to_date)
VALUES ('d0000000-0000-0000-0000-00000000000b', 'd0000000-0000-0000-0000-00000000000a',
        CURRENT_DATE + 30, CURRENT_DATE + 35);
SELECT ok((SELECT count(*) FROM approval_delegations
            WHERE delegator_id = 'd0000000-0000-0000-0000-00000000000b') = 2,
          'a later, separate window is allowed');

\echo '== 5. approvals follow the frozen steps, and the acting officer may take them'

-- The deputy holds Reception only, plus Manager by delegation. Step s1
-- wants Manager. The live template no longer even contains s1.
SELECT act_as('deputy@office.kh');
SELECT ok((process_document(
             (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
             'approve', 'Approved while the manager is away')).current_step_id = 's2',
          'the acting deputy clears step 1 and the request moves to step 2');

SELECT ok((SELECT history -> -1 ->> 'stepName' FROM document_requests WHERE title = 'Leave — Chanthou')
          = 'Manager review',
          'the trail names the step that was actioned, not just the action');

SELECT raises($$SELECT process_document(
    (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'), 'approve')$$,
              'the deputy cannot also take the director''s step');

SELECT act_as('clerk@office.kh');
SELECT raises($$SELECT process_document(
    (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'), 'approve')$$,
              'the requester may not approve their own request');

SELECT act_as('director@office.kh');
SELECT ok((process_document(
             (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
             'approve', 'Signed')).status = 'approved',
          'the director''s approval is the last step and the request is approved');
SELECT ok((SELECT closed_at FROM document_requests WHERE title = 'Leave — Chanthou') IS NOT NULL,
          'reaching the end of the chain closes the file');

SELECT raises($$SELECT process_document(
    (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'), 'approve')$$,
              'an approved request cannot be approved a second time');

\echo '== 6. closing, voiding, and the number staying put'

SELECT act_as('manager@office.kh');
SELECT ok((close_document((SELECT id FROM document_requests WHERE direction = 'incoming'),
                          'Figures sent by email')).status = 'closed',
          'the action officer closes the incoming letter');
SELECT raises($$SELECT close_document((SELECT id FROM document_requests WHERE direction = 'incoming'))$$,
              'it cannot be closed twice');

SELECT act_as('clerk@office.kh');
SELECT (register_document('outgoing', 'Reply on staffing figures',
          p_correspondent_org => 'Provincial Department')).id;
SELECT act_as('director@office.kh');
SELECT raises($$SELECT close_document((SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'))$$,
              'somebody unconnected to the file cannot close it');

SELECT act_as('manager@office.kh');
SELECT raises($$SELECT void_document(
    (SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'), 'mistake')$$,
              'voiding a registered document is not an everyday act');

SELECT act_as('admin@office.kh');
SELECT raises($$SELECT void_document(
    (SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'), '  ')$$,
              'voiding without a reason is refused');

SELECT ok((void_document((SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'),
                         'Sent under the wrong reference')).status = 'void',
          'an administrator may void it, with a reason');
SELECT ok((SELECT reference FROM document_requests WHERE title = 'Reply on staffing figures') IS NOT NULL,
          'the voided document KEEPS its number, so the series shows no gap');
SELECT ok((SELECT void_reason FROM document_requests WHERE title = 'Reply on staffing figures')
          = 'Sent under the wrong reference',
          'and the reason is on the record');

SELECT raises($$DELETE FROM document_requests WHERE title = 'Reply on staffing figures'$$,
              'a numbered document cannot be deleted, only voided');
SELECT raises($$SELECT process_document(
    (SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'), 'approve')$$,
              'nothing further can be done to a void document');
SELECT raises($$SELECT assign_document(
    (SELECT id FROM document_requests WHERE title = 'Reply on staffing figures'),
    'd0000000-0000-0000-0000-00000000000b')$$,
              'a void document cannot be handed to anybody');

-- A draft that never entered the register may still be deleted outright.
INSERT INTO document_requests (id, title, requester_id)
VALUES ('d3000000-0000-0000-0000-000000000001', 'Unregistered scrap', 'd0000000-0000-0000-0000-00000000000a');
DELETE FROM document_requests WHERE id = 'd3000000-0000-0000-0000-000000000001';
SELECT ok(NOT EXISTS (SELECT 1 FROM document_requests WHERE id = 'd3000000-0000-0000-0000-000000000001'),
          'an unnumbered draft is still deletable');

\echo '== 7. assignment and attachments'

SELECT act_as('admin@office.kh');
SELECT ok((assign_document((SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                           'd0000000-0000-0000-0000-00000000000b', CURRENT_DATE + 2)).action_officer_id
          = 'd0000000-0000-0000-0000-00000000000b',
          'a file can be handed to a named officer with a date');
SELECT raises($$SELECT assign_document(
    (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
    'd0000000-0000-0000-0000-0000000000ff')$$,
              'it cannot be handed to somebody who does not work here');

INSERT INTO document_attachments (document_id, file_name, storage_path, mime_type, sha256, uploaded_by)
VALUES ((SELECT id FROM document_requests WHERE direction = 'incoming'),
        'scan-001.pdf', 'incoming/2026/scan-001.pdf', 'application/pdf', repeat('a', 64),
        'd0000000-0000-0000-0000-00000000000a');
SELECT ok((SELECT count(*) FROM document_attachments
            WHERE document_id = (SELECT id FROM document_requests WHERE direction = 'incoming')) = 1,
          'a scan is attached to the letter it belongs to');

SELECT raises($$
  INSERT INTO document_attachments (document_id, file_name)
  VALUES ((SELECT id FROM document_requests WHERE direction = 'incoming'), 'nowhere.pdf')$$,
              'an attachment that points at neither a file nor a link is refused');

-- A replacement scan supersedes the first rather than overwriting it.
INSERT INTO document_attachments (document_id, file_name, storage_path, version, replaces_id, uploaded_by)
VALUES ((SELECT id FROM document_requests WHERE direction = 'incoming'),
        'scan-001-rescanned.pdf', 'incoming/2026/scan-001-v2.pdf', 2,
        (SELECT id FROM document_attachments WHERE file_name = 'scan-001.pdf'),
        'd0000000-0000-0000-0000-00000000000a');
SELECT ok((SELECT count(*) FROM document_attachments
            WHERE document_id = (SELECT id FROM document_requests WHERE direction = 'incoming')) = 2,
          'the superseded scan is kept, not overwritten');

\echo '== 8. the register, and who is carrying what'

SELECT ok((SELECT count(*) FROM document_register(NULL, NULL, NULL)) >= 3,
          'the register lists every direction together');
SELECT ok((SELECT count(*) FROM document_register(NULL, NULL, 'incoming')) = 1,
          'and can be read one direction at a time');
SELECT ok((SELECT out_correspondent FROM document_register(NULL, NULL, 'incoming'))
          = 'Mr Dara (Provincial Department)',
          'the register shows who wrote, and for whom');
SELECT ok((SELECT out_attachment_count FROM document_register(NULL, NULL, 'incoming')) = 2,
          'the register shows how much paper is behind each entry');
SELECT ok((SELECT out_days_open FROM document_register(NULL, NULL, 'incoming')) = 1,
          'a closed item ages to the day it was closed, not to today');

-- An overdue file nobody has closed.
SELECT act_as('clerk@office.kh');
SELECT (register_document('incoming', 'Overdue circular',
          p_received_at    => CURRENT_DATE - 30,
          p_due_date       => CURRENT_DATE - 10,
          p_action_officer => 'd0000000-0000-0000-0000-00000000000b')).id;

SELECT ok((SELECT out_overdue FROM document_register(NULL, NULL, NULL)
            WHERE out_title = 'Overdue circular'),
          'a file past its date reads as overdue');
SELECT ok((SELECT out_days_open FROM document_register(NULL, NULL, NULL)
            WHERE out_title = 'Overdue circular') = 30,
          'and its age is counted from the day it arrived');

SELECT ok((SELECT out_overdue FROM document_register(NULL, NULL, 'incoming')
            WHERE out_title = 'Request for staffing figures') = false,
          'a closed file is never overdue, however late it was');

SELECT ok((SELECT out_overdue FROM document_register(NULL, NULL, NULL)
            WHERE out_title = 'Leave — Chanthou') = false,
          'an approved request with a past due date is not still overdue');

SELECT ok((SELECT out_open FROM document_workload()
            WHERE out_officer = 'Sopheak (manager)') = 1,
          'the workload shows what the manager is actually holding');
SELECT ok((SELECT out_overdue FROM document_workload()
            WHERE out_officer = 'Sopheak (manager)') = 1,
          'and how much of it is late');
SELECT ok(NOT EXISTS (SELECT 1 FROM document_workload() WHERE out_officer = 'Sokha (admin)'),
          'somebody carrying nothing does not appear in the workload');

-- Voided and rejected work is finished business and must not inflate
-- anybody's queue.
SELECT ok((SELECT coalesce(sum(out_open), 0) FROM document_workload()) =
          (SELECT count(*) FROM document_requests
            WHERE closed_at IS NULL AND status NOT IN ('void', 'rejected')),
          'the workload counts open files and nothing else');

\echo '== 9. confidentiality is decided by involvement, not by rank alone'

SELECT act_as('clerk@office.kh');
SELECT (register_document('incoming', 'Complaint about a staff member',
          p_confidentiality => 'confidential',
          p_action_officer  => 'd0000000-0000-0000-0000-00000000000c')).id;

SELECT raises($$SELECT register_document('incoming', 'Bad marking', p_confidentiality => 'top-secret')$$,
              'a confidentiality level we do not recognise is refused');

SELECT ok(EXISTS (SELECT 1 FROM pg_policies
                   WHERE tablename = 'document_requests' AND policyname = 'View documents'
                     AND qual LIKE '%confidentiality%'),
          'the read policy actually consults the confidentiality marking');

-- The step-visibility helper is what lets an approver see a confidential
-- item that is waiting on them, and only while it is waiting on them.
INSERT INTO document_templates (id, name, content, workflow)
VALUES ('d1000000-0000-0000-0000-000000000002', 'Disciplinary note', '<p>x</p>',
        '[{"id":"t1","name":"Director review","type":"approval","order":1,"allowedRoles":["Director"]}]'::jsonb);
SELECT (register_document('internal', 'Disciplinary — draft',
          p_template_id     => 'd1000000-0000-0000-0000-000000000002',
          p_confidentiality => 'confidential')).id;

SELECT ok(document_step_open_to_me((SELECT id FROM document_requests WHERE title = 'Disciplinary — draft')) = false,
          'the clerk cannot see a confidential item they are not part of');

\echo '== 10. re-running the vertical changes nothing'

SELECT ok((SELECT count(*) FROM document_series WHERE code IN ('IN','OUT','INT')) = 3,
          'the starting series were seeded exactly once');
SELECT ok((SELECT count(*) FROM document_attachments WHERE note LIKE 'Imported from%') = 0,
          'no phantom legacy attachments were invented');


\echo '== 11. the form engine, moved to the server'

INSERT INTO form_defs (id, name, category, schema, workflow, fee_amount, fee_currency, is_published)
VALUES ('f0000000-0000-0000-0000-000000000001', 'Business licence', 'permits',
        '[{"key":"trader","label":"Trader name","type":"text","required":true,"isTitle":true},
          {"key":"note","label":"Note","type":"textarea"}]'::jsonb,
        '[{"id":"w1","name":"Reception check","type":"approval","allowedRoles":["Reception"]},
          {"id":"w2","name":"Fee","type":"payment"},
          {"id":"w3","name":"Manager sign-off","type":"approval","allowedRoles":["Manager"]}]'::jsonb,
        25, 'USD', true);

INSERT INTO form_defs (id, name, schema, workflow, is_published)
VALUES ('f0000000-0000-0000-0000-000000000002', 'Unpublished draft', '[]'::jsonb, '[]'::jsonb, false);

SELECT act_as('clerk@office.kh');
SELECT raises($$SELECT submit_form('f0000000-0000-0000-0000-000000000002', '{}'::jsonb)$$,
              'an unpublished form cannot be submitted');
SELECT raises($$SELECT submit_form('f0000000-0000-0000-0000-000000000001', '{"note":"no trader"}'::jsonb)$$,
              'a required field missing on the server is refused, not only in the browser');

SELECT ok((submit_form('f0000000-0000-0000-0000-000000000001',
             '{"trader":"Sok Trading","note":"first"}'::jsonb)).reference LIKE 'SUB-%',
          'a submission is numbered by the database, not by a browser clock');
SELECT ok((SELECT title FROM form_submissions WHERE reference LIKE 'SUB-%' LIMIT 1) = 'Sok Trading',
          'the field flagged isTitle becomes the submission title');
SELECT ok((SELECT current_step FROM form_submissions LIMIT 1) = 0,
          'it starts on the first step');
SELECT ok((SELECT fee_amount FROM form_submissions LIMIT 1) = 25,
          'the fee is carried onto the submission because the workflow has a payment step');

-- The hole this closes: an employee could PATCH their own row to approved
-- and paid, and forge the events that were the only audit trail.
SELECT raises($$UPDATE form_submissions SET status = 'completed', fee_status = 'paid'$$,
              'a client can no longer write a submission directly')
  WHERE EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename = 'form_submissions' AND cmd IN ('UPDATE','ALL'));
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'form_submissions' AND cmd IN ('UPDATE','ALL','INSERT')),
          'no client policy grants write on form_submissions at all');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'form_submission_events' AND cmd IN ('INSERT','ALL')),
          'and none grants an event to be forged');

SELECT raises($$SELECT process_form_submission(
    (SELECT id FROM form_submissions LIMIT 1), 'approve')$$,
              'the submitter may not approve their own submission');

SELECT act_as('deputy@office.kh');
SELECT ok((process_form_submission((SELECT id FROM form_submissions LIMIT 1), 'approve')).current_step = 1,
          'a colleague with the Reception role clears step 1');
SELECT ok((SELECT status FROM form_submissions LIMIT 1) = 'in_review',
          'and the submission is now in review');

SELECT raises($$SELECT process_form_submission((SELECT id FROM form_submissions LIMIT 1), 'approve')$$,
              'a payment step cannot be approved past — it waits for the fee');

SELECT act_as('clerk@office.kh');
SELECT raises($$SELECT record_form_fee_paid((SELECT id FROM form_submissions LIMIT 1))$$,
              'an ordinary clerk cannot mark their own fee paid');

SELECT act_as('manager@office.kh');
SELECT ok((record_form_fee_paid((SELECT id FROM form_submissions LIMIT 1))).current_step = 2,
          'paying the fee moves the submission past the payment step by itself');
SELECT ok((SELECT fee_status FROM form_submissions LIMIT 1) = 'paid',
          'and the fee reads as paid');
SELECT ok(EXISTS (SELECT 1 FROM form_submission_events WHERE type = 'fee_paid'),
          'the payment is on the trail');

-- The webhook path writes only fee_status. Before the trigger existed, a
-- submission paid through the bank sat on its payment step forever while
-- one paid by hand went through.
SELECT ok((submit_form('f0000000-0000-0000-0000-000000000001', '{"trader":"Webhook Co"}'::jsonb)).current_step = 0,
          'a second submission starts at the beginning');
SELECT act_as('deputy@office.kh');
SELECT process_form_submission((SELECT id FROM form_submissions WHERE title = 'Webhook Co'), 'approve');
UPDATE form_submissions SET fee_status = 'paid' WHERE title = 'Webhook Co';   -- what the webhook does
SELECT ok((SELECT current_step FROM form_submissions WHERE title = 'Webhook Co') = 2,
          'a fee settled by the bank webhook advances the same as one settled by hand');

SELECT act_as('director@office.kh');
SELECT raises($$SELECT process_form_submission(
    (SELECT id FROM form_submissions WHERE title = 'Sok Trading'), 'approve')$$,
              'the director''s roles do not open a step reserved for the manager');

SELECT act_as('manager@office.kh');
SELECT ok((process_form_submission(
             (SELECT id FROM form_submissions WHERE title = 'Sok Trading'), 'approve')).status = 'completed',
          'the manager takes the last step and the submission completes');
SELECT raises($$SELECT process_form_submission(
    (SELECT id FROM form_submissions WHERE title = 'Sok Trading'), 'reject')$$,
              'a completed submission cannot then be rejected');

SELECT act_as('clerk@office.kh');
SELECT raises($$SELECT request_fee('employees', (SELECT id FROM form_submissions LIMIT 1), 10, 'USD')$$,
              'a fee cannot be requested against an arbitrary table');
SELECT raises($$SELECT request_fee('form_submissions', (SELECT id FROM form_submissions LIMIT 1), 0, 'USD')$$,
              'a fee of zero is refused');

\echo '== 12. one inbox'

-- Sitting on w1 (Reception), submitted by the clerk.
SELECT ok((submit_form('f0000000-0000-0000-0000-000000000001', '{"trader":"Inbox Test"}'::jsonb)).current_step = 0,
          'a fresh submission waits on Reception');

SELECT act_as('deputy@office.kh');
SELECT ok(EXISTS (SELECT 1 FROM my_action_inbox()
                   WHERE out_kind = 'form' AND out_title = 'Inbox Test'),
          'the deputy sees the form waiting on their role');

SELECT act_as('clerk@office.kh');
SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox()
                       WHERE out_kind = 'form' AND out_title = 'Inbox Test'),
          'the person who submitted it does not see it as theirs to approve');

SELECT act_as('manager@office.kh');
SELECT ok(EXISTS (SELECT 1 FROM my_action_inbox()
                   WHERE out_kind = 'document' AND out_title = 'Overdue circular' AND out_overdue),
          'the manager''s overdue incoming letter is in the same inbox as the forms');
SELECT ok((SELECT out_overdue FROM my_action_inbox() LIMIT 1) = true,
          'and the most overdue item is at the top');
SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox() WHERE out_title = 'Request for staffing figures'),
          'a closed file has left the inbox');
SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox() WHERE out_title = 'Reply on staffing figures'),
          'and so has a voided one');

SELECT act_as('nobody@elsewhere.kh');
SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox()),
          'somebody who is not an employee has an empty inbox, not an error');

\echo '== 13. routing: conditions, quorum and copies for information'

-- The rule staff used to carry in their heads: anything over five hundred
-- also goes to the director.
INSERT INTO document_templates (id, name, content, workflow, fields)
VALUES ('d1000000-0000-0000-0000-000000000003', 'Expense claim', '<p>claim</p>',
        '[{"id":"e1","name":"Accountant check","type":"approval","order":1,"allowedRoles":["Accountant"],"cc":["Reception"]},
          {"id":"e2","name":"Director sign-off","type":"approval","order":2,"allowedRoles":["Director"],
           "when":{"field":"totalAmount","op":">","value":500}}]'::jsonb,
        '[{"key":"totalAmount","label":"Total","type":"number","required":true}]'::jsonb);

INSERT INTO employees (id, user_id, name, email, roles)
VALUES ('d0000000-0000-0000-0000-00000000000f', 'e0000000-0000-0000-0000-00000000000f',
        'Mony (accountant)', 'acct@office.kh', ARRAY['Accountant'])
ON CONFLICT DO NOTHING;

SELECT ok(step_applies('{"name":"x"}'::jsonb, '{}'::jsonb),
          'a step with no condition always applies');
SELECT ok(step_applies('{"when":{"field":"a","op":">","value":500}}'::jsonb, '{"a":"600"}'::jsonb),
          '600 is over the 500 threshold');
SELECT ok(NOT step_applies('{"when":{"field":"a","op":">","value":500}}'::jsonb, '{"a":"400"}'::jsonb),
          '400 is not');
SELECT ok(NOT step_applies('{"when":{"field":"a","op":">","value":500}}'::jsonb, '{}'::jsonb),
          'an unanswered field satisfies nothing — a blank is not a zero');
SELECT ok(step_applies('{"when":{"field":"k","op":"in","value":["a","b"]}}'::jsonb, '{"k":"b"}'::jsonb),
          'an "in" list matches one of its values');
SELECT ok(step_applies('{"when":{"field":"k","op":"not_empty"}}'::jsonb, '{"k":"x"}'::jsonb),
          'not_empty sees an answer');
SELECT raises($$SELECT step_applies('{"name":"Bad","when":{"field":"a","op":"roughly","value":1}}'::jsonb, '{"a":"1"}'::jsonb)$$,
              'an operator this system does not know is an error, not a silent yes');
SELECT raises($$SELECT step_applies('{"name":"Bad","when":{"field":"a","op":">","value":500}}'::jsonb, '{"a":"lots"}'::jsonb)$$,
              'comparing text as a number is an error, not a silent no');

SELECT act_as('clerk@office.kh');
SELECT ok((register_document('internal', 'Small claim',
             p_template_id  => 'd1000000-0000-0000-0000-000000000003',
             p_field_values => '{"totalAmount":"120"}'::jsonb)).current_step_id = 'e1',
          'a small claim starts at the accountant');
SELECT ok((register_document('internal', 'Large claim',
             p_template_id  => 'd1000000-0000-0000-0000-000000000003',
             p_field_values => '{"totalAmount":"900"}'::jsonb)).current_step_id = 'e1',
          'so does a large one');

SELECT act_as('admin@office.kh');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Small claim'), 'approve')).status = 'approved',
          'the small claim finishes at the accountant — the director step does not apply to it');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Large claim'), 'approve')).current_step_id = 'e2',
          'the large one goes on to the director, without anybody remembering to send it');

SELECT act_as('director@office.kh');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Large claim'), 'approve')).status = 'approved',
          'and the director closes it');

-- Two of them have to sign.
INSERT INTO document_templates (id, name, content, workflow)
VALUES ('d1000000-0000-0000-0000-000000000004', 'Board resolution', '<p>resolution</p>',
        '[{"id":"b1","name":"Two signatures","type":"approval","order":1,
           "allowedRoles":["Manager","Director","Accountant"],"quorum":2}]'::jsonb);

SELECT act_as('clerk@office.kh');
SELECT (register_document('internal', 'Resolution 1',
          p_template_id => 'd1000000-0000-0000-0000-000000000004')).id;

SELECT act_as('manager@office.kh');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Resolution 1'),
                            'approve', 'Agreed')).status = 'pending',
          'one signature of two does not clear the step');
SELECT ok((SELECT out_given FROM document_step_progress(
             (SELECT id FROM document_requests WHERE title = 'Resolution 1'))) = 1,
          'and the progress says one of two');
SELECT ok((SELECT out_signers FROM document_step_progress(
             (SELECT id FROM document_requests WHERE title = 'Resolution 1'))) = 'Sopheak (manager)',
          'naming who actually signed, not just how many');
SELECT raises($$SELECT process_document(
    (SELECT id FROM document_requests WHERE title = 'Resolution 1'), 'approve')$$,
              'the same person cannot sign twice to make up the number');

SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox() WHERE out_title = 'Resolution 1'),
          'and it leaves the inbox of somebody who has already signed');
SELECT act_as('director@office.kh');
SELECT ok(EXISTS (SELECT 1 FROM my_action_inbox() WHERE out_title = 'Resolution 1'),
          'while still waiting on everybody who has not');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Resolution 1'),
                            'approve')).status = 'approved',
          'the second signature clears the step and the resolution passes');

-- A returned file loses its partial signatures: they were given against a
-- version that is about to change.
SELECT act_as('clerk@office.kh');
SELECT (register_document('internal', 'Resolution 2',
          p_template_id => 'd1000000-0000-0000-0000-000000000004')).id;
SELECT act_as('manager@office.kh');
SELECT process_document((SELECT id FROM document_requests WHERE title = 'Resolution 2'), 'approve');
SELECT process_document((SELECT id FROM document_requests WHERE title = 'Resolution 2'), 'return', 'Wrong figures');
SELECT ok((SELECT out_given FROM document_step_progress(
             (SELECT id FROM document_requests WHERE title = 'Resolution 2'))) = 0,
          'returning the file clears the signatures already on that step');
SELECT act_as('clerk@office.kh');
SELECT ok((process_document((SELECT id FROM document_requests WHERE title = 'Resolution 2'),
                            'resubmit')).current_step_id = 'b1',
          'and a resubmitted file starts the step over rather than arriving pre-signed');

-- Copied in for information: may read, never asked to act.
SELECT act_as('clerk@office.kh');
SELECT ok(document_cc_open_to_me((SELECT id FROM document_requests WHERE title = 'Large claim')),
          'a Reception role copied in on a step can read the file');
SELECT ok(NOT EXISTS (SELECT 1 FROM my_action_inbox() WHERE out_title = 'Large claim'),
          'and is never asked to action it');
SELECT act_as('director@office.kh');
SELECT ok(NOT document_cc_open_to_me((SELECT id FROM document_requests WHERE title = 'Resolution 1')),
          'a workflow that copies nobody in opens nothing');

\echo ''
\echo 'ALL DOCUMENT REGISTER ASSERTIONS PASSED'
