-- =====================================================================
-- KAREYA SILO — DOCUMENT REGISTER (document-register)
-- ---------------------------------------------------------------------
-- The Documents module could already route an INTERNALLY WRITTEN request
-- through an approval chain. That is roughly half of what a real office
-- desk does, and the missing half is where the double work comes from:
--
--  1. NO NUMBER. A document nobody can cite is a document staff keep a
--     second copy of. document_requests had no reference column at all,
--     so every office running this would also keep a paper or Excel
--     register — the exact fragmentation digitising was meant to remove.
--     Numbers are allocated atomically here, gap-free per series, and a
--     numbered document can no longer be deleted: it is VOIDED, keeping
--     its number. Same rule the GDT invoice series already follows.
--
--     The FORMAT is the operator's, not ours. prefix / width / separator
--     / yearly reset are columns, and authority_ref names the circular or
--     internal rule the operator is following. Nothing in this file
--     claims to reproduce any ministry's numbering standard.
--
--  2. NO INCOMING SIDE. Every request was internally originated. A letter
--     that ARRIVES — from a ministry, a partner, a customer — had nowhere
--     to live, no sender, no date received, no action officer, no
--     deadline. direction + correspondent + their_ref + received_at close
--     that, so one register covers both directions of the desk.
--
--  3. NOTHING WAS OWED BY ANYONE, BY ANY DATE. No action officer, no due
--     date, no ageing. "Where is that file?" was unanswerable, which is
--     the other reason a parallel notebook exists.
--
--  4. THE FILE STOPPED WHEN THE APPROVER TRAVELLED. There was no acting
--     officer. approval_delegations lets a named person hold another's
--     roles for a dated window — and only for that window.
--
--  5. EDITING A TEMPLATE RE-ROUTED WORK ALREADY IN FLIGHT. process_document
--     resolved the current step from the LIVE template, so removing a step
--     orphaned every request sitting on it (the UI still carries a
--     "Legacy" rescue badge for exactly this). Each request now carries a
--     frozen workflow_snapshot and the template version it started under.
--
--  6. ATTACHMENTS WERE ONE PASTED URL. Now real files in a private
--     bucket, many per document, hashed, versioned, with the old
--     attachment_url backfilled rather than abandoned.
--
-- Idempotent and order-independent: safe to re-run, and it does not
-- depend on any other vertical.
-- Depends on: public.document_requests, public.document_templates,
--             public.employees, public.is_employee(),
--             public.is_admin_or_founder(), public.current_employee_id().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. NUMBERING SERIES
-- The format is configuration, not a claim. An operator whose registry
-- rule says "ចេញលេខ ០០១/២៦" sets prefix/width/separator to match and
-- records the rule it came from in authority_ref.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.document_series (
  code          text NOT NULL,
  name          text NOT NULL,
  prefix        text DEFAULT '',
  suffix        text DEFAULT '',
  width         integer DEFAULT 4,          -- zero-padding of the running number
  separator     text DEFAULT '/',
  reset_yearly  boolean DEFAULT true,
  year_format   text DEFAULT 'YYYY',        -- 'YYYY' or 'YY'
  authority_ref text,                       -- the circular / internal rule this format follows
  is_active     boolean DEFAULT true,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT document_series_pkey PRIMARY KEY (code)
);

-- One counter per series per period. The counter is the series: it is
-- never reset by hand and never reused, so the register cannot show a gap
-- that nobody can account for.
CREATE TABLE IF NOT EXISTS public.document_series_counters (
  series_code text NOT NULL,
  period      text NOT NULL,                -- '2026' when reset_yearly, else 'ALL'
  last_no     bigint NOT NULL DEFAULT 0,
  CONSTRAINT document_series_counters_pkey PRIMARY KEY (series_code, period)
);

-- Three neutral starting series so the module is usable on day one. They
-- are ordinary office practice (in / out / internal), not a reproduction
-- of any published standard — an operator is expected to edit or replace
-- them, which is why authority_ref is deliberately left NULL.
INSERT INTO public.document_series (code, name, prefix, width, separator, reset_yearly)
VALUES ('IN',  'Incoming correspondence', 'IN-',  4, '/', true),
       ('OUT', 'Outgoing correspondence', 'OUT-', 4, '/', true),
       ('INT', 'Internal requests',       'INT-', 4, '/', true)
ON CONFLICT (code) DO NOTHING;

