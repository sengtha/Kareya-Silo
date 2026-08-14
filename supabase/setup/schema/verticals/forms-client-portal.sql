-- =====================================================================
-- KAREYA SILO — VERTICAL: CLIENT PORTAL (PASSCODE-GATED FORMS)
-- ---------------------------------------------------------------------
-- A company's own client fills in a form without having an account.
--
-- Until now Forms was entirely internal: every policy required
-- is_employee(), so a staff member typed the applicant's answers on their
-- behalf. This is the other half — the client does it themselves, from a
-- link, gated by a passcode.
--
-- WHO THESE PEOPLE ARE. A client is NOT a Kareya user and never becomes
-- one. There is no auth.users row, no Hub identity, no Google account,
-- nothing on Kareya's side at all. They are a row in THIS database, which
-- belongs to the company they are a client of. A list of a customer's
-- customers is the customer's own data and it stays here.
--
-- That is also why passkeys are not the gate. Registering one needs an
-- existing session, so it could never open the FIRST door; and Kareya's
-- passkeys live on the Hub, which would mean minting a Hub user for every
-- client of every customer. A passcode needs no account, works on a
-- borrowed phone, and can be read out over the telephone — which is how
-- these are actually going to be delivered.
--
-- THE SHAPE OF A PASSCODE. `PREFIX-SECRET`: the prefix is stored in clear
-- and indexed, the whole code is stored bcrypt-hashed. Verification is one
-- indexed lookup and one hash comparison, rather than a hash comparison
-- against every pass in the table — which at a few thousand clients would
-- be slow enough to be its own denial of service. It is the same reason
-- API keys are shaped this way.
--
-- The alphabet has no 0/O and no 1/I/L, for the same reason ticket codes
-- do not: these get read aloud down a phone line.
--
-- WHAT A CLIENT CAN REACH: the form, plus whatever the company chose to
-- share with THAT client — their own submissions, their own invoices.
-- Never the form list, never another client, never one row of anything
-- the company did not tick.
--
-- Enforced by the functions below being the only route in. The tables
-- grant anon nothing, and every function is REVOKEd from PUBLIC first —
-- PostgreSQL grants EXECUTE to PUBLIC by default, so a GRANT to
-- `authenticated` on its own restricts nobody at all.
--
-- INSTALL ORDER. This file sorts after document-register.sql, which is
-- deliberate: it redefines submit_form so the staff path and the client
-- path share one required-field check and one title rule, rather than
-- each carrying a copy that can drift. In a REVERSE-order install the
-- older definition wins instead — behaviour is identical, but the shared
-- validator is not in use until a forward pass runs. Forward is the
-- documented order.
--
-- One Silo == one business, so there is NO company_id here.
-- Fully idempotent: safe to re-run.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1. A pass belongs to one client and opens one form
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.client_passes (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  form_id      uuid NOT NULL,
  client_name  text NOT NULL,             -- who this was issued to
  contact      text,                      -- phone or email, for reissuing
  code_prefix  text NOT NULL,             -- in clear, indexed, for lookup
  code_hash    text NOT NULL,             -- bcrypt of the WHOLE code
  note         text,

  -- WHAT THIS CLIENT MAY SEE. The company decides, per client:
  --   form         fill in the form (always on — a pass without it is idle)
  --   submissions  the submissions they themselves sent
  --   shared       the items staff have explicitly published to them
  scopes       text[] NOT NULL DEFAULT ARRAY['form'],
  client_id    uuid,                      -- which customer this is, for staff's own reference

  expires_at   timestamptz,               -- null = no expiry
  revoked_at   timestamptz,
  revoke_reason text,

  -- Lockout. Only reachable once a prefix has been matched, so this is
  -- protection for a client whose code is half-known — a shoulder-surfed
  -- prefix, a code read out in a noisy room. The real defence against
  -- blind guessing is the length of the secret.
  failed_attempts integer NOT NULL DEFAULT 0,
  locked_until    timestamptz,

  use_count    integer NOT NULL DEFAULT 0,
  last_used_at timestamptz,
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT client_passes_pkey PRIMARY KEY (id),
  CONSTRAINT client_passes_prefix_key UNIQUE (code_prefix),
  CONSTRAINT client_passes_form_fkey FOREIGN KEY (form_id)
      REFERENCES public.form_defs(id) ON DELETE CASCADE,
  CONSTRAINT client_passes_created_by_fkey FOREIGN KEY (created_by)
      REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT client_passes_client_fkey FOREIGN KEY (client_id)
      REFERENCES public.clients(id) ON DELETE SET NULL,
  CONSTRAINT client_passes_name_len CHECK (char_length(btrim(client_name)) BETWEEN 1 AND 120),
  CONSTRAINT client_passes_scopes_known CHECK (
      scopes <@ ARRAY['form', 'submissions', 'shared']
      AND 'form' = ANY (scopes))
);
CREATE INDEX IF NOT EXISTS idx_client_passes_form ON public.client_passes (form_id);

