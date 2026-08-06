-- =====================================================================
-- KAREYA SILO — DEFERRED APPROVAL FOR ASSISTANT ACTIONS
-- ---------------------------------------------------------------------
-- The assistant proposes; a person decides; the database performs.
--
-- THE PROBLEM THIS SOLVES IS A HUMAN ONE. An assistant that stops and
-- asks before every single write is unusable, so people switch the asking
-- off — and then it has unsupervised write access, which is worse than
-- where they started. An assistant that writes freely is unacceptable in
-- a ledger. Neither answer is any good.
--
-- So: a write is QUEUED, not performed. The assistant carries on and can
-- queue more. The person comes back — in a minute or tomorrow — and
-- approves the lot, or picks through them one at a time. Nothing has
-- happened until they do.
--
-- WHAT THIS IS NOT. It is NOT a permission system. Every queued action is
-- replayed through the same SECURITY DEFINER RPC the screens call, under
-- the JWT of whoever approves it, so that RPC's own checks apply
-- unchanged. Approving cannot make somebody able to do something they
-- could not do by hand. The queue adds a delay and a human gate; it
-- grants nothing. That is the property everything else here is arranged
-- to preserve.
--
-- WHY THE DISPATCHER IS CODE AND NOT A TABLE. It would be tidier to keep
-- "tool name → statement to run" in a table an administrator could edit.
-- That table would be an arbitrary-SQL execution surface reachable by
-- anyone who could write one row. The list of replayable actions is a
-- CASE in ai_apply_one() below, and an unknown tool is refused at the
-- moment it is queued rather than discovered at approval time.
--
-- IN ORDER, AND NEVER PAST A GATE. Actions apply oldest-first. If action
-- #5 is waiting for a person and #6 could apply on its own, #6 WAITS —
-- because #6 was very likely proposed on the assumption that #5 had
-- happened. Skipping a human gate to get at the easy item behind it is
-- exactly the failure this whole mechanism exists to prevent.
--
-- WHAT MAY SKIP THE ASKING. An owner may say "this kind of action never
-- needs my click". Only kinds that are REVERSIBLE are eligible: returning
-- a document for correction can be undone by resubmitting it, so it may
-- be a standing rule; approving or rejecting one cannot be undone, so it
-- may not — and asking for it is refused rather than quietly ignored.
-- An auto-approval is recorded with the name of whoever enabled the rule,
-- because it happened on their authority, not the assistant's.
--
-- A FAILURE STOPS THE QUEUE. If an action cannot be applied — the
-- document moved on, someone else got there first — it stays pending with
-- the database's own sentence attached, and nothing behind it is tried.
-- A queue that steps over its own failures is a queue that lies about
-- what it did.
--
-- NOTHING IS DELETED. A rejected action keeps its row. The trail of what
-- the assistant wanted to do is worth more than the tidiness.
--
-- One Silo == one business, so there is NO company_id here.
-- Fully idempotent: safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The queue
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_actions (
  id                bigint GENERATED ALWAYS AS IDENTITY,

  tool              text NOT NULL,          -- assistant tool name, e.g. process_document_request
  kind              text NOT NULL,          -- what sort of act this is, e.g. document.approve
  title             text NOT NULL,          -- one line a person can decide from
  detail            text,                   -- the fuller sentence, if there is one
  args              jsonb NOT NULL DEFAULT '{}'::jsonb,  -- exactly what will be replayed

  requested_by      uuid NOT NULL,          -- who was talking to the assistant
  requested_by_name text,

  state             text NOT NULL DEFAULT 'pending',   -- pending | applied | rejected
  auto_approvable   boolean NOT NULL DEFAULT false,    -- is this KIND reversible at all
  auto_approved     boolean NOT NULL DEFAULT false,    -- did it go through without a click
  authority_of      uuid,                   -- whose standing rule allowed that
  authority_name    text,

  resolved_by       uuid,
  resolved_by_name  text,
  resolved_at       timestamptz,
  reason            text,                   -- why it was rejected, in their words

  attempts          integer NOT NULL DEFAULT 0,
  error             text,                   -- the database's own sentence, last time it failed

  result            jsonb,                  -- what came back when it worked
  created_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ai_actions_pkey PRIMARY KEY (id),
  CONSTRAINT ai_actions_state_known CHECK (state = ANY (ARRAY['pending','applied','rejected'])),
  -- A resolved action names who resolved it and when. An unresolved one names neither.
  CONSTRAINT ai_actions_resolution_complete CHECK (
      (state = 'pending' AND resolved_at IS NULL)
   OR (state <> 'pending' AND resolved_at IS NOT NULL))
);