-- Allocate the next number in a series. SECURITY DEFINER because the
-- counter table is not writable by clients: a number must only ever come
-- from here.
CREATE OR REPLACE FUNCTION public.allocate_document_number(p_series_code text, p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_s      document_series;
  v_period text;
  v_year   text;
  v_no     bigint;
BEGIN
  SELECT * INTO v_s FROM document_series WHERE code = p_series_code;
  IF v_s.code IS NULL THEN
    RAISE EXCEPTION 'There is no document series "%". Create it before registering documents.', p_series_code;
  END IF;
  IF NOT v_s.is_active THEN
    RAISE EXCEPTION 'Document series "%" is closed', p_series_code;
  END IF;

  v_year   := to_char(p_on, coalesce(nullif(v_s.year_format, ''), 'YYYY'));
  v_period := CASE WHEN v_s.reset_yearly THEN v_year ELSE 'ALL' END;

  -- Serialise allocation for THIS series only. Two clerks registering in
  -- the same second must not be handed the same number.
  PERFORM pg_advisory_xact_lock(hashtext('document_series:' || p_series_code));

  INSERT INTO document_series_counters (series_code, period, last_no)
  VALUES (p_series_code, v_period, 1)
  ON CONFLICT (series_code, period)
  DO UPDATE SET last_no = document_series_counters.last_no + 1
  RETURNING last_no INTO v_no;

  RETURN coalesce(v_s.prefix, '')
      || lpad(v_no::text, greatest(coalesce(v_s.width, 4), 1), '0')
      || CASE WHEN v_s.reset_yearly THEN coalesce(v_s.separator, '/') || v_year ELSE '' END
      || coalesce(v_s.suffix, '');
END;
$function$;

-- ---------------------------------------------------------------------
-- 2. REGISTER COLUMNS
-- ---------------------------------------------------------------------
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS reference          text;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS series_code        text;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS direction          text DEFAULT 'internal';
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS correspondent_name text;   -- the person who sent it / it is addressed to
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS correspondent_org  text;   -- their ministry / company
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS their_ref          text;   -- the sender's OWN number, so a reply can cite it
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS document_date      date;   -- the date printed on the face of the document
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS received_at        date;   -- the date it physically arrived
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS action_officer_id  uuid;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS due_date           date;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS closed_at          timestamp with time zone;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS confidentiality    text DEFAULT 'normal';
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS field_values       jsonb DEFAULT '{}'::jsonb;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS template_version   integer;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS workflow_snapshot  jsonb;  -- frozen at creation; see §4
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS void_reason        text;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS voided_at          timestamp with time zone;
ALTER TABLE public.document_requests ADD COLUMN IF NOT EXISTS voided_by          uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'document_requests_direction_check') THEN
    ALTER TABLE public.document_requests
      ADD CONSTRAINT document_requests_direction_check
      CHECK (direction = ANY (ARRAY['incoming', 'outgoing', 'internal']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'document_requests_confidentiality_check') THEN
    ALTER TABLE public.document_requests
      ADD CONSTRAINT document_requests_confidentiality_check
      CHECK (confidentiality = ANY (ARRAY['normal', 'confidential', 'secret']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'document_requests_action_officer_fkey') THEN
    ALTER TABLE public.document_requests
      ADD CONSTRAINT document_requests_action_officer_fkey
      FOREIGN KEY (action_officer_id) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'document_requests_series_fkey') THEN
    ALTER TABLE public.document_requests
      ADD CONSTRAINT document_requests_series_fkey
      FOREIGN KEY (series_code) REFERENCES public.document_series(code);
  END IF;
END $$;

-- A reference identifies exactly one document, or the register is fiction.
CREATE UNIQUE INDEX IF NOT EXISTS uq_document_requests_reference
  ON public.document_requests (reference) WHERE reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_document_requests_direction ON public.document_requests (direction, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_document_requests_officer   ON public.document_requests (action_officer_id) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_document_requests_due       ON public.document_requests (due_date) WHERE closed_at IS NULL;

-- ---------------------------------------------------------------------
-- 3. ATTACHMENTS AS FILES
-- attachment_url stays as the legacy single link and is backfilled below,
-- so no existing document loses the link somebody pasted.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.document_attachments (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  document_id  uuid NOT NULL,
  file_name    text NOT NULL,
  storage_path text,                        -- object key in the document-files bucket
  external_url text,                        -- or a link, for offices still on Drive
  mime_type    text,
  size_bytes   bigint,
  sha256       text,                        -- so "is this the same paper?" is answerable
  version      integer DEFAULT 1,
  replaces_id  uuid,
  note         text,
  uploaded_by  uuid,
  uploaded_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT document_attachments_pkey PRIMARY KEY (id),
  CONSTRAINT document_attachments_document_fkey FOREIGN KEY (document_id) REFERENCES public.document_requests(id) ON DELETE CASCADE,
  CONSTRAINT document_attachments_replaces_fkey FOREIGN KEY (replaces_id) REFERENCES public.document_attachments(id) ON DELETE SET NULL,
  CONSTRAINT document_attachments_uploader_fkey FOREIGN KEY (uploaded_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT document_attachments_location_check CHECK (storage_path IS NOT NULL OR external_url IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_document_attachments_document ON public.document_attachments (document_id);

-- Private bucket. Guarded the same way kb-sources is: on a self-hosted
-- stack the storage schema does not exist yet at db-init time.
DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public)
    VALUES ('document-files', 'document-files', false)
    ON CONFLICT (id) DO NOTHING;
  END IF;
END $$;

-- Carry every previously pasted link into the attachment list. Idempotent:
-- a document that already has its legacy link recorded is skipped.
INSERT INTO public.document_attachments (document_id, file_name, external_url, note)
SELECT d.id, 'Attachment', d.attachment_url, 'Imported from the single attachment link'
  FROM public.document_requests d
 WHERE d.attachment_url IS NOT NULL
   AND d.attachment_url <> ''
   AND NOT EXISTS (
     SELECT 1 FROM public.document_attachments a
      WHERE a.document_id = d.id AND a.external_url = d.attachment_url);

-- ---------------------------------------------------------------------
-- 4. TEMPLATE VERSIONING
-- A request must be judged by the rules that were in force when it was
-- raised. Editing a template from now on bumps its version and archives
-- the new state; in-flight requests keep the workflow they started under.
-- ---------------------------------------------------------------------
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS version          integer DEFAULT 1;
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS series_code      text;
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS direction        text DEFAULT 'internal';
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS default_due_days integer;
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS fields           jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.document_templates ADD COLUMN IF NOT EXISTS is_active        boolean DEFAULT true;

UPDATE public.document_templates SET version = 1 WHERE version IS NULL;

CREATE TABLE IF NOT EXISTS public.document_template_versions (
  template_id uuid NOT NULL,
  version     integer NOT NULL,
  name        text,
  content     text,
  workflow    jsonb,
  fields      jsonb,
  created_at  timestamp with time zone DEFAULT now(),
  created_by  uuid,
  CONSTRAINT document_template_versions_pkey PRIMARY KEY (template_id, version),
  CONSTRAINT document_template_versions_template_fkey FOREIGN KEY (template_id) REFERENCES public.document_templates(id) ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION public.document_template_bump_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' AND (
       NEW.content  IS DISTINCT FROM OLD.content
    OR NEW.workflow IS DISTINCT FROM OLD.workflow
    OR NEW.fields   IS DISTINCT FROM OLD.fields
  ) THEN
    NEW.version := coalesce(OLD.version, 1) + 1;
  END IF;
  NEW.version := coalesce(NEW.version, 1);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_document_template_bump_version ON public.document_templates;
CREATE TRIGGER trg_document_template_bump_version
  BEFORE INSERT OR UPDATE ON public.document_templates
  FOR EACH ROW EXECUTE FUNCTION public.document_template_bump_version();

CREATE OR REPLACE FUNCTION public.document_template_archive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO document_template_versions (template_id, version, name, content, workflow, fields, created_by)
  VALUES (NEW.id, NEW.version, NEW.name, NEW.content, NEW.workflow, NEW.fields, current_employee_id())
  ON CONFLICT (template_id, version) DO NOTHING;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_document_template_archive ON public.document_templates;
CREATE TRIGGER trg_document_template_archive
  AFTER INSERT OR UPDATE ON public.document_templates
  FOR EACH ROW EXECUTE FUNCTION public.document_template_archive();

-- Archive whatever templates already exist, so version 1 of each is on
-- record even though it predates the trigger.
INSERT INTO public.document_template_versions (template_id, version, name, content, workflow, fields)
SELECT t.id, coalesce(t.version, 1), t.name, t.content, t.workflow, t.fields
  FROM public.document_templates t
ON CONFLICT (template_id, version) DO NOTHING;

-- Existing in-flight requests have no snapshot. Freeze them against the
-- template as it stands right now — that is the closest honest guess, and
-- it stops the next template edit from re-routing them.
UPDATE public.document_requests d
   SET workflow_snapshot = t.workflow,
       template_version  = coalesce(t.version, 1)
  FROM public.document_templates t
 WHERE d.template_id = t.id
   AND d.workflow_snapshot IS NULL;

-- ---------------------------------------------------------------------
-- 5. DELEGATION (the acting officer)
-- Roles, not individual documents: when the manager travels, the named
-- delegate holds the manager's roles for the dated window and no longer.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.approval_delegations (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  delegator_id uuid NOT NULL,
  delegate_id  uuid NOT NULL,
  from_date    date NOT NULL,
  to_date      date NOT NULL,
  reason       text,
  created_by   uuid,
  created_at   timestamp with time zone DEFAULT now(),
  CONSTRAINT approval_delegations_pkey PRIMARY KEY (id),
  CONSTRAINT approval_delegations_delegator_fkey FOREIGN KEY (delegator_id) REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT approval_delegations_delegate_fkey  FOREIGN KEY (delegate_id)  REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT approval_delegations_distinct_check CHECK (delegate_id <> delegator_id),
  CONSTRAINT approval_delegations_dates_check    CHECK (to_date >= from_date)
);
CREATE INDEX IF NOT EXISTS idx_approval_delegations_delegate ON public.approval_delegations (delegate_id, from_date, to_date);

-- Two overlapping delegations from one person would make "who is acting
-- today?" ambiguous, and an ambiguous approver is how a file goes missing.
CREATE OR REPLACE FUNCTION public.approval_delegation_no_overlap()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM approval_delegations d
     WHERE d.delegator_id = NEW.delegator_id
       AND d.id <> NEW.id
       AND daterange(d.from_date, d.to_date, '[]') && daterange(NEW.from_date, NEW.to_date, '[]')
  ) THEN
    RAISE EXCEPTION 'This person already has a delegation covering those dates. End that one first.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_approval_delegation_no_overlap ON public.approval_delegations;
CREATE TRIGGER trg_approval_delegation_no_overlap
  BEFORE INSERT OR UPDATE ON public.approval_delegations
  FOR EACH ROW EXECUTE FUNCTION public.approval_delegation_no_overlap();

-- The roles a person may act with on a given date: their own, plus those
-- of anybody who has delegated to them for that date.
CREATE OR REPLACE FUNCTION public.effective_roles(p_employee_id uuid, p_on date DEFAULT CURRENT_DATE)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((
    SELECT array_agg(DISTINCT r) FROM (
      SELECT unnest(e.roles) AS r FROM employees e WHERE e.id = p_employee_id
      UNION
      SELECT unnest(dl.roles) AS r
        FROM approval_delegations ad
        JOIN employees dl ON dl.id = ad.delegator_id
       WHERE ad.delegate_id = p_employee_id
         AND p_on BETWEEN ad.from_date AND ad.to_date
    ) s
  ), ARRAY[]::text[]);
$function$;

-- ---------------------------------------------------------------------
-- 6. REGISTERING A DOCUMENT
-- The only way a document gets a number. Handles all three directions:
-- an incoming letter (no approval chain, an action officer and a
-- deadline), an outgoing one, and an internal request that walks a
-- template workflow.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_document(
  p_direction          text,
  p_title              text,
  p_template_id        uuid DEFAULT NULL,
  p_content            text DEFAULT NULL,
  p_correspondent_name text DEFAULT NULL,
  p_correspondent_org  text DEFAULT NULL,
  p_their_ref          text DEFAULT NULL,
  p_document_date      date DEFAULT NULL,
  p_received_at        date DEFAULT NULL,
  p_action_officer     uuid DEFAULT NULL,
  p_due_date           date DEFAULT NULL,
  p_confidentiality    text DEFAULT 'normal',
  p_series_code        text DEFAULT NULL,
  p_field_values       jsonb DEFAULT '{}'::jsonb
)
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_tpl    document_templates;
  v_series text;
  v_ref    text;
  v_first  jsonb;
  v_due    date;
  v_doc    document_requests;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST
    LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  IF p_direction NOT IN ('incoming', 'outgoing', 'internal') THEN
    RAISE EXCEPTION 'Direction must be incoming, outgoing or internal';
  END IF;
  IF coalesce(trim(p_title), '') = '' THEN
    RAISE EXCEPTION 'A document needs a subject before it can be registered';
  END IF;

  IF p_template_id IS NOT NULL THEN
    SELECT * INTO v_tpl FROM document_templates WHERE id = p_template_id;
    IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'Template not found'; END IF;
    IF coalesce(v_tpl.is_active, true) = false THEN
      RAISE EXCEPTION 'Template "%" is retired and cannot be used for new requests', v_tpl.name;
    END IF;
  END IF;

  -- Series: explicit, else the template's, else the direction default.
  v_series := coalesce(p_series_code, v_tpl.series_code,
                       CASE p_direction WHEN 'incoming' THEN 'IN'
                                        WHEN 'outgoing' THEN 'OUT'
                                        ELSE 'INT' END);
  v_ref := allocate_document_number(v_series, coalesce(p_received_at, p_document_date, CURRENT_DATE));

  -- Freeze the workflow. From here the request is judged by these steps
  -- even if somebody edits the template tomorrow.
  SELECT s INTO v_first
    FROM jsonb_array_elements(coalesce(v_tpl.workflow, '[]'::jsonb)) s
   ORDER BY coalesce((s->>'order')::int, 0)
   LIMIT 1;

  v_due := coalesce(p_due_date,
                    CASE WHEN v_tpl.default_due_days IS NOT NULL
                         THEN coalesce(p_received_at, CURRENT_DATE) + v_tpl.default_due_days
                    END);

  INSERT INTO document_requests (
    template_id, requester_id, title, content, status,
    current_step_id, current_step_order,
    reference, series_code, direction,
    correspondent_name, correspondent_org, their_ref,
    document_date, received_at, action_officer_id, due_date,
    confidentiality, field_values, template_version, workflow_snapshot,
    history
  ) VALUES (
    p_template_id, v_emp.id, p_title, coalesce(p_content, v_tpl.content), 'pending',
    v_first->>'id', coalesce((v_first->>'order')::int, 0),
    v_ref, v_series, p_direction,
    p_correspondent_name, p_correspondent_org, p_their_ref,
    p_document_date, coalesce(p_received_at, CASE WHEN p_direction = 'incoming' THEN CURRENT_DATE END),
    p_action_officer, v_due,
    coalesce(p_confidentiality, 'normal'), coalesce(p_field_values, '{}'::jsonb),
    v_tpl.version, coalesce(v_tpl.workflow, '[]'::jsonb),
    jsonb_build_array(jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', 'created',
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', 'Registered as ' || v_ref
    ))
  )
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.register_document(text, text, uuid, text, text, text, text, date, date, uuid, date, text, text, jsonb) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ASSIGN / CLOSE / VOID
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assign_document(p_doc_id uuid, p_officer uuid, p_due date DEFAULT NULL, p_note text DEFAULT '')
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_off employees; v_doc document_requests;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;
  IF v_doc.status = 'void' THEN RAISE EXCEPTION 'This document is void'; END IF;

  IF p_officer IS NOT NULL THEN
    SELECT * INTO v_off FROM employees WHERE id = p_officer;
    IF v_off.id IS NULL THEN RAISE EXCEPTION 'That person is not an employee of this workspace'; END IF;
  END IF;

  UPDATE document_requests SET
    action_officer_id = p_officer,
    due_date  = coalesce(p_due, due_date),
    updated_at = now(),
    history = coalesce(history, '[]'::jsonb) || jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', 'assigned',
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', coalesce(nullif(p_note, ''), 'Assigned to ' || coalesce(v_off.name, 'nobody'))
    )
  WHERE id = p_doc_id
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.assign_document(uuid, uuid, date, text) TO authenticated;