-- ---------------------------------------------------------------------
-- 2. A session is what the browser holds afterwards
-- ---------------------------------------------------------------------
-- The token is 32 random bytes and is stored as a SHA-256 digest. bcrypt
-- is for low-entropy secrets a human chose; a 256-bit random token needs
-- no work factor, and putting one on every request would make each page
-- load pay for a key-stretching function that is protecting nothing.
CREATE TABLE IF NOT EXISTS public.client_sessions (
  id         uuid DEFAULT gen_random_uuid() NOT NULL,
  pass_id    uuid NOT NULL,
  token_hash text NOT NULL,
  issued_at  timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '2 hours'),
  revoked_at timestamptz,
  CONSTRAINT client_sessions_pkey PRIMARY KEY (id),
  CONSTRAINT client_sessions_token_key UNIQUE (token_hash),
  CONSTRAINT client_sessions_pass_fkey FOREIGN KEY (pass_id)
      REFERENCES public.client_passes(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_client_sessions_pass ON public.client_sessions (pass_id);

-- Which pass, if any, a submission came from. Nullable, because every
-- submission taken by staff before today has none and always will.
ALTER TABLE public.form_submissions
  ADD COLUMN IF NOT EXISTS client_pass_id uuid;
DO $$ BEGIN
  ALTER TABLE public.form_submissions
    ADD CONSTRAINT form_submissions_client_pass_fkey FOREIGN KEY (client_pass_id)
    REFERENCES public.client_passes(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_form_submissions_client_pass
  ON public.form_submissions (client_pass_id) WHERE client_pass_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3. Issuing a code
-- ---------------------------------------------------------------------
-- No 0/O, no 1/I/L. Somebody is going to read this down a telephone.
CREATE OR REPLACE FUNCTION public.new_client_code(p_len integer DEFAULT 10)
RETURNS text LANGUAGE plpgsql AS $function$
DECLARE
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  v_bytes  bytea;
  v_out    text := '';
  i        integer;
BEGIN
  v_bytes := gen_random_bytes(p_len);
  FOR i IN 1..p_len LOOP
    v_out := v_out || substr(alphabet, (get_byte(v_bytes, i - 1) % length(alphabet)) + 1, 1);
  END LOOP;
  RETURN v_out;
END $function$;

-- Returns the code ONCE, in clear. It is never readable again — only the
-- prefix and a bcrypt hash are kept. A staff member who loses it issues a
-- new one; that is the correct outcome, and a "show code" button would
-- quietly turn this table into a list of live credentials.
DROP FUNCTION IF EXISTS public.issue_client_pass(uuid, text, text, timestamptz, text);
DROP FUNCTION IF EXISTS public.issue_client_pass(uuid, text, text, timestamptz, text, text[], uuid);
CREATE OR REPLACE FUNCTION public.issue_client_pass(
  p_form_id    uuid,
  p_client_name text,
  p_contact    text DEFAULT NULL,
  p_expires_at timestamptz DEFAULT NULL,
  p_note       text DEFAULT NULL,
  p_scopes     text[] DEFAULT ARRAY['form'],
  p_client_id  uuid DEFAULT NULL
)
RETURNS TABLE(out_id uuid, out_code text, out_prefix text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_prefix text;
  v_secret text;
  v_id     uuid;
  n        integer := 0;
BEGIN
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
   ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN
    RAISE EXCEPTION 'refused: only staff of this workspace may issue a client passcode.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM form_defs WHERE id = p_form_id) THEN
    RAISE EXCEPTION 'refused: no such form.';
  END IF;

  -- The prefix is unique, so a collision means trying again rather than
  -- handing two clients the same lookup key.
  LOOP
    v_prefix := new_client_code(4);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM client_passes WHERE code_prefix = v_prefix);
    n := n + 1;
    IF n > 20 THEN RAISE EXCEPTION 'refused: could not allocate a passcode prefix.'; END IF;
  END LOOP;
  v_secret := new_client_code(10);

  INSERT INTO client_passes (form_id, client_name, contact, code_prefix, code_hash,
                             expires_at, note, scopes, client_id, created_by)
  VALUES (p_form_id, btrim(p_client_name), nullif(btrim(coalesce(p_contact, '')), ''),
          v_prefix, crypt(v_prefix || '-' || v_secret, gen_salt('bf', 10)),
          p_expires_at, nullif(btrim(coalesce(p_note, '')), ''),
          -- 'form' is not optional, so it is added rather than demanded.
          (SELECT array_agg(DISTINCT x) FROM unnest(coalesce(p_scopes, '{}') || ARRAY['form']) x),
          p_client_id, v_emp.id)
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, v_prefix || '-' || v_secret, v_prefix;
END $function$;
REVOKE EXECUTE ON FUNCTION public.issue_client_pass(uuid, text, text, timestamptz, text, text[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.issue_client_pass(uuid, text, text, timestamptz, text, text[], uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.revoke_client_pass(p_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT is_employee() THEN
    RAISE EXCEPTION 'refused: only staff of this workspace may revoke a client passcode.';
  END IF;
  UPDATE client_passes
     SET revoked_at = now(), revoke_reason = nullif(btrim(coalesce(p_reason, '')), '')
   WHERE id = p_id AND revoked_at IS NULL;
  -- Cutting the sessions too. A revoked pass whose holder stays signed in
  -- for another two hours has not been revoked, it has been scheduled.
  UPDATE client_sessions SET revoked_at = now()
   WHERE pass_id = p_id AND revoked_at IS NULL;
END $function$;
REVOKE EXECUTE ON FUNCTION public.revoke_client_pass(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_client_pass(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Opening a session — the only thing an anonymous visitor may call
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.open_client_session(text);
CREATE OR REPLACE FUNCTION public.open_client_session(p_code text)
RETURNS TABLE(
  out_ok boolean, out_message text, out_token text,
  out_form_id uuid, out_form_name text, out_client_name text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_code   text;
  v_prefix text;
  v_pass   client_passes;
  v_def    form_defs;
  v_token  text;
BEGIN
  -- Typed back in lower case, with the dash left out, still works. That is
  -- a person at a counter, not a forgery.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  IF char_length(v_code) < 14 THEN
    RETURN QUERY SELECT false, 'not_recognised', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;
  v_prefix := substr(v_code, 1, 4);
  v_code   := v_prefix || '-' || substr(v_code, 5);

  SELECT * INTO v_pass FROM client_passes WHERE code_prefix = v_prefix;

  -- Every refusal below returns the SAME message to the visitor. Telling
  -- somebody that a code exists but is expired, or that a prefix is real
  -- but the rest is wrong, is telling an attacker which half to keep.
  IF v_pass.id IS NULL THEN
    RETURN QUERY SELECT false, 'not_recognised', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  IF v_pass.locked_until IS NOT NULL AND v_pass.locked_until > now() THEN
    RETURN QUERY SELECT false, 'locked', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  IF v_pass.code_hash <> crypt(v_code, v_pass.code_hash) THEN
    UPDATE client_passes
       SET failed_attempts = failed_attempts + 1,
           locked_until = CASE WHEN failed_attempts + 1 >= 5
                               THEN now() + interval '15 minutes' ELSE locked_until END
     WHERE id = v_pass.id;
    RETURN QUERY SELECT false, 'not_recognised', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  IF v_pass.revoked_at IS NOT NULL
     OR (v_pass.expires_at IS NOT NULL AND v_pass.expires_at <= now()) THEN
    RETURN QUERY SELECT false, 'not_recognised', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  SELECT * INTO v_def FROM form_defs WHERE id = v_pass.form_id;
  IF v_def.id IS NULL OR NOT coalesce(v_def.is_published, false) THEN
    -- The code is good; the form is not open. This one IS said plainly,
    -- because the holder is legitimate and the fix is the company's.
    RETURN QUERY SELECT false, 'form_closed', NULL::text, NULL::uuid, NULL::text, NULL::text;
    RETURN;
  END IF;

  UPDATE client_passes
     SET failed_attempts = 0, locked_until = NULL,
         use_count = use_count + 1, last_used_at = now()
   WHERE id = v_pass.id;

  v_token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO client_sessions (pass_id, token_hash)
  VALUES (v_pass.id, encode(digest(v_token, 'sha256'), 'hex'));

  RETURN QUERY SELECT true, 'ok', v_token, v_def.id, v_def.name, v_pass.client_name;
END $function$;
REVOKE EXECUTE ON FUNCTION public.open_client_session(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.open_client_session(text) TO anon, authenticated;

-- Resolve a token to its pass. Internal: never granted to anon, so a
-- caller cannot use it to test tokens.
CREATE OR REPLACE FUNCTION public.client_session_pass(p_token text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT s.pass_id FROM client_sessions s
   WHERE s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     AND s.revoked_at IS NULL AND s.expires_at > now()
   LIMIT 1;
$function$;
-- PostgreSQL grants EXECUTE to PUBLIC on every function it creates, so a
-- GRANT to `authenticated` restricts precisely nobody. Without this REVOKE
-- an anonymous visitor could call this and turn it into an oracle for
-- testing tokens. Found by a test asserting it was refused; it was not.
REVOKE EXECUTE ON FUNCTION public.client_session_pass(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.new_client_code(integer) FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 5. The form, as the client sees it
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.client_form(text);
CREATE OR REPLACE FUNCTION public.client_form(p_token text)
RETURNS TABLE(form_id uuid, name text, description text, schema jsonb,
              fee_amount numeric, fee_currency text, client_name text, scopes text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  -- The workflow is NOT returned. Which manager approves what, and in what
  -- order, is the company's business and none of the client's.
  SELECT d.id, d.name, d.description, coalesce(d.schema, '[]'::jsonb),
         coalesce(d.fee_amount, 0), coalesce(d.fee_currency, 'USD'), p.client_name, p.scopes
    FROM client_passes p
    JOIN form_defs d ON d.id = p.form_id
   WHERE p.id = client_session_pass(p_token)
     AND coalesce(d.is_published, false);
$function$;
REVOKE EXECUTE ON FUNCTION public.client_form(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.client_form(text) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Submitting
-- ---------------------------------------------------------------------
-- Validation and titling are shared with the staff path below, so a rule
-- cannot be enforced for one and not the other. That is the whole reason
-- this file redefines submit_form rather than copying its body.
CREATE OR REPLACE FUNCTION public.form_check_required(p_def form_defs, p_values jsonb)
RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $function$
DECLARE v_field jsonb; v_val jsonb;
BEGIN
  FOR v_field IN SELECT f FROM jsonb_array_elements(coalesce(p_def.schema, '[]'::jsonb)) f LOOP
    CONTINUE WHEN coalesce(v_field->>'type', '') = 'section';
    CONTINUE WHEN NOT coalesce((v_field->>'required')::boolean, false);
    v_val := coalesce(p_values, '{}'::jsonb) -> (v_field->>'key');
    IF v_val IS NULL OR v_val = 'null'::jsonb OR v_val = '""'::jsonb OR v_val = 'false'::jsonb THEN
      RAISE EXCEPTION '% is required', coalesce(v_field->>'label', v_field->>'key');
    END IF;
  END LOOP;
END $function$;

CREATE OR REPLACE FUNCTION public.form_title_for(p_def form_defs, p_values jsonb)
RETURNS text LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $function$
DECLARE v_title text;
BEGIN
  SELECT coalesce(p_values ->> (f->>'key'), '') INTO v_title
    FROM jsonb_array_elements(coalesce(p_def.schema, '[]'::jsonb)) f
   WHERE coalesce((f->>'isTitle')::boolean, false) LIMIT 1;
  IF coalesce(v_title, '') = '' THEN
    SELECT coalesce(p_values ->> (f->>'key'), '') INTO v_title
      FROM jsonb_array_elements(coalesce(p_def.schema, '[]'::jsonb)) f
     WHERE f->>'type' IN ('text', 'textarea') LIMIT 1;
  END IF;
  RETURN CASE WHEN coalesce(v_title, '') = '' THEN p_def.name ELSE v_title END;
END $function$;

-- Shared internals: nobody outside this file has any business calling them.
REVOKE EXECUTE ON FUNCTION public.form_check_required(form_defs, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.form_title_for(form_defs, jsonb) FROM PUBLIC;

DROP FUNCTION IF EXISTS public.client_submit_form(text, jsonb, text);
CREATE OR REPLACE FUNCTION public.client_submit_form(
  p_token  text,
  p_values jsonb,
  p_notes  text DEFAULT NULL
)
RETURNS TABLE(out_id uuid, out_reference text, out_status text, out_fee numeric, out_currency text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_pass client_passes;
  v_def  form_defs;
  v_step integer;
  v_fee  numeric;
  v_sub  form_submissions;
BEGIN
  SELECT * INTO v_pass FROM client_passes WHERE id = client_session_pass(p_token);
  IF v_pass.id IS NULL THEN
    RAISE EXCEPTION 'refused: that link has expired. Enter your passcode again.';
  END IF;

  SELECT * INTO v_def FROM form_defs WHERE id = v_pass.form_id;
  IF v_def.id IS NULL OR NOT coalesce(v_def.is_published, false) THEN
    RAISE EXCEPTION 'refused: this form is not accepting submissions.';
  END IF;

  PERFORM form_check_required(v_def, p_values);

  v_step := form_skip_auto(v_def.workflow, 0, 'none');
  v_fee  := CASE WHEN EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(v_def.workflow, '[]'::jsonb)) s WHERE s->>'type' = 'payment')
    THEN coalesce(v_def.fee_amount, 0) ELSE 0 END;

  INSERT INTO form_submissions (
    form_id, reference, series_code, title, values, status, current_step,
    submitted_by, applicant_name, notes, client_pass_id,
    fee_amount, fee_currency, fee_status
  ) VALUES (
    v_def.id, allocate_document_number('FORM'), 'FORM',
    form_title_for(v_def, p_values), coalesce(p_values, '{}'::jsonb),
    form_status_for(v_def.workflow, v_step), v_step,
    NULL,                      -- no employee: nobody here works for the company
    v_pass.client_name, nullif(btrim(coalesce(p_notes, '')), ''), v_pass.id,
    v_fee, coalesce(v_def.fee_currency, 'USD'), 'none'
  )
  RETURNING * INTO v_sub;

  PERFORM form_event(v_sub.id, 'submitted', v_pass.client_name, NULL, 'Submitted by the client');

  RETURN QUERY SELECT v_sub.id, v_sub.reference, v_sub.status, v_sub.fee_amount, v_sub.fee_currency;
END $function$;
REVOKE EXECUTE ON FUNCTION public.client_submit_form(text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.client_submit_form(text, jsonb, text) TO anon, authenticated;

-- What the client may look at afterwards: their own submissions, and only
-- the fields that concern them. Not the internal notes, not who approved.
DROP FUNCTION IF EXISTS public.client_my_submissions(text);
CREATE OR REPLACE FUNCTION public.client_my_submissions(p_token text)
RETURNS TABLE(id uuid, reference text, title text, status text,
              fee_amount numeric, fee_currency text, fee_status text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT s.id, s.reference, s.title, s.status,
         s.fee_amount, s.fee_currency, s.fee_status, s.created_at
    FROM form_submissions s
    JOIN client_passes p ON p.id = s.client_pass_id
   WHERE p.id = client_session_pass(p_token)
     AND 'submissions' = ANY (p.scopes)
   ORDER BY s.created_at DESC
   LIMIT 50;
$function$;
REVOKE EXECUTE ON FUNCTION public.client_my_submissions(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.client_my_submissions(text) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 6b. Shared items — copied, never joined
-- ---------------------------------------------------------------------
-- A client NEVER reads the company's own tables. Not invoices, not
-- documents, not clients — not even through a function that filters them.
-- Staff PUBLISH an item here, and this table is the only thing a client
-- can see.
--
-- Why a copy rather than a filtered view of the real thing:
--
--   1. A filter is a decision remade on every read, and a schema change
--      years from now can widen it without anybody noticing. A copy is a
--      decision made once, by a person, at the moment of sharing.
--   2. It is a FROZEN SNAPSHOT, like every other document Kareya hands
--      out. An invoice shared in March still reads as it did in March,
--      whatever the ledger has done since. The client sees what they were
--      sent.
--   3. A column added to `invoices` next year cannot become visible to
--      the outside world by accident. Nothing here widens on its own.
--
-- The cost is real and worth stating plainly: a shared item does NOT
-- follow the original. Staff re-share to refresh it, and the check at the
-- end of this file names items whose source has since changed.
CREATE TABLE IF NOT EXISTS public.client_shared_items (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  pass_id     uuid NOT NULL,
  kind        text NOT NULL,               -- invoice | document | note | link
  title       text NOT NULL,
  reference   text,                        -- invoice number, document number
  body        text,                        -- the note, or a description
  amount      numeric,
  currency    text,
  status      text,                        -- as it read at the moment of sharing
  url         text,                        -- an https link, if any
  source_table text,                       -- what it was copied FROM, for staff
  source_id   uuid,                        -- and which row. NEVER shown to the client.
  shared_at   timestamptz NOT NULL DEFAULT now(),
  shared_by   uuid,
  revoked_at  timestamptz,
  CONSTRAINT client_shared_items_pkey PRIMARY KEY (id),
  CONSTRAINT client_shared_items_pass_fkey FOREIGN KEY (pass_id)
      REFERENCES public.client_passes(id) ON DELETE CASCADE,
  CONSTRAINT client_shared_items_by_fkey FOREIGN KEY (shared_by)
      REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT client_shared_items_kind CHECK (kind = ANY (ARRAY['invoice', 'document', 'note', 'link'])),
  CONSTRAINT client_shared_items_title_len CHECK (char_length(btrim(title)) BETWEEN 1 AND 200),
  CONSTRAINT client_shared_items_url_https CHECK (url IS NULL OR url ~ '^https://')
);
CREATE INDEX IF NOT EXISTS idx_client_shared_items_pass ON public.client_shared_items (pass_id);

DROP FUNCTION IF EXISTS public.share_with_client(uuid, text, text, text, text, numeric, text, text, text, text, uuid);
CREATE OR REPLACE FUNCTION public.share_with_client(
  p_pass_id uuid, p_kind text, p_title text,
  p_reference text DEFAULT NULL, p_body text DEFAULT NULL,
  p_amount numeric DEFAULT NULL, p_currency text DEFAULT NULL,
  p_status text DEFAULT NULL, p_url text DEFAULT NULL,
  p_source_table text DEFAULT NULL, p_source_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_id uuid;
BEGIN
  SELECT * INTO v_emp FROM employees
   WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
   ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN
    RAISE EXCEPTION 'refused: only staff of this workspace may share an item with a client.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM client_passes WHERE id = p_pass_id AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'refused: no such client passcode, or it has been revoked.';
  END IF;

  INSERT INTO client_shared_items (pass_id, kind, title, reference, body, amount,
                                   currency, status, url, source_table, source_id, shared_by)
  VALUES (p_pass_id, p_kind, btrim(p_title), p_reference, p_body, p_amount,
          p_currency, p_status, p_url, p_source_table, p_source_id, v_emp.id)
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.share_with_client(uuid, text, text, text, text, numeric, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.share_with_client(uuid, text, text, text, text, numeric, text, text, text, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.unshare_from_client(p_item_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT is_employee() THEN
    RAISE EXCEPTION 'refused: only staff of this workspace may withdraw a shared item.';
  END IF;
  UPDATE client_shared_items SET revoked_at = now() WHERE id = p_item_id AND revoked_at IS NULL;
END $function$;
REVOKE EXECUTE ON FUNCTION public.unshare_from_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unshare_from_client(uuid) TO authenticated;

-- What the client sees. source_table and source_id are NOT returned: which
-- row of which table this was copied from is the company's business.
DROP FUNCTION IF EXISTS public.client_shared(text);
CREATE OR REPLACE FUNCTION public.client_shared(p_token text)
RETURNS TABLE(kind text, title text, reference text, body text,
              amount numeric, currency text, status text, url text, shared_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT i.kind, i.title, i.reference, i.body,
         i.amount, i.currency, i.status, i.url, i.shared_at
    FROM client_shared_items i
    JOIN client_passes p ON p.id = i.pass_id
   WHERE p.id = client_session_pass(p_token)
     AND 'shared' = ANY (p.scopes)
     AND i.revoked_at IS NULL
   ORDER BY i.shared_at DESC
   LIMIT 200;
$function$;
REVOKE EXECUTE ON FUNCTION public.client_shared(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.client_shared(text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.client_portal_scopes()
RETURNS TABLE(scope text, label text)
LANGUAGE sql IMMUTABLE AS $function$
  VALUES ('form',        'Fill in the form'),
         ('submissions', 'See their own submissions'),
         ('shared',      'See items staff share with them')
$function$;
-- ---------------------------------------------------------------------
-- 7. The staff path, redefined to share the rules above
-- ---------------------------------------------------------------------
-- Identical behaviour to the version in document-register.sql, with the
-- required-field check and the title derivation replaced by calls to the
-- shared functions. This file sorts after that one, so this definition is
-- the one that survives.
CREATE OR REPLACE FUNCTION public.submit_form(
  p_form_id uuid,
  p_values jsonb,
  p_applicant_name text DEFAULT NULL,
  p_applicant_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
 RETURNS public.form_submissions
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_emp employees; v_def form_defs; v_step integer; v_fee numeric; v_sub form_submissions;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  SELECT * INTO v_def FROM form_defs WHERE id = p_form_id;
  IF v_def.id IS NULL THEN RAISE EXCEPTION 'Form not found'; END IF;
  IF NOT coalesce(v_def.is_published, false) THEN
    RAISE EXCEPTION 'Form "%" is not published', v_def.name;
  END IF;

  PERFORM form_check_required(v_def, p_values);

  v_step := form_skip_auto(v_def.workflow, 0, 'none');
  v_fee  := CASE WHEN EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(v_def.workflow, '[]'::jsonb)) s WHERE s->>'type' = 'payment')
    THEN coalesce(v_def.fee_amount, 0) ELSE 0 END;

  INSERT INTO form_submissions (
    form_id, reference, series_code, title, values, status, current_step,
    submitted_by, applicant_name, applicant_phone, notes,
    fee_amount, fee_currency, fee_status
  ) VALUES (
    p_form_id, allocate_document_number('FORM'), 'FORM',
    form_title_for(v_def, p_values), coalesce(p_values, '{}'::jsonb),
    form_status_for(v_def.workflow, v_step), v_step,
    v_emp.id, p_applicant_name, p_applicant_phone, p_notes,
    v_fee, coalesce(v_def.fee_currency, 'USD'), 'none'
  )
  RETURNING * INTO v_sub;

  PERFORM form_event(v_sub.id, 'submitted', v_emp.name, NULL, v_sub.title);
  RETURN v_sub;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.submit_form(uuid, jsonb, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_form(uuid, jsonb, text, text, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. What needs looking at
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.client_portal_reconciliation();
CREATE OR REPLACE FUNCTION public.client_portal_reconciliation()
RETURNS TABLE(issue text, detail text, count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT 'locked_out', 'Passcodes locked after repeated wrong attempts — the holder may need a new one, or somebody is guessing',
         count(*) FROM client_passes WHERE locked_until > now()
  UNION ALL
  SELECT 'never_used', 'Issued more than fourteen days ago and never used — the client may never have received it',
         count(*) FROM client_passes
   WHERE use_count = 0 AND revoked_at IS NULL AND created_at < now() - interval '14 days'
  UNION ALL
  SELECT 'form_unpublished', 'Live passcodes for a form that is no longer published — their holders are being turned away',
         count(*) FROM client_passes p JOIN form_defs d ON d.id = p.form_id
   WHERE p.revoked_at IS NULL AND NOT coalesce(d.is_published, false)
  UNION ALL
  SELECT 'expired_not_revoked', 'Passcodes past their expiry date but never revoked — tidy-up, not a fault',
         count(*) FROM client_passes
   WHERE expires_at <= now() AND revoked_at IS NULL
  UNION ALL
  SELECT 'stale_sessions', 'Client sessions still open past their expiry — harmless, but they can be cleared',
         count(*) FROM client_sessions WHERE expires_at <= now() AND revoked_at IS NULL
  UNION ALL
  -- A shared item is a COPY, frozen at the moment it was shared. This names
  -- the ones whose source has moved on since, which is the price of the copy
  -- and the thing somebody has to be told about rather than discover.
  SELECT 'shared_invoice_moved', 'Invoices shared with a client whose status has changed since — re-share to refresh what they see',
         count(*) FROM client_shared_items i
    JOIN invoices v ON v.id = i.source_id
   WHERE i.kind = 'invoice' AND i.source_table = 'invoices'
     AND i.revoked_at IS NULL AND coalesce(i.status, '') <> coalesce(v.status, '');
$function$;
REVOKE EXECUTE ON FUNCTION public.client_portal_reconciliation() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.client_portal_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 9. Row level security
-- ---------------------------------------------------------------------
-- anon is granted NOTHING on these tables. Every route in for a client is
-- a SECURITY DEFINER function above, each of which decides for itself what
-- one token may see. A policy would be a second place for that decision to
-- be made, and the two would eventually disagree.
ALTER TABLE public.client_passes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Staff read client passes" ON public.client_passes;
CREATE POLICY "Staff read client passes" ON public.client_passes
  FOR SELECT TO authenticated USING (is_employee());

DROP POLICY IF EXISTS "Managers manage client passes" ON public.client_passes;
CREATE POLICY "Managers manage client passes" ON public.client_passes
  FOR ALL TO authenticated USING (has_any_role(ARRAY['Manager'])) WITH CHECK (has_any_role(ARRAY['Manager']));

-- Sessions are readable by staff for support ("did they get in?") and
-- writable by nobody: they are created and revoked through the functions.
DROP POLICY IF EXISTS "Staff read client sessions" ON public.client_sessions;
CREATE POLICY "Staff read client sessions" ON public.client_sessions
  FOR SELECT TO authenticated USING (is_employee());

ALTER TABLE public.client_shared_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Staff read shared items" ON public.client_shared_items;
CREATE POLICY "Staff read shared items" ON public.client_shared_items
  FOR SELECT TO authenticated USING (is_employee());
DROP POLICY IF EXISTS "Staff manage shared items" ON public.client_shared_items;
CREATE POLICY "Staff manage shared items" ON public.client_shared_items
  FOR ALL TO authenticated USING (is_employee()) WITH CHECK (is_employee());
