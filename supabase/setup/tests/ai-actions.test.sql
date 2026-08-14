-- =====================================================================
-- DEFERRED APPROVAL — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The assistant may propose a write. That is all it may do.
--
-- QUEUEING CHANGES NOTHING. The document is exactly where it was.
--
-- APPROVING GRANTS NOTHING. Every queued action is replayed through the
-- same RPC the screen calls, as the person who approved it. If they could
-- not press the button by hand — their own request, the wrong role — the
-- queue refuses in the same words. This is the assertion the whole design
-- exists to make true, and several below attack it directly.
--
-- ORDER IS NOT ADVISORY. Nothing applies over the top of a pending
-- decision that came first, whether by a standing rule or by somebody
-- clicking the second item in the list.
--
-- ONLY WHAT CAN BE UNDONE MAY SKIP THE ASKING, and asking for more is
-- refused out loud rather than accepted and ignored.
--
-- A FAILURE STOPS THE QUEUE and keeps the database's own sentence.
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

CREATE OR REPLACE FUNCTION nobody() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{}', false);
  PERFORM set_config('request.jwt.claim.sub', '', false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('a0000000-0000-0000-0000-00000000000a', 'clerk@office.kh'),
  ('a0000000-0000-0000-0000-00000000000b', 'manager@office.kh'),
  ('a0000000-0000-0000-0000-00000000000c', 'director@office.kh'),
  ('a0000000-0000-0000-0000-00000000000d', 'owner@office.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('b0000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-00000000000a', 'Chanthou', 'clerk@office.kh',    ARRAY['Reception']),
  ('b0000000-0000-0000-0000-00000000000b', 'a0000000-0000-0000-0000-00000000000b', 'Sopheak',  'manager@office.kh',  ARRAY['Manager']),
  ('b0000000-0000-0000-0000-00000000000c', 'a0000000-0000-0000-0000-00000000000c', 'Rithy',    'director@office.kh', ARRAY['Director']),
  ('b0000000-0000-0000-0000-00000000000d', 'a0000000-0000-0000-0000-00000000000d', 'Sokha',    'owner@office.kh',    ARRAY['Admin'])
ON CONFLICT DO NOTHING;

INSERT INTO document_templates (id, name, content, workflow)
VALUES ('c0000000-0000-0000-0000-000000000001', 'Leave Request', '<p>Leave</p>',
        '[{"id":"s1","name":"Manager review","type":"approval","order":1,"allowedRoles":["Manager"]},
          {"id":"s2","name":"Director sign-off","type":"approval","order":2,"allowedRoles":["Director"]}]'::jsonb);

SELECT act_as('clerk@office.kh');
SELECT register_document('internal', 'Leave — Chanthou',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');
SELECT register_document('internal', 'Leave — second request',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');


\echo '== 1. only an employee may propose anything'

SELECT nobody();
SELECT raises($$SELECT ai_queue_action('process_document_request', '{}'::jsonb)$$,
              'somebody with no employee record cannot queue an action');

SELECT act_as('manager@office.kh');
SELECT raises($$SELECT ai_queue_action('drop_everything', '{"x":1}'::jsonb)$$,
              'a tool the database has never heard of is refused at queue time');
SELECT raises($$SELECT ai_queue_action('process_document_request',
                 jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                                    'action', 'shred'))$$,
              'an action that is not part of the workflow is refused');
SELECT raises($$SELECT ai_queue_action('process_document_request',
                 '{"document_id":"00000000-0000-0000-0000-000000000000","action":"approve"}'::jsonb)$$,
              'a document that does not exist is refused rather than queued for later discovery');


\echo '== 2. queueing does not do it'

SELECT act_as('manager@office.kh');
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                                'action', 'approve', 'comment', 'Looks fine'))) = 'pending',
          'an approval the assistant proposes comes back pending, not done');

SELECT ok((SELECT current_step_id FROM document_requests WHERE title = 'Leave — Chanthou') = 's1',
          'and the document has not moved one step');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 1,
          'there is exactly one thing waiting');