-- Close an item that is finished as a matter of record — the normal end
-- of an incoming letter that has been actioned. Distinct from 'approved',
-- which means an approval chain reached its last step.
CREATE OR REPLACE FUNCTION public.close_document(p_doc_id uuid, p_note text DEFAULT '')
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_doc document_requests; v_priv boolean;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  v_priv := EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder'));

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;
  IF v_doc.status = 'void' THEN RAISE EXCEPTION 'This document is void'; END IF;
  IF v_doc.closed_at IS NOT NULL THEN RAISE EXCEPTION 'This document is already closed'; END IF;

  -- Only the person carrying it, the one who registered it, or an admin.
  IF NOT v_priv
     AND v_doc.action_officer_id IS DISTINCT FROM v_emp.id
     AND v_doc.requester_id      IS DISTINCT FROM v_emp.id THEN
    RAISE EXCEPTION 'Only the action officer may close this document';
  END IF;

  -- A request still mid-approval must not be closed out from under its
  -- approvers; it has to be approved, rejected or returned.
  IF v_doc.status = 'pending' AND v_doc.current_step_id IS NOT NULL THEN
    RAISE EXCEPTION 'This request is still waiting on an approval step. Action the step instead of closing it.';
  END IF;

  UPDATE document_requests SET
    status = CASE WHEN status = 'pending' THEN 'closed' ELSE status END,
    closed_at = now(),
    updated_at = now(),
    history = coalesce(history, '[]'::jsonb) || jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', 'closed',
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', coalesce(p_note, '')
    )
  WHERE id = p_doc_id
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.close_document(uuid, text) TO authenticated;