COMMENT ON TABLE public.ai_actions IS
 'Assistant-proposed writes awaiting a human decision. Applying one replays it '
 'through the same RPC the screens call, under the approver''s own JWT, so it '
 'can never do more than that person could do by hand.';
COMMENT ON COLUMN public.ai_actions.authority_of IS
 'For an auto-approved action: the person whose standing rule meant nobody was '
 'asked. It ran on their authority and the audit trail says so.';

CREATE INDEX IF NOT EXISTS idx_ai_actions_pending
    ON public.ai_actions (requested_by, id) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_ai_actions_created_at
    ON public.ai_actions (created_at DESC);

-- ---------------------------------------------------------------------
-- 2. Standing rules — "this kind never needs my click"
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ai_auto_approve (
  kind            text NOT NULL,
  enabled_by      uuid NOT NULL,
  enabled_by_name text,
  enabled_at      timestamptz NOT NULL DEFAULT now(),
  note            text,
  CONSTRAINT ai_auto_approve_pkey PRIMARY KEY (kind)
);

COMMENT ON TABLE public.ai_auto_approve IS
 'One row = one kind of assistant action that applies without being asked. '
 'Only reversible kinds may appear here; ai_set_auto_approve() refuses the rest. '
 'enabled_by is kept because an action that skipped the asking ran on that '
 'person''s authority.';

-- ---------------------------------------------------------------------
-- 3. What the assistant is allowed to propose
--
-- This is the whole list. A tool that is not named here cannot be queued,
-- which means it can never reach ai_apply_one() and be dispatched. Adding
-- a write tool to the assistant is therefore a deliberate edit HERE as
-- well as in the edge function — the database is not willing to replay
-- something it has never heard of.
--
-- SECURITY INVOKER on purpose. It reads document_requests to build an
-- honest title, and it must read it as the CALLER, so a title cannot be
-- lifted from a row that person is not allowed to see. If they cannot see
-- it, the lookup returns nothing and queueing is refused.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_describe_action(p_tool text, p_args jsonb)
RETURNS TABLE(kind text, title text, detail text, auto_approvable boolean)
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_action text;
  v_doc    document_requests;
BEGIN
  IF p_tool = 'process_document_request' THEN
    v_action := lower(coalesce(p_args->>'action', ''));
    IF v_action NOT IN ('approve','reject','return','resubmit') THEN
      RAISE EXCEPTION 'refused: % is not something that can be done to a document request', coalesce(p_args->>'action', '(nothing)');
    END IF;

    SELECT * INTO v_doc FROM document_requests WHERE id = (p_args->>'document_id')::uuid;
    IF v_doc.id IS NULL THEN
      RAISE EXCEPTION 'refused: no document request you can see with that id';
    END IF;

    kind  := 'document.' || v_action;
    title := CASE v_action
               WHEN 'approve'  THEN 'Approve "' || v_doc.title || '"'
               WHEN 'reject'   THEN 'Reject "' || v_doc.title || '"'
               WHEN 'return'   THEN 'Return "' || v_doc.title || '" for correction'
               WHEN 'resubmit' THEN 'Resubmit "' || v_doc.title || '"'
             END;
    detail := 'Currently ' || v_doc.status || ', at step ' || coalesce(v_doc.current_step_order, 0) || '.'
              || CASE WHEN coalesce(p_args->>'comment', '') <> ''
                      THEN ' Note: ' || (p_args->>'comment') ELSE '' END;
    -- Reversible, so a standing rule may cover it. Approve and reject are not:
    -- a document that has been approved has been approved.
    auto_approvable := v_action IN ('return', 'resubmit');
    RETURN NEXT;
    RETURN;
  END IF;

  RAISE EXCEPTION 'refused: the assistant has no action called %', p_tool;
END;
$function$;