SELECT ok((SELECT kind FROM ai_actions ORDER BY id DESC LIMIT 1) = 'document.approve',
          'it is recorded as the kind of act it is, not just a tool name');
SELECT ok((SELECT title FROM ai_actions ORDER BY id DESC LIMIT 1) LIKE '%Leave — Chanthou%',
          'the title names the actual document, so the decision can be made from the list');
SELECT ok((SELECT auto_approvable FROM ai_actions ORDER BY id DESC LIMIT 1) = false,
          'approving a document is never eligible to skip the asking');


\echo '== 3. the queue is personal — you decide what you proposed'

-- A queue belongs to the person who was talking to the assistant. Somebody
-- else's proposal is not theirs to decide, and an owner is the only exception.
SELECT act_as('director@office.kh');
SELECT raises($$SELECT ai_approve_action(
    (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b' ORDER BY id LIMIT 1))$$,
              'a colleague cannot decide somebody else''s proposal');
SELECT raises($$SELECT ai_reject_action(
    (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b' ORDER BY id LIMIT 1))$$,
              'nor throw it away');


\echo '== 4. approving grants nothing that pressing the button would not'

-- The clerk raised this leave request. process_document() refuses people
-- acting on their own, and it must refuse here in exactly the same words.
SELECT act_as('clerk@office.kh');
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                            'action', 'approve'));
SELECT ok((SELECT out_ok FROM ai_approve_action(
             (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000a'
               AND state = 'pending' ORDER BY id LIMIT 1))) = false,
          'the requester cannot approve their own request through the queue either');
SELECT ok((SELECT error FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000a'
            ORDER BY id LIMIT 1) IS NOT NULL,
          'and the database''s own sentence about why is kept');
SELECT ok((SELECT attempts FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000a'
            ORDER BY id LIMIT 1) = 1,
          'the attempt is counted');
SELECT ok((SELECT current_step_id FROM document_requests WHERE title = 'Leave — Chanthou') = 's1',
          'the document has not moved');
SELECT ai_reject_action((SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000a'
                          AND state = 'pending' ORDER BY id LIMIT 1), 'The assistant proposed what I cannot do');

-- The director holds Director, but step 1 wants Manager.
SELECT act_as('director@office.kh');
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                            'action', 'approve'));
SELECT ok((SELECT out_ok FROM ai_approve_action(
             (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000c'
               AND state = 'pending' ORDER BY id LIMIT 1))) = false,
          'somebody without the role for the current step is refused as well');
SELECT ai_reject_action((SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000c'
                          AND state = 'pending' ORDER BY id LIMIT 1), 'not mine to take');

-- The manager can, because the manager could by hand.
SELECT act_as('manager@office.kh');
SELECT ok((SELECT out_ok FROM ai_approve_action(
             (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b'
               AND state = 'pending' ORDER BY id LIMIT 1))) = true,
          'the person the workflow actually allows can approve it');
SELECT ok((SELECT current_step_id FROM document_requests WHERE title = 'Leave — Chanthou') = 's2',
          'and only then does the document move');
SELECT ok((SELECT state FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b'
            ORDER BY id LIMIT 1) = 'applied',
          'the action is marked applied');
SELECT ok((SELECT result ->> 'status' FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b'
            ORDER BY id LIMIT 1) IS NOT NULL,
          'what came back is kept, so the list can show what happened');

SELECT raises($$SELECT ai_approve_action(
    (SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000b' ORDER BY id LIMIT 1))$$,
              'an applied action cannot be applied twice');

-- An owner is the exception, so nothing is ever stranded.
SELECT act_as('clerk@office.kh');
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — Chanthou'),
                            'action', 'approve'));
SELECT act_as('owner@office.kh');
SELECT ai_reject_action((SELECT id FROM ai_actions WHERE requested_by = 'a0000000-0000-0000-0000-00000000000a'
                          AND state = 'pending' ORDER BY id LIMIT 1), 'clearing a stuck proposal');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 0,
          'an owner can clear a proposal its author was never able to apply');