-- Voiding keeps the number in the series. That is the whole point: a
-- register with a missing number is a register nobody trusts.
CREATE OR REPLACE FUNCTION public.void_document(p_doc_id uuid, p_reason text)
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_doc document_requests;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder')) THEN
    RAISE EXCEPTION 'Only an administrator may void a registered document';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a registered document requires a reason';
  END IF;

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;
  IF v_doc.status = 'void' THEN RAISE EXCEPTION 'This document is already void'; END IF;

  UPDATE document_requests SET
    status = 'void',
    void_reason = p_reason,
    voided_at = now(),
    voided_by = v_emp.id,
    closed_at = coalesce(closed_at, now()),
    current_step_id = NULL,
    updated_at = now(),
    history = coalesce(history, '[]'::jsonb) || jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', 'void',
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', p_reason
    )
  WHERE id = p_doc_id
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.void_document(uuid, text) TO authenticated;

-- A numbered document cannot be deleted from any client. This is a
-- trigger and not a UI rule, because a UI rule is not an audit trail.
CREATE OR REPLACE FUNCTION public.document_no_delete_when_numbered()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.reference IS NOT NULL THEN
    RAISE EXCEPTION 'Document % is in the register and cannot be deleted. Void it instead, so its number stays accounted for.', OLD.reference;
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_document_no_delete_when_numbered ON public.document_requests;
CREATE TRIGGER trg_document_no_delete_when_numbered
  BEFORE DELETE ON public.document_requests
  FOR EACH ROW EXECUTE FUNCTION public.document_no_delete_when_numbered();