-- ---------------------------------------------------------------------
-- 4. Doing it for real
--
-- The dispatcher. Runs as INVOKER so process_document() sees the approver
-- as the caller and applies its own rules to them — which is the point:
-- approving from this queue is exactly as powerful as pressing the button
-- on the screen, and no more.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_apply_one(p_tool text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE v_doc document_requests;
BEGIN
  IF p_tool = 'process_document_request' THEN
    v_doc := process_document(
               (p_args->>'document_id')::uuid,
               lower(p_args->>'action'),
               coalesce(p_args->>'comment', ''));
    RETURN jsonb_build_object(
      'id', v_doc.id, 'title', v_doc.title, 'status', v_doc.status,
      'current_step_order', v_doc.current_step_order);
  END IF;

  RAISE EXCEPTION 'refused: the assistant has no action called %', p_tool;
END;
$function$;

-- ---------------------------------------------------------------------
-- 5. Queueing
--
-- Called by the assistant's edge function under the JWT of whoever is
-- talking to it. Inserts, then drains: if a standing rule covers this
-- kind AND nothing is waiting in front of it, it applies at once and the
-- assistant can honestly say it is done.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_queue_action(p_tool text, p_args jsonb)
RETURNS TABLE(out_id bigint, out_state text, out_title text, out_message text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_emp  employees;
  v_desc record;
  v_id   bigint;
  v_row  ai_actions;
BEGIN
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email') LIMIT 1;
  IF v_emp.id IS NULL THEN
    RAISE EXCEPTION 'refused: only an employee can ask the assistant to do something';
  END IF;

  SELECT * INTO v_desc FROM ai_describe_action(p_tool, coalesce(p_args, '{}'::jsonb));

  INSERT INTO ai_actions (tool, kind, title, detail, args,
                          requested_by, requested_by_name, auto_approvable)
  VALUES (p_tool, v_desc.kind, v_desc.title, v_desc.detail, coalesce(p_args, '{}'::jsonb),
          auth.uid(), v_emp.name, v_desc.auto_approvable)
  RETURNING id INTO v_id;

  PERFORM ai_drain();

  SELECT * INTO v_row FROM ai_actions WHERE id = v_id;

  out_id    := v_id;
  out_state := v_row.state;
  out_title := v_row.title;
  out_message := CASE
    WHEN v_row.state = 'applied' THEN 'Done — a standing rule covers this, so nobody was asked.'
    ELSE 'Queued. It will not happen until somebody approves it.'
  END;
  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------
-- 6. The drain
--
-- Oldest first, for THIS person's queue only. Stops at the first action
-- that needs a human — it does not step over it to reach an easier one
-- behind. Stops on the first failure too, leaving the sentence that
-- caused it on the row.
--
-- One person's pending action does not block another's: the queues are
-- separate because the dependency between actions is a dependency within
-- one conversation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_drain()
RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_rec     ai_actions;
  v_rule    ai_auto_approve;
  v_result  jsonb;
  v_applied integer := 0;
BEGIN
  FOR v_rec IN
    SELECT * FROM ai_actions
     WHERE requested_by = auth.uid() AND state = 'pending'
     ORDER BY id
  LOOP
    -- Not reversible, or no standing rule for it: a human gate. Stop here.
    IF NOT v_rec.auto_approvable THEN EXIT; END IF;
    SELECT * INTO v_rule FROM ai_auto_approve WHERE kind = v_rec.kind;
    IF v_rule.kind IS NULL THEN EXIT; END IF;

    BEGIN
      v_result := ai_apply_one(v_rec.tool, v_rec.args);
    EXCEPTION WHEN others THEN
      -- Record why, leave it pending for a person, and stop. Anything behind
      -- this was very likely proposed assuming it had worked.
      UPDATE ai_actions
         SET attempts = attempts + 1, error = left(SQLERRM, 500)
       WHERE id = v_rec.id;
      RETURN v_applied;
    END;

    UPDATE ai_actions
       SET state = 'applied', result = v_result, error = NULL,
           auto_approved = true,
           authority_of = v_rule.enabled_by, authority_name = v_rule.enabled_by_name,
           resolved_by = auth.uid(), resolved_by_name = v_rec.requested_by_name,
           resolved_at = now(), attempts = attempts + 1
     WHERE id = v_rec.id;

    INSERT INTO audit_log (actor_id, actor_name, action, entity, entity_id, detail)
    VALUES (auth.uid(), v_rec.requested_by_name, 'ai.action.auto_applied', 'ai_action', v_rec.id::text,
            v_rec.title || ' — no one was asked, under a standing rule enabled by '
            || coalesce(v_rule.enabled_by_name, 'an owner'));

    v_applied := v_applied + 1;
  END LOOP;

  RETURN v_applied;
END;
$function$;

-- ---------------------------------------------------------------------
-- 7. A person decides
--
-- Approving runs the action as the approver. If they are not allowed to
-- do it — process_document() refuses people acting on their own requests,
-- and people without the role for the current step — then it refuses here
-- too, in the same words. That is the whole safety story: this queue is a
-- convenience, not a capability.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_approve_action(p_id bigint)
RETURNS TABLE(out_ok boolean, out_message text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_rec    ai_actions;
  v_result jsonb;
  v_ahead  bigint;
BEGIN
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email') LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'refused: employees only'; END IF;

  SELECT * INTO v_rec FROM ai_actions WHERE id = p_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'refused: no such action'; END IF;
  IF v_rec.state <> 'pending' THEN
    RAISE EXCEPTION 'refused: that was already %', v_rec.state;
  END IF;
  IF v_rec.requested_by <> auth.uid() AND NOT is_admin_or_founder() THEN
    RAISE EXCEPTION 'refused: only the person who asked, or an owner, can decide this';
  END IF;

  -- In order. Approving #6 while #5 is still waiting would apply it on top of
  -- a state #6 was not proposed against.
  SELECT min(id) INTO v_ahead FROM ai_actions
   WHERE requested_by = v_rec.requested_by AND state = 'pending' AND id < p_id;
  IF v_ahead IS NOT NULL THEN
    RAISE EXCEPTION 'refused: action % is still waiting and came first — decide that one before this', v_ahead;
  END IF;

  BEGIN
    v_result := ai_apply_one(v_rec.tool, v_rec.args);
  EXCEPTION WHEN others THEN
    UPDATE ai_actions SET attempts = attempts + 1, error = left(SQLERRM, 500) WHERE id = p_id;
    out_ok := false;
    out_message := left(SQLERRM, 500);
    RETURN NEXT;
    RETURN;
  END;

  UPDATE ai_actions
     SET state = 'applied', result = v_result, error = NULL,
         resolved_by = auth.uid(), resolved_by_name = v_emp.name,
         resolved_at = now(), attempts = attempts + 1
   WHERE id = p_id;

  INSERT INTO audit_log (actor_id, actor_name, action, entity, entity_id, detail)
  VALUES (auth.uid(), v_emp.name, 'ai.action.applied', 'ai_action', p_id::text,
          v_rec.title || ' — proposed by the assistant for '
          || coalesce(v_rec.requested_by_name, 'someone') || ', approved here');

  -- Whatever was queued behind this may now be eligible.
  IF v_rec.requested_by = auth.uid() THEN PERFORM ai_drain(); END IF;

  out_ok := true;
  out_message := 'Done.';
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.ai_reject_action(p_id bigint, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_emp employees;
  v_rec ai_actions;
BEGIN
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email') LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'refused: employees only'; END IF;

  SELECT * INTO v_rec FROM ai_actions WHERE id = p_id;
  IF v_rec.id IS NULL THEN RAISE EXCEPTION 'refused: no such action'; END IF;
  IF v_rec.state <> 'pending' THEN
    RAISE EXCEPTION 'refused: that was already %', v_rec.state;
  END IF;
  IF v_rec.requested_by <> auth.uid() AND NOT is_admin_or_founder() THEN
    RAISE EXCEPTION 'refused: only the person who asked, or an owner, can decide this';
  END IF;

  -- The row stays. What the assistant wanted to do is worth keeping.
  UPDATE ai_actions
     SET state = 'rejected', reason = nullif(btrim(coalesce(p_reason, '')), ''),
         resolved_by = auth.uid(), resolved_by_name = v_emp.name, resolved_at = now()
   WHERE id = p_id;

  INSERT INTO audit_log (actor_id, actor_name, action, entity, entity_id, detail)
  VALUES (auth.uid(), v_emp.name, 'ai.action.rejected', 'ai_action', p_id::text,
          v_rec.title || coalesce(' — ' || nullif(btrim(coalesce(p_reason, '')), ''), ''));
END;
$function$;

-- Approve a batch. In id order, and it stops at the first one that will not
-- apply rather than carrying on down the list — same reason as the drain.
CREATE OR REPLACE FUNCTION public.ai_approve_actions(p_ids bigint[])
RETURNS TABLE(out_applied integer, out_stopped_at bigint, out_message text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_id  bigint;
  v_res record;
  v_n   integer := 0;
BEGIN
  FOR v_id IN SELECT unnest(coalesce(p_ids, ARRAY[]::bigint[])) ORDER BY 1 LOOP
    BEGIN
      SELECT * INTO v_res FROM ai_approve_action(v_id);
    EXCEPTION WHEN others THEN
      out_applied := v_n; out_stopped_at := v_id; out_message := left(SQLERRM, 500);
      RETURN NEXT; RETURN;
    END;
    IF NOT v_res.out_ok THEN
      out_applied := v_n; out_stopped_at := v_id; out_message := v_res.out_message;
      RETURN NEXT; RETURN;
    END IF;
    v_n := v_n + 1;
  END LOOP;

  out_applied := v_n; out_stopped_at := NULL; out_message := NULL;
  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------
-- 8. Standing rules are an owner's decision
--
-- And only for kinds that can be undone. Asking for a rule on
-- document.approve is refused in plain words rather than accepted and
-- quietly ignored — an owner who believes they have turned something on
-- should be right.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_set_auto_approve(p_kind text, p_on boolean, p_note text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE v_emp employees;
BEGIN
  IF NOT is_admin_or_founder() THEN
    RAISE EXCEPTION 'refused: only an owner can let the assistant act without being asked';
  END IF;
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email') LIMIT 1;

  IF p_on THEN
    IF NOT EXISTS (SELECT 1 FROM ai_action_kinds() k WHERE k.kind = p_kind) THEN
      RAISE EXCEPTION 'refused: the assistant has no action of the kind %', p_kind;
    END IF;
    IF p_kind <> ALL (ai_reversible_kinds()) THEN
      RAISE EXCEPTION 'refused: % cannot be undone, so it always needs a person', p_kind;
    END IF;
    INSERT INTO ai_auto_approve (kind, enabled_by, enabled_by_name, note)
    VALUES (p_kind, auth.uid(), v_emp.name, nullif(btrim(coalesce(p_note, '')), ''))
    ON CONFLICT (kind) DO UPDATE
      SET enabled_by = EXCLUDED.enabled_by, enabled_by_name = EXCLUDED.enabled_by_name,
          enabled_at = now(), note = EXCLUDED.note;

    INSERT INTO audit_log (actor_id, actor_name, action, entity, entity_id, detail)
    VALUES (auth.uid(), v_emp.name, 'ai.auto_approve.enabled', 'ai_auto_approve', p_kind,
            'The assistant may now do this without being asked');
  ELSE
    DELETE FROM ai_auto_approve WHERE kind = p_kind;
    INSERT INTO audit_log (actor_id, actor_name, action, entity, entity_id, detail)
    VALUES (auth.uid(), v_emp.name, 'ai.auto_approve.disabled', 'ai_auto_approve', p_kind,
            'This will be asked about again');
  END IF;
END;
$function$;

-- The kinds a standing rule may cover. Kept as a function rather than a table
-- so that "which acts are reversible" is a decision in the schema, not a row
-- somebody can add.
CREATE OR REPLACE FUNCTION public.ai_reversible_kinds()
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT ARRAY['document.return', 'document.resubmit'];
$function$;

-- Everything the assistant can propose, and whether a rule may cover it.
-- The settings screen is built from this rather than from a hard-coded list.
CREATE OR REPLACE FUNCTION public.ai_action_kinds()
RETURNS TABLE(kind text, reversible boolean, auto_approve_on boolean, enabled_by_name text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  SELECT k.kind,
         k.kind = ANY (ai_reversible_kinds()),
         r.kind IS NOT NULL,
         r.enabled_by_name
    FROM unnest(ARRAY['document.approve','document.reject','document.return','document.resubmit']) AS k(kind)
    LEFT JOIN ai_auto_approve r ON r.kind = k.kind
   ORDER BY k.kind;
$function$;

-- ---------------------------------------------------------------------
-- 9. What needs looking at
--
-- Names drift; changes nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_actions_reconciliation()
RETURNS TABLE(check_name text, detail text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  -- Waiting a long time. Somebody queued work and never came back to it.
  SELECT 'waiting over a week'::text,
         a.title || ' — proposed by ' || coalesce(a.requested_by_name, 'someone')
         || ' on ' || to_char(a.created_at, 'YYYY-MM-DD')
    FROM ai_actions a
   WHERE a.state = 'pending' AND a.created_at < now() - interval '7 days'

  UNION ALL
  -- Tried and failed. The queue behind these is stopped until somebody acts.
  SELECT 'failed and blocking'::text,
         a.title || ' — ' || coalesce(a.error, 'no reason recorded')
    FROM ai_actions a
   WHERE a.state = 'pending' AND a.attempts > 0

  UNION ALL
  -- A rule covering something that is no longer reversible. Only reachable if
  -- ai_reversible_kinds() was narrowed after the rule was enabled.
  SELECT 'standing rule no longer allowed'::text,
         r.kind || ' — enabled by ' || coalesce(r.enabled_by_name, 'an owner')
         || ', but that act can no longer be undone'
    FROM ai_auto_approve r
   WHERE r.kind <> ALL (ai_reversible_kinds())

  UNION ALL
  -- The document moved on after the action was proposed against it. Approving
  -- now would act on a state nobody looked at.
  SELECT 'document changed since proposed'::text,
         a.title || ' — was ' || coalesce(a.detail, '') || ' now ' || d.status
    FROM (SELECT * FROM ai_actions
           WHERE state = 'pending' AND tool = 'process_document_request') a
    JOIN document_requests d ON d.id = (a.args->>'document_id')::uuid
   WHERE d.updated_at > a.created_at;
$function$;

-- ---------------------------------------------------------------------
-- 10. Who may see and touch the queue
--
-- The requester sees their own; an owner sees all — the same people who
-- may decide. Nobody deletes: a rejected proposal is part of the record of
-- what the assistant was asked to do.
-- ---------------------------------------------------------------------
ALTER TABLE public.ai_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_actions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_auto_approve ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_auto_approve FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_actions_read ON public.ai_actions;
CREATE POLICY ai_actions_read ON public.ai_actions FOR SELECT TO authenticated
  USING (requested_by = auth.uid() OR is_admin_or_founder());

DROP POLICY IF EXISTS ai_actions_insert ON public.ai_actions;
CREATE POLICY ai_actions_insert ON public.ai_actions FOR INSERT TO authenticated
  WITH CHECK (is_employee() AND requested_by = auth.uid());

DROP POLICY IF EXISTS ai_actions_update ON public.ai_actions;
CREATE POLICY ai_actions_update ON public.ai_actions FOR UPDATE TO authenticated
  USING (requested_by = auth.uid() OR is_admin_or_founder())
  WITH CHECK (requested_by = auth.uid() OR is_admin_or_founder());

-- No DELETE policy anywhere, deliberately.

DROP POLICY IF EXISTS ai_auto_approve_read ON public.ai_auto_approve;
CREATE POLICY ai_auto_approve_read ON public.ai_auto_approve FOR SELECT TO authenticated
  USING (is_employee());

-- No write policies: rules are set through ai_set_auto_approve() only, which
-- checks for an owner and records the change in the audit log. A direct INSERT
-- would skip both.

-- ---------------------------------------------------------------------
-- 11. Grants
--
-- PostgreSQL grants EXECUTE on every new function to PUBLIC, so a GRANT to
-- `authenticated` on its own restricts precisely nobody. REVOKE first,
-- every time.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.ai_describe_action(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_apply_one(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_queue_action(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_drain() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_approve_action(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_approve_actions(bigint[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_reject_action(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_set_auto_approve(text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_action_kinds() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_reversible_kinds() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ai_actions_reconciliation() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.ai_describe_action(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_reversible_kinds() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_queue_action(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_drain() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_approve_action(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_approve_actions(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_reject_action(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_set_auto_approve(text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_action_kinds() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ai_actions_reconciliation() TO authenticated;

-- ai_apply_one has to be granted as well, because ai_drain() and
-- ai_approve_action() are SECURITY INVOKER and therefore call it as whoever is
-- signed in. Reachable directly, then — and that is harmless: it is a thin
-- wrapper over process_document(), which `authenticated` may already call, and
-- which does its own checking either way. It offers no shortcut round anything.
GRANT EXECUTE ON FUNCTION public.ai_apply_one(text, jsonb) TO authenticated;

GRANT SELECT, INSERT, UPDATE ON public.ai_actions TO authenticated;
GRANT SELECT ON public.ai_auto_approve TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.ai_actions_id_seq TO authenticated;