\echo '== 5. a decision that came first is decided first'

SELECT act_as('manager@office.kh');
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — second request'),
                            'action', 'return', 'comment', 'Dates missing'));
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — second request'),
                            'action', 'approve'));

SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 2,
          'both are waiting');

SELECT raises($$SELECT ai_approve_action((SELECT max(id) FROM ai_actions WHERE state = 'pending'))$$,
              'the second cannot be approved while the first is still waiting');

-- Clear the first, then the second becomes reachable.
SELECT ai_reject_action((SELECT min(id) FROM ai_actions WHERE state = 'pending'), 'Changed my mind');
SELECT ok((SELECT out_ok FROM ai_approve_action((SELECT min(id) FROM ai_actions WHERE state = 'pending'))) = true,
          'once the one in front is decided, the next can be');


\echo '== 6. a rejected proposal keeps its row'

SELECT ok(EXISTS (SELECT 1 FROM ai_actions WHERE state = 'rejected' AND reason = 'Changed my mind'),
          'the rejected action is still there, with the words the person used');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'rejected') = 4,
          'every proposal turned down so far is still on the record');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ai_actions' AND cmd = 'DELETE'),
          'nothing can delete from the queue — there is no policy for it');

SELECT raises($$SELECT ai_reject_action(
    (SELECT id FROM ai_actions WHERE state = 'rejected' AND reason = 'Changed my mind'))$$,
              'a rejected action cannot be rejected again');
SELECT raises($$SELECT ai_approve_action(
    (SELECT id FROM ai_actions WHERE state = 'rejected' AND reason = 'Changed my mind'))$$,
              'nor approved afterwards');


\echo '== 7. only an owner sets a standing rule, and only on what can be undone'

SELECT act_as('manager@office.kh');
SELECT raises($$SELECT ai_set_auto_approve('document.return', true)$$,
              'a manager cannot let the assistant act without being asked');

SELECT act_as('owner@office.kh');
SELECT raises($$SELECT ai_set_auto_approve('document.approve', true)$$,
              'approving a document can never be covered by a standing rule');
SELECT raises($$SELECT ai_set_auto_approve('document.reject', true)$$,
              'nor can rejecting one');
SELECT raises($$SELECT ai_set_auto_approve('invented.kind', true)$$,
              'a kind that does not exist is refused rather than stored');

SELECT ai_set_auto_approve('document.return', true, 'Returning for correction is reversible');
SELECT ok((SELECT enabled_by_name FROM ai_auto_approve WHERE kind = 'document.return') = 'Sokha',
          'the rule records who enabled it, because actions will run on their authority');
SELECT ok((SELECT auto_approve_on FROM ai_action_kinds() WHERE kind = 'document.return') = true,
          'the settings list reflects it');
SELECT ok((SELECT reversible FROM ai_action_kinds() WHERE kind = 'document.approve') = false,
          'and shows plainly that approving is not on offer');


\echo '== 8. a covered kind applies at once, and says whose authority it was'

SELECT act_as('clerk@office.kh');
SELECT register_document('internal', 'Leave — third request',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');

SELECT act_as('manager@office.kh');
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — third request'),
                                'action', 'return', 'comment', 'Needs dates'))) = 'applied',
          'a return goes through without anybody being asked');
SELECT ok((SELECT status FROM document_requests WHERE title = 'Leave — third request') = 'returned',
          'and the document really was returned');
SELECT ok((SELECT auto_approved FROM ai_actions ORDER BY id DESC LIMIT 1) = true,
          'it is marked as having skipped the asking');
SELECT ok((SELECT authority_name FROM ai_actions ORDER BY id DESC LIMIT 1) = 'Sokha',
          'and names the owner whose rule allowed it, not the assistant');
SELECT ok(EXISTS (SELECT 1 FROM audit_log
                   WHERE action = 'ai.action.auto_applied' AND detail LIKE '%Sokha%'),
          'the audit trail says the same thing');