-- ---------------------------------------------------------------------
-- 8. THE APPROVAL ENGINE, REVISED
-- Same guarantees as before — employee, role on the CURRENT step,
-- separation of duties, resubmit by the requester — with three changes:
--   * steps come from the request's frozen snapshot, not the live template
--   * an acting delegate may act with the roles delegated to them
--   * reaching the end of the chain closes the item, so the register can
--     tell an open file from a finished one
-- The admin rescue path deliberately does NOT extend through delegation:
-- it is a hatch for stuck files, not a routine act to hand around.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_document(p_doc_id uuid, p_action text, p_comment text DEFAULT '')
 RETURNS public.document_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp      employees;
  v_doc      document_requests;
  v_tpl      document_templates;
  v_flow     jsonb;
  v_cur      jsonb;
  v_next     jsonb;
  v_allowed  text[];
  v_roles    text[];
  v_priv     boolean;
  v_status   text;
  v_next_id  text;
  v_next_ord integer;
  v_close    timestamp with time zone;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST
    LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  v_priv  := EXISTS (SELECT 1 FROM unnest(v_emp.roles) r WHERE lower(r) IN ('admin', 'founder'));
  v_roles := effective_roles(v_emp.id, CURRENT_DATE);

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id FOR UPDATE;
  IF v_doc.id IS NULL THEN RAISE EXCEPTION 'Document not found'; END IF;
  IF v_doc.status = 'void' THEN RAISE EXCEPTION 'This document is void'; END IF;

  SELECT * INTO v_tpl FROM document_templates WHERE id = v_doc.template_id;

  -- The steps this request was raised under. Falls back to the live
  -- template only for rows registered before snapshots existed.
  v_flow := coalesce(v_doc.workflow_snapshot, v_tpl.workflow, '[]'::jsonb);

  IF v_doc.current_step_id IS NOT NULL THEN
    SELECT s INTO v_cur FROM jsonb_array_elements(v_flow) s
      WHERE s->>'id' = v_doc.current_step_id LIMIT 1;
  END IF;

  IF p_action IN ('approve', 'reject', 'return') THEN
    IF v_doc.status <> 'pending' THEN RAISE EXCEPTION 'Document is not awaiting approval'; END IF;
    IF v_cur IS NULL THEN
      IF NOT v_priv THEN RAISE EXCEPTION 'No current step to act on'; END IF;
    ELSE
      IF v_doc.requester_id = v_emp.id THEN RAISE EXCEPTION 'You cannot action your own request'; END IF;
      v_allowed := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_cur->'allowedRoles', '[]'::jsonb)));
      IF NOT v_priv AND NOT EXISTS (
        SELECT 1 FROM unnest(v_emp.roles) er JOIN unnest(v_allowed) ar ON lower(er) = lower(ar)
      ) AND NOT EXISTS (
        SELECT 1 FROM unnest(v_roles) er JOIN unnest(v_allowed) ar ON lower(er) = lower(ar)
      ) THEN
        RAISE EXCEPTION 'Your role is not authorized to approve this step';
      END IF;
    END IF;
  ELSIF p_action = 'resubmit' THEN
    IF v_doc.requester_id <> v_emp.id AND NOT v_priv THEN RAISE EXCEPTION 'Only the requester may resubmit'; END IF;
    IF v_doc.status NOT IN ('returned', 'rejected') THEN RAISE EXCEPTION 'Only returned or rejected requests can be resubmitted'; END IF;
  ELSE
    RAISE EXCEPTION 'Unknown action: %', p_action;
  END IF;

  IF p_action = 'approve' THEN
    SELECT s INTO v_next FROM jsonb_array_elements(v_flow) s
      WHERE (s->>'order')::int > coalesce(v_doc.current_step_order, 0)
      ORDER BY (s->>'order')::int LIMIT 1;
    IF v_next IS NULL THEN
      v_status := 'approved'; v_next_id := NULL; v_next_ord := 0; v_close := now();
    ELSE
      v_status := 'pending'; v_next_id := v_next->>'id'; v_next_ord := (v_next->>'order')::int;
    END IF;
  ELSIF p_action = 'reject' THEN
    v_status := 'rejected'; v_next_id := NULL; v_next_ord := v_doc.current_step_order; v_close := now();
  ELSIF p_action = 'return' THEN
    v_status := 'returned'; v_next_id := v_doc.current_step_id; v_next_ord := v_doc.current_step_order;
  ELSE -- resubmit
    SELECT s INTO v_next FROM jsonb_array_elements(v_flow) s
      ORDER BY (s->>'order')::int LIMIT 1;
    v_status := 'pending'; v_next_id := v_next->>'id'; v_next_ord := coalesce((v_next->>'order')::int, 0);
  END IF;

  UPDATE document_requests SET
    status = v_status,
    current_step_id = v_next_id,
    current_step_order = v_next_ord,
    closed_at = CASE WHEN p_action = 'resubmit' THEN NULL ELSE coalesce(v_close, closed_at) END,
    updated_at = now(),
    history = coalesce(history, '[]'::jsonb) || jsonb_build_object(
      'id', 'hist_' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
      'action', p_action,
      'actorId', v_emp.id,
      'actorName', v_emp.name,
      'stepName', coalesce(v_cur->>'name', ''),
      'timestamp', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'comment', coalesce(p_comment, '')
    )
  WHERE id = p_doc_id
  RETURNING * INTO v_doc;

  RETURN v_doc;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_document(uuid, text, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 9. THE REGISTER ITSELF, AND WHO IS CARRYING WHAT
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.document_register(date, date, text);
CREATE OR REPLACE FUNCTION public.document_register(
  p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_direction text DEFAULT NULL)
 RETURNS TABLE (
   out_id                 uuid,
   out_reference          text,
   out_direction          text,
   out_title              text,
   out_correspondent      text,
   out_their_ref          text,
   out_document_date      date,
   out_registered_on      date,
   out_officer            text,
   out_due_date           date,
   out_status             text,
   out_days_open          integer,
   out_overdue            boolean,
   out_attachment_count   bigint
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT d.id,
         d.reference,
         coalesce(d.direction, 'internal'),
         d.title,
         nullif(trim(coalesce(d.correspondent_name, '') || CASE WHEN d.correspondent_org IS NOT NULL
                THEN ' (' || d.correspondent_org || ')' ELSE '' END), ''),
         d.their_ref,
         d.document_date,
         coalesce(d.received_at, d.created_at::date),
         e.name,
         d.due_date,
         d.status,
         GREATEST(0, (coalesce(d.closed_at, now())::date - coalesce(d.received_at, d.created_at::date)))::integer,
         (d.closed_at IS NULL AND d.due_date IS NOT NULL AND d.due_date < CURRENT_DATE),
         (SELECT count(*) FROM document_attachments a WHERE a.document_id = d.id)
    FROM document_requests d
    LEFT JOIN employees e ON e.id = d.action_officer_id
   WHERE (p_from IS NULL OR coalesce(d.received_at, d.created_at::date) >= p_from)
     AND (p_to   IS NULL OR coalesce(d.received_at, d.created_at::date) <= p_to)
     AND (p_direction IS NULL OR coalesce(d.direction, 'internal') = p_direction)
   ORDER BY coalesce(d.received_at, d.created_at::date) DESC, d.reference DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.document_register(date, date, text) TO authenticated;

-- Who is holding how many, and how many of those are late. The answer to
-- "where is that file?" without walking the corridor.
DROP FUNCTION IF EXISTS public.document_workload();
CREATE OR REPLACE FUNCTION public.document_workload()
 RETURNS TABLE (
   out_officer_id uuid,
   out_officer    text,
   out_open       bigint,
   out_overdue    bigint,
   out_oldest_days integer
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT d.action_officer_id,
         coalesce(e.name, 'Unassigned'),
         count(*),
         count(*) FILTER (WHERE d.due_date IS NOT NULL AND d.due_date < CURRENT_DATE),
         max(CURRENT_DATE - coalesce(d.received_at, d.created_at::date))::integer
    FROM document_requests d
    LEFT JOIN employees e ON e.id = d.action_officer_id
   WHERE d.closed_at IS NULL
     AND coalesce(d.status, 'pending') NOT IN ('void', 'rejected')
   GROUP BY d.action_officer_id, e.name
   ORDER BY count(*) FILTER (WHERE d.due_date IS NOT NULL AND d.due_date < CURRENT_DATE) DESC, count(*) DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.document_workload() TO authenticated;

-- ---------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY
-- The base policy let every employee read every document request. That
-- was tolerable when everything was a leave form; it is not once the
-- register holds incoming correspondence. Confidential and secret items
-- are visible only to the people actually involved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.document_step_open_to_me(p_doc_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp uuid; v_doc document_requests; v_flow jsonb; v_cur jsonb; v_allowed text[]; v_roles text[];
BEGIN
  v_emp := current_employee_id();
  IF v_emp IS NULL THEN RETURN false; END IF;

  SELECT * INTO v_doc FROM document_requests WHERE id = p_doc_id;
  IF v_doc.id IS NULL OR v_doc.current_step_id IS NULL THEN RETURN false; END IF;

  SELECT coalesce(v_doc.workflow_snapshot, t.workflow, '[]'::jsonb) INTO v_flow
    FROM document_templates t WHERE t.id = v_doc.template_id;
  v_flow := coalesce(v_flow, v_doc.workflow_snapshot, '[]'::jsonb);

  SELECT s INTO v_cur FROM jsonb_array_elements(v_flow) s WHERE s->>'id' = v_doc.current_step_id LIMIT 1;
  IF v_cur IS NULL THEN RETURN false; END IF;

  v_allowed := ARRAY(SELECT jsonb_array_elements_text(coalesce(v_cur->'allowedRoles', '[]'::jsonb)));
  v_roles   := effective_roles(v_emp, CURRENT_DATE);
  RETURN EXISTS (SELECT 1 FROM unnest(v_roles) er JOIN unnest(v_allowed) ar ON lower(er) = lower(ar));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.document_step_open_to_me(uuid) TO authenticated;

DROP POLICY IF EXISTS "View documents" ON public.document_requests;
CREATE POLICY "View documents" ON public.document_requests
  FOR SELECT TO authenticated
  USING (
    public.is_employee() AND (
      coalesce(confidentiality, 'normal') = 'normal'
      OR public.is_admin_or_founder()
      OR requester_id      = public.current_employee_id()
      OR action_officer_id = public.current_employee_id()
      OR public.document_step_open_to_me(id)
    )
  );

ALTER TABLE public.document_series          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_series_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_attachments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_template_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_delegations     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS document_series_read ON public.document_series;
CREATE POLICY document_series_read ON public.document_series
  FOR SELECT TO authenticated USING (public.is_employee());
DROP POLICY IF EXISTS document_series_write ON public.document_series;
CREATE POLICY document_series_write ON public.document_series
  FOR ALL TO authenticated USING (public.is_admin_or_founder()) WITH CHECK (public.is_admin_or_founder());

-- Counters are readable (so the register can show where a series stands)
-- and writable by nobody. allocate_document_number() is the only way a
-- number moves, which is what makes the series gap-free.
DROP POLICY IF EXISTS document_series_counters_read ON public.document_series_counters;
CREATE POLICY document_series_counters_read ON public.document_series_counters
  FOR SELECT TO authenticated USING (public.is_employee());

DROP POLICY IF EXISTS document_attachments_read ON public.document_attachments;
CREATE POLICY document_attachments_read ON public.document_attachments
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.document_requests d WHERE d.id = document_id));
DROP POLICY IF EXISTS document_attachments_add ON public.document_attachments;
CREATE POLICY document_attachments_add ON public.document_attachments
  FOR INSERT TO authenticated WITH CHECK (public.is_employee());
DROP POLICY IF EXISTS document_attachments_remove ON public.document_attachments;
CREATE POLICY document_attachments_remove ON public.document_attachments
  FOR DELETE TO authenticated
  USING (uploaded_by = public.current_employee_id() OR public.is_admin_or_founder());

DROP POLICY IF EXISTS document_template_versions_read ON public.document_template_versions;
CREATE POLICY document_template_versions_read ON public.document_template_versions
  FOR SELECT TO authenticated USING (public.is_employee());

DROP POLICY IF EXISTS approval_delegations_read ON public.approval_delegations;
CREATE POLICY approval_delegations_read ON public.approval_delegations
  FOR SELECT TO authenticated USING (public.is_employee());
-- Handing your authority to somebody else is an administrative act, not a
-- personal one: a user must not be able to grant themselves an approver's
-- roles by writing their own delegation row.
DROP POLICY IF EXISTS approval_delegations_write ON public.approval_delegations;
CREATE POLICY approval_delegations_write ON public.approval_delegations
  FOR ALL TO authenticated USING (public.is_admin_or_founder()) WITH CHECK (public.is_admin_or_founder());

-- The attachment read policy leans on the request's own policy: the
-- sub-select is itself filtered by "View documents", so an attachment on a
-- confidential document is invisible to anyone who cannot see the document.