\echo '== 9. never past a gate'

-- Queue something that needs a person, then something a rule covers. The
-- second must NOT jump the queue, because it was proposed on the assumption
-- the first had happened.
-- Two different documents, so that clearing the gate cannot be what stops the
-- one behind it — the only thing holding the second back is the first.
SELECT act_as('clerk@office.kh');
SELECT register_document('internal', 'Leave — fourth request',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');
SELECT register_document('internal', 'Leave — fourth request (b)',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');

SELECT act_as('manager@office.kh');
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — fourth request'),
                            'action', 'approve'));
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — fourth request (b)'),
                                'action', 'return', 'comment', 'Second thoughts'))) = 'pending',
          'a covered kind waits behind a decision that came first');
SELECT ok((SELECT status FROM document_requests WHERE title = 'Leave — fourth request (b)') <> 'returned',
          'and nothing at all happened to its document');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 2,
          'both are still waiting');

-- Decide the one in front; the covered one behind it then goes through.
SELECT ok((SELECT out_ok FROM ai_approve_action((SELECT min(id) FROM ai_actions WHERE state = 'pending'))) = true,
          'the gate is cleared by a person');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 0,
          'and the covered action behind it applies immediately afterwards');
SELECT ok((SELECT status FROM document_requests WHERE title = 'Leave — fourth request (b)') = 'returned',
          'only now does the second document move');


\echo '== 10. a failure stops the queue and keeps the sentence'

SELECT act_as('clerk@office.kh');
SELECT register_document('internal', 'Leave — fifth request',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');

-- The clerk raised it, so the clerk's own return of it will be refused.
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — fifth request'),
                                'action', 'return'))) = 'pending',
          'a covered kind that cannot actually be applied stays pending');
SELECT ok((SELECT error FROM ai_actions ORDER BY id DESC LIMIT 1) IS NOT NULL,
          'the reason it would not go through is kept on the row');
SELECT ok((SELECT attempts FROM ai_actions ORDER BY id DESC LIMIT 1) = 1,
          'the attempt is counted');

-- And a second covered action behind the failure does not slip past it.
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — fifth request'),
                                'action', 'return', 'comment', 'again'))) = 'pending',
          'nothing behind a failure is tried');
SELECT ok((SELECT status FROM document_requests WHERE title = 'Leave — fifth request') <> 'returned',
          'and the document is untouched by either of them');

-- The clerk's queue is stuck: they proposed something they are not the one to
-- do. An owner clears it. Nothing else can, and that is the point.
SELECT act_as('owner@office.kh');
SELECT ai_reject_action((SELECT min(id) FROM ai_actions WHERE state = 'pending'), 'not yours to do');
SELECT ai_reject_action((SELECT min(id) FROM ai_actions WHERE state = 'pending'), 'nor this one');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 0,
          'an owner can unstick a queue its author could never clear');

-- The same act, proposed by somebody the workflow allows, goes through at once
-- under the standing rule. It was the person that was wrong, not the action.
SELECT act_as('manager@office.kh');
SELECT ok((SELECT out_state FROM ai_queue_action('process_document_request',
             jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — fifth request'),
                                'action', 'return', 'comment', 'dates missing'))) = 'applied',
          'the same return proposed by somebody allowed to make it applies at once');


\echo '== 11. approving a batch stops where it stops'

SELECT act_as('clerk@office.kh');
SELECT register_document('internal', 'Leave — sixth request',
                         p_template_id => 'c0000000-0000-0000-0000-000000000001');
SELECT act_as('manager@office.kh');

SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — sixth request'),
                            'action', 'approve'));
SELECT ai_queue_action('process_document_request',
         jsonb_build_object('document_id', (SELECT id FROM document_requests WHERE title = 'Leave — sixth request'),
                            'action', 'approve'));

-- The first approval clears step 1; the second wants step 2, which the manager
-- does not hold. The batch must stop there rather than carry on down the list.
SELECT ok((SELECT out_applied FROM ai_approve_actions(
             ARRAY(SELECT id FROM ai_actions WHERE state = 'pending' ORDER BY id))) = 1,
          'the batch applies what it can and stops at the first refusal');
SELECT ok((SELECT out_stopped_at FROM ai_approve_actions(ARRAY[]::bigint[])) IS NULL,
          'an empty batch is not an error');
SELECT ok((SELECT count(*) FROM ai_actions WHERE state = 'pending') = 1,
          'the one it stopped at is still waiting for somebody');


\echo '== 12. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM ai_actions_reconciliation() WHERE check_name = 'failed and blocking'),
          'a tried-and-failed action is named as blocking the queue');

-- Backdate one to make the age check fire.
UPDATE ai_actions SET created_at = now() - interval '10 days' WHERE state = 'pending';
SELECT ok(EXISTS (SELECT 1 FROM ai_actions_reconciliation() WHERE check_name = 'waiting over a week'),
          'something nobody came back to is named');

-- A rule for a kind that is no longer reversible is only reachable if the list
-- was narrowed after the fact. Simulate it directly.
INSERT INTO ai_auto_approve (kind, enabled_by, enabled_by_name)
VALUES ('document.approve', 'a0000000-0000-0000-0000-00000000000d', 'Sokha');
SELECT ok(EXISTS (SELECT 1 FROM ai_actions_reconciliation()
                   WHERE check_name = 'standing rule no longer allowed'),
          'a rule covering something irreversible is named, not silently obeyed');
DELETE FROM ai_auto_approve WHERE kind = 'document.approve';

SELECT ok((SELECT count(*) FROM ai_actions_reconciliation()) >= 2,
          'the check reports without changing anything');


\echo '== 13. the queue is not readable by everyone, and not callable by nobody'

-- Superuser bypasses RLS outright, even with FORCE, so these have to run as a
-- role that does not. act_as() reads the employee roster, so the identity is
-- set BEFORE dropping into that role.
-- The director proposed one action, back in section 4, and nothing else.
SELECT act_as('director@office.kh');
SET ROLE authenticated;
SELECT ok((SELECT count(*) FROM ai_actions) = 1
          AND NOT EXISTS (SELECT 1 FROM ai_actions
                           WHERE requested_by <> 'a0000000-0000-0000-0000-00000000000c'),
          'an employee who is not an owner sees their own proposals and nobody else''s');
RESET ROLE;

SELECT act_as('manager@office.kh');
SET ROLE authenticated;
SELECT ok((SELECT count(*) FROM ai_actions) > 1,
          'the person who asked sees all of their own');
SELECT ok(NOT EXISTS (SELECT 1 FROM ai_actions
                       WHERE requested_by <> 'a0000000-0000-0000-0000-00000000000b'),
          'and still nobody else''s');
RESET ROLE;

SELECT act_as('owner@office.kh');
SET ROLE authenticated;
SELECT ok((SELECT count(*) FROM ai_actions) > 0,
          'an owner sees all of it');

-- Rules are set through the function or not at all.
SELECT raises($$INSERT INTO ai_auto_approve (kind, enabled_by)
              VALUES ('document.resubmit', 'a0000000-0000-0000-0000-00000000000d')$$,
              'a rule cannot be inserted by hand, skipping the owner check and the audit entry');
SELECT raises($$DELETE FROM ai_actions$$,
              'and nothing in the queue can be deleted, by anybody');

RESET ROLE;

SET ROLE anon;
SELECT raises($$SELECT ai_queue_action('process_document_request', '{}'::jsonb)$$,
              'an anonymous caller cannot reach the queue at all');
SELECT raises($$SELECT ai_approve_action(1)$$,
              'nor approve anything');
SELECT raises($$SELECT ai_set_auto_approve('document.return', false)$$,
              'nor change what runs unattended');
RESET ROLE;

\echo ''
\echo 'ai-actions: done'
