-- =====================================================================
-- KAREYA SILO — HOSPITAL: PAYERS, COVERAGE, CLAIMS, STATISTICS
-- ---------------------------------------------------------------------
-- Until now every charge was the patient's. In Cambodia that is wrong
-- often enough to matter: a Health Equity Fund or ID Poor cardholder, an
-- NSSF member, somebody on a private policy or a company account. Getting
-- this wrong has two failure modes and they hurt different people —
--
--   bill the scheme's share to the patient, and somebody entitled to free
--   care is asked for money they do not have;
--   forget to claim it, and the hospital absorbs the cost and slowly dies.
--
-- WHAT THIS FILE DOES NOT CONTAIN, DELIBERATELY:
--
-- No HEF benefit package. No NSSF reimbursement rates. No MoH HMIS form
-- layout. Those are set by the operator of each scheme, they change, and
-- this deployment could not verify any of them. Encoding a plausible
-- guess would be worse than encoding nothing, because a wrong rate looks
-- exactly like a right one and nobody checks a number the computer
-- printed. So EVERY rate, ceiling and exclusion here is configured by the
-- hospital from its own signed agreement, and the tables ship EMPTY.
--
-- This is the same stance payroll_config and tax_config already take for
-- Prakas-set figures, for the same reason. Nothing here is advice on
-- entitlement.
--
-- SCOPE: one payer per charge, with the remainder to the patient. Two
-- schemes splitting a single line is rare in Cambodian practice and would
-- double the complexity of every reconciliation; if it is ever needed the
-- charge can be recorded as two lines.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.patients, public.hospital_charges, public.employees,
--             public.has_any_role(text[]).
-- =====================================================================

-- =====================================================================
-- 1. PAYERS AND WHAT THEY COVER
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.payers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  name_kh text,
  kind text DEFAULT 'other'::text,          -- equity_fund | social_security | private_insurance | corporate | ngo | government | other
  claim_cycle text DEFAULT 'monthly'::text, -- monthly | weekly | per_case
  contact text,
  agreement_ref text,                       -- the signed document these rules came from
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payers_pkey PRIMARY KEY (id),
  CONSTRAINT payers_kind_check CHECK (kind = ANY (ARRAY['equity_fund','social_security','private_insurance','corporate','ngo','government','other'])),
  CONSTRAINT payers_cycle_check CHECK (claim_cycle = ANY (ARRAY['monthly','weekly','per_case']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_payers_code ON public.payers (lower(code));

/** What a payer covers, by charge kind.
 *
 *  A row with charge_kind NULL is the default for anything not named
 *  explicitly, so a scheme that covers everything at 100% is one row and
 *  a scheme with exceptions is a handful.
 *
 *  covered_pct 0 is meaningful and is NOT the same as no rule: it says
 *  "this scheme explicitly does not pay for this", which a hospital needs
 *  to be able to state. */
CREATE TABLE IF NOT EXISTS public.payer_coverage (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  payer_id uuid NOT NULL,
  charge_kind text,                         -- NULL = the default rule
  covered_pct numeric DEFAULT 0 NOT NULL,
  per_item_ceiling numeric,                 -- most the scheme pays on one line
  notes text,
  CONSTRAINT payer_coverage_pkey PRIMARY KEY (id),
  CONSTRAINT payer_coverage_payer_fkey FOREIGN KEY (payer_id) REFERENCES public.payers(id) ON DELETE CASCADE,
  CONSTRAINT payer_coverage_pct_check CHECK (covered_pct BETWEEN 0 AND 100),
  CONSTRAINT payer_coverage_ceiling_check CHECK (per_item_ceiling IS NULL OR per_item_ceiling >= 0),
  CONSTRAINT payer_coverage_kind_check CHECK (
    charge_kind IS NULL OR charge_kind = ANY (ARRAY['bed','consultation','procedure','lab','radiology','drug','consumable','other']))
);
-- One rule per kind per payer, and one default per payer. Two rules for
-- the same kind would make the split depend on row order.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payer_coverage_kind
  ON public.payer_coverage (payer_id, charge_kind) WHERE charge_kind IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_payer_coverage_default
  ON public.payer_coverage (payer_id) WHERE charge_kind IS NULL;

/** A patient's membership of a scheme, with the dates it is valid for.
 *
 *  Validity is checked against the DATE OF THE CHARGE, not today. An ID
 *  Poor card that expired last week still covers last month's admission,
 *  and a card issued yesterday does not cover the week before. Getting
 *  that backwards produces claims the scheme rejects and bills the patient
 *  should never have seen. */
CREATE TABLE IF NOT EXISTS public.patient_coverage (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid NOT NULL,
  payer_id uuid NOT NULL,
  membership_no text,
  valid_from date,
  valid_to date,
  -- Lower number wins when a patient holds more than one card.
  priority integer DEFAULT 100,
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT patient_coverage_pkey PRIMARY KEY (id),
  CONSTRAINT patient_coverage_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT patient_coverage_payer_fkey FOREIGN KEY (payer_id) REFERENCES public.payers(id) ON DELETE CASCADE,
  CONSTRAINT patient_coverage_span_check CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from)
);
CREATE INDEX IF NOT EXISTS idx_patient_coverage_patient ON public.patient_coverage (patient_id) WHERE is_active;

-- =====================================================================
-- 2. SPLITTING A CHARGE
-- =====================================================================

ALTER TABLE public.hospital_charges ADD COLUMN IF NOT EXISTS payer_id uuid;
ALTER TABLE public.hospital_charges ADD COLUMN IF NOT EXISTS claim_id uuid;
DO $c$ BEGIN
  ALTER TABLE public.hospital_charges ADD CONSTRAINT hospital_charges_payer_fkey
    FOREIGN KEY (payer_id) REFERENCES public.payers(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
CREATE INDEX IF NOT EXISTS idx_hospital_charges_claimable
  ON public.hospital_charges (payer_id, charge_date) WHERE claim_id IS NULL AND scheme_amount > 0;

/** The scheme that applies to this patient on this date, if any. */
DROP FUNCTION IF EXISTS public.coverage_for(uuid, date);
CREATE OR REPLACE FUNCTION public.coverage_for(p_patient uuid, p_on date)
RETURNS TABLE (out_payer_id uuid, out_payer text, out_membership_no text)
LANGUAGE sql STABLE AS $$
  SELECT pc.payer_id, p.name, pc.membership_no
    FROM public.patient_coverage pc
    JOIN public.payers p ON p.id = pc.payer_id
   WHERE pc.patient_id = p_patient
     AND pc.is_active AND p.is_active
     AND (pc.valid_from IS NULL OR pc.valid_from <= p_on)
     AND (pc.valid_to   IS NULL OR pc.valid_to   >= p_on)
   ORDER BY pc.priority, pc.created_at
   LIMIT 1;
$$;

/** What a given payer would pay on one line. Pure arithmetic over the
 *  configured rule — no rule means no cover, never an assumed default. */
CREATE OR REPLACE FUNCTION public.covered_amount(p_payer uuid, p_kind text, p_amount numeric)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v_rule public.payer_coverage; v_out numeric;
BEGIN
  SELECT * INTO v_rule FROM public.payer_coverage
   WHERE payer_id = p_payer AND charge_kind = p_kind;
  IF NOT FOUND THEN
    SELECT * INTO v_rule FROM public.payer_coverage
     WHERE payer_id = p_payer AND charge_kind IS NULL;
  END IF;
  IF NOT FOUND THEN RETURN 0; END IF;

  v_out := round(coalesce(p_amount, 0) * v_rule.covered_pct / 100.0, 2);
  IF v_rule.per_item_ceiling IS NOT NULL THEN
    v_out := least(v_out, v_rule.per_item_ceiling);
  END IF;
  RETURN greatest(0, least(v_out, coalesce(p_amount, 0)));
END $$;

/** Apply coverage to a charge, or re-apply it after the rules change.
 *
 *  Refuses once the charge is on a claim or an invoice: both are documents
 *  somebody is holding, and moving the split underneath them turns a
 *  reconciliation into an argument. */
CREATE OR REPLACE FUNCTION public.apply_coverage(p_charge uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c public.hospital_charges; v_payer uuid; v_covered numeric;
BEGIN
  SELECT * INTO v_c FROM public.hospital_charges WHERE id = p_charge FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Charge not found'; END IF;
  IF v_c.claim_id IS NOT NULL THEN
    RAISE EXCEPTION 'That charge is already on a claim and its split cannot be changed';
  END IF;
  IF v_c.invoice_id IS NOT NULL THEN
    RAISE EXCEPTION 'That charge is already on an invoice and its split cannot be changed';
  END IF;

  SELECT out_payer_id INTO v_payer FROM public.coverage_for(v_c.patient_id, v_c.charge_date);
  IF v_payer IS NULL THEN
    UPDATE public.hospital_charges SET payer_id = NULL, scheme_amount = 0 WHERE id = p_charge;
    RETURN 0;
  END IF;

  v_covered := public.covered_amount(v_payer, v_c.kind, v_c.amount);
  UPDATE public.hospital_charges
     SET payer_id = v_payer, scheme_amount = v_covered
   WHERE id = p_charge;
  RETURN v_covered;
END $$;

/** New charges are split as they are created, so the running total on the
 *  ward is what the patient will actually be asked for. */
CREATE OR REPLACE FUNCTION public.hosp_charge_apply_coverage()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_payer uuid; v_covered numeric;
BEGIN
  SELECT out_payer_id INTO v_payer FROM public.coverage_for(NEW.patient_id, NEW.charge_date);
  IF v_payer IS NOT NULL THEN
    v_covered := public.covered_amount(v_payer, NEW.kind, NEW.amount);
    UPDATE public.hospital_charges
       SET payer_id = v_payer, scheme_amount = v_covered
     WHERE id = NEW.id;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_hosp_charge_apply_coverage ON public.hospital_charges;
CREATE TRIGGER trg_hosp_charge_apply_coverage
  AFTER INSERT ON public.hospital_charges
  FOR EACH ROW EXECUTE FUNCTION public.hosp_charge_apply_coverage();

/** Who owes what on an admission. The number a family actually asks for. */
DROP FUNCTION IF EXISTS public.admission_payer_split(uuid);
CREATE OR REPLACE FUNCTION public.admission_payer_split(p_admission uuid)
RETURNS TABLE (out_payer text, out_lines integer, out_scheme numeric, out_patient numeric)
LANGUAGE sql STABLE AS $$
  SELECT coalesce(p.name, '—'), count(*)::integer, sum(c.scheme_amount), sum(c.patient_amount)
    FROM public.hospital_charges c
    LEFT JOIN public.payers p ON p.id = c.payer_id
   WHERE c.admission_id = p_admission
   GROUP BY p.name
   ORDER BY sum(c.scheme_amount) DESC;
$$;

-- =====================================================================
-- 3. CLAIMS
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.payer_claims (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  claim_no text,
  payer_id uuid NOT NULL,
  period_from date NOT NULL,
  period_to date NOT NULL,
  status text DEFAULT 'draft'::text,        -- draft | submitted | part_paid | paid | rejected
  claimed_amount numeric DEFAULT 0,
  paid_amount numeric DEFAULT 0,
  submitted_at timestamp with time zone,
  settled_at timestamp with time zone,
  their_reference text,
  rejection_reason text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT payer_claims_pkey PRIMARY KEY (id),
  CONSTRAINT payer_claims_payer_fkey FOREIGN KEY (payer_id) REFERENCES public.payers(id) ON DELETE RESTRICT,
  CONSTRAINT payer_claims_period_check CHECK (period_to >= period_from),
  CONSTRAINT payer_claims_status_check CHECK (status = ANY (ARRAY['draft','submitted','part_paid','paid','rejected'])),
  CONSTRAINT payer_claims_amounts_check CHECK (claimed_amount >= 0 AND paid_amount >= 0),
  -- A rejection that does not say why is a rejection nobody can act on.
  CONSTRAINT payer_claims_rejection_check CHECK (
    status <> 'rejected' OR btrim(coalesce(rejection_reason, '')) <> '')
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_payer_claims_no ON public.payer_claims (claim_no) WHERE claim_no IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_payer_claims_open ON public.payer_claims (payer_id, status);

DO $c$ BEGIN
  ALTER TABLE public.hospital_charges ADD CONSTRAINT hospital_charges_claim_fkey
    FOREIGN KEY (claim_id) REFERENCES public.payer_claims(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** Batch every unclaimed scheme portion for one payer over a period.
 *
 *  A charge carries the claim it went onto, so it cannot be claimed twice:
 *  the second attempt simply finds nothing. That is the whole defence
 *  against double-claiming, and it is one column rather than a process. */
CREATE OR REPLACE FUNCTION public.create_payer_claim(
  p_payer uuid, p_from date, p_to date
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_claim uuid; v_total numeric; v_no text; v_seq integer;
BEGIN
  IF p_to < p_from THEN RAISE EXCEPTION 'The period ends before it starts'; END IF;

  SELECT sum(scheme_amount) INTO v_total
    FROM public.hospital_charges
   WHERE payer_id = p_payer AND claim_id IS NULL
     AND scheme_amount > 0 AND charge_date BETWEEN p_from AND p_to;
  IF coalesce(v_total, 0) = 0 THEN
    RAISE EXCEPTION 'There is nothing unclaimed for that payer in that period';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('payer_claim_no'));
  SELECT count(*) + 1 INTO v_seq FROM public.payer_claims
   WHERE created_at >= date_trunc('year', now());
  v_no := 'CLM-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  INSERT INTO public.payer_claims (claim_no, payer_id, period_from, period_to, claimed_amount)
  VALUES (v_no, p_payer, p_from, p_to, v_total)
  RETURNING id INTO v_claim;

  UPDATE public.hospital_charges SET claim_id = v_claim
   WHERE payer_id = p_payer AND claim_id IS NULL
     AND scheme_amount > 0 AND charge_date BETWEEN p_from AND p_to;

  RETURN v_claim;
END $$;

CREATE OR REPLACE FUNCTION public.submit_payer_claim(p_claim uuid, p_reference text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.payer_claims
     SET status = 'submitted', submitted_at = now(), their_reference = coalesce(p_reference, their_reference)
   WHERE id = p_claim AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'That claim is not a draft'; END IF;
END $$;

/** Record what the scheme actually paid.
 *
 *  Short payment is the normal case, not an error, and the shortfall stays
 *  visible rather than being written off quietly — that difference is the
 *  hospital's money and somebody should have to decide to forgive it. */
CREATE OR REPLACE FUNCTION public.settle_payer_claim(
  p_claim uuid, p_paid numeric, p_reference text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_claim public.payer_claims; v_status text;
BEGIN
  SELECT * INTO v_claim FROM public.payer_claims WHERE id = p_claim FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Claim not found'; END IF;
  IF v_claim.status NOT IN ('submitted', 'part_paid') THEN
    RAISE EXCEPTION 'That claim is %, so it cannot be settled', v_claim.status;
  END IF;
  IF coalesce(p_paid, 0) < 0 THEN RAISE EXCEPTION 'A payment cannot be negative'; END IF;

  v_status := CASE WHEN coalesce(p_paid, 0) >= v_claim.claimed_amount THEN 'paid' ELSE 'part_paid' END;

  UPDATE public.payer_claims
     SET paid_amount = coalesce(p_paid, 0),
         status = v_status,
         settled_at = CASE WHEN v_status = 'paid' THEN now() ELSE settled_at END,
         their_reference = coalesce(p_reference, their_reference)
   WHERE id = p_claim;
  RETURN v_status;
END $$;

/** Reject a claim and release its charges, so they can be corrected and
 *  claimed again. Without the release a rejection would silently write
 *  the money off. */
CREATE OR REPLACE FUNCTION public.reject_payer_claim(p_claim uuid, p_reason text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count integer;
BEGIN
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'A rejected claim needs the reason the scheme gave';
  END IF;
  UPDATE public.payer_claims
     SET status = 'rejected', rejection_reason = p_reason, settled_at = now()
   WHERE id = p_claim AND status IN ('submitted', 'part_paid', 'draft');
  IF NOT FOUND THEN RAISE EXCEPTION 'That claim cannot be rejected from its current state'; END IF;

  UPDATE public.hospital_charges SET claim_id = NULL WHERE claim_id = p_claim;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

/** What each payer owes, and how long it has owed it. */
DROP FUNCTION IF EXISTS public.payer_receivables();
CREATE OR REPLACE FUNCTION public.payer_receivables()
RETURNS TABLE (
  out_payer_id uuid, out_payer text, out_unclaimed numeric,
  out_submitted numeric, out_shortfall numeric, out_oldest_days integer
) LANGUAGE sql STABLE AS $$
  SELECT p.id, p.name,
         coalesce((SELECT sum(c.scheme_amount) FROM public.hospital_charges c
                    WHERE c.payer_id = p.id AND c.claim_id IS NULL AND c.scheme_amount > 0), 0),
         coalesce((SELECT sum(cl.claimed_amount - cl.paid_amount) FROM public.payer_claims cl
                    WHERE cl.payer_id = p.id AND cl.status IN ('submitted','part_paid')), 0),
         coalesce((SELECT sum(cl.claimed_amount - cl.paid_amount) FROM public.payer_claims cl
                    WHERE cl.payer_id = p.id AND cl.status = 'part_paid'), 0),
         coalesce((SELECT max((CURRENT_DATE - c.charge_date))::integer FROM public.hospital_charges c
                    WHERE c.payer_id = p.id AND c.claim_id IS NULL AND c.scheme_amount > 0), 0)
    FROM public.payers p
   WHERE p.is_active
   ORDER BY p.name;
$$;

-- =====================================================================
-- 4. STATISTICS
-- ---------------------------------------------------------------------
-- Counts a hospital can compute honestly from its own records: how many
-- were admitted, discharged, died; how many bed-days; occupancy.
--
-- This is NOT the Ministry of Health HMIS return. The official form's
-- indicators, groupings and age bands could not be verified when this was
-- built, and a return filed from figures that merely look official is
-- worse than one filed by hand. Use these to fill the form, having
-- checked what each line of the form actually asks for.
-- =====================================================================

DROP FUNCTION IF EXISTS public.hospital_statistics(date, date);
CREATE OR REPLACE FUNCTION public.hospital_statistics(p_from date, p_to date)
RETURNS TABLE (
  out_metric text, out_value numeric
) LANGUAGE sql STABLE AS $$
  SELECT 'admissions', count(*)::numeric FROM public.hospital_admissions
   WHERE admitted_at::date BETWEEN p_from AND p_to
  UNION ALL
  SELECT 'discharges', count(*)::numeric FROM public.hospital_admissions
   WHERE discharged_at::date BETWEEN p_from AND p_to AND status = 'discharged'
  UNION ALL
  SELECT 'deaths', count(*)::numeric FROM public.hospital_admissions
   WHERE discharged_at::date BETWEEN p_from AND p_to AND status = 'deceased'
  UNION ALL
  SELECT 'against_advice', count(*)::numeric FROM public.hospital_admissions
   WHERE discharged_at::date BETWEEN p_from AND p_to AND discharge_type = 'against_advice'
  UNION ALL
  SELECT 'referred_out', count(*)::numeric FROM public.hospital_admissions
   WHERE discharged_at::date BETWEEN p_from AND p_to AND discharge_type = 'referred'
  UNION ALL
  -- Bed-days come from the bed-day charges, so the statistic and the
  -- invoice can never disagree about how long somebody stayed.
  SELECT 'bed_days', coalesce(sum(quantity), 0) FROM public.hospital_charges
   WHERE kind = 'bed' AND charge_date BETWEEN p_from AND p_to
  UNION ALL
  SELECT 'outpatient_tickets', count(*)::numeric FROM public.opd_queue_tickets
   WHERE queue_date BETWEEN p_from AND p_to
  UNION ALL
  SELECT 'beds_available', count(*)::numeric FROM public.hospital_beds
  UNION ALL
  SELECT 'occupancy_pct',
         CASE WHEN (SELECT count(*) FROM public.hospital_beds) = 0 THEN 0
         ELSE round(coalesce((SELECT sum(quantity) FROM public.hospital_charges
                               WHERE kind = 'bed' AND charge_date BETWEEN p_from AND p_to), 0)
                    / ((SELECT count(*) FROM public.hospital_beds) * greatest(1, (p_to - p_from) + 1))
                    * 100, 1) END;
$$;

/** Admissions grouped for a return: sex, age band, ward, outcome.
 *  Age is computed AT ADMISSION, not today — a return covering last
 *  January must not age its patients by the time it is filed. */
DROP FUNCTION IF EXISTS public.admission_breakdown(date, date);
CREATE OR REPLACE FUNCTION public.admission_breakdown(p_from date, p_to date)
RETURNS TABLE (
  out_ward text, out_sex text, out_age_band text, out_outcome text, out_count integer
) LANGUAGE sql STABLE AS $$
  SELECT coalesce(w.name, '—'),
         coalesce(pt.sex, 'unknown'),
         CASE WHEN pt.dob IS NULL THEN 'unknown'
              WHEN a.admitted_at::date - pt.dob < 28 THEN '0-27d'
              WHEN a.admitted_at::date - pt.dob < 365 THEN '28d-1y'
              WHEN a.admitted_at::date - pt.dob < 1826 THEN '1-4y'
              WHEN a.admitted_at::date - pt.dob < 5478 THEN '5-14y'
              WHEN a.admitted_at::date - pt.dob < 18263 THEN '15-49y'
              WHEN a.admitted_at::date - pt.dob < 23742 THEN '50-64y'
              ELSE '65y+' END,
         coalesce(a.discharge_type, a.status),
         count(*)::integer
    FROM public.hospital_admissions a
    JOIN public.patients pt ON pt.id = a.patient_id
    LEFT JOIN LATERAL (
      SELECT b.ward_id FROM public.hospital_bed_placements pl
      JOIN public.hospital_beds b ON b.id = pl.bed_id
      WHERE pl.admission_id = a.id ORDER BY pl.from_ts LIMIT 1) fb ON true
    LEFT JOIN public.hospital_wards w ON w.id = fb.ward_id
   WHERE a.admitted_at::date BETWEEN p_from AND p_to
   GROUP BY 1, 2, 3, 4
   ORDER BY 1, 2, 3;
$$;

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================

ALTER TABLE public.payers            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payer_coverage    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_coverage  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payer_claims      ENABLE ROW LEVEL SECURITY;

DO $p$
DECLARE t text;
  v_read  text := 'Clinician,Nurse,Reception,Accountant,Manager';
  -- Who a patient's scheme is decides what they are charged, so changing
  -- it is a money decision, not a clinical one.
  v_write text := 'Reception,Accountant,Manager';
BEGIN
  FOREACH t IN ARRAY ARRAY['payers','payer_coverage','patient_coverage','payer_claims']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_read ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_read ON public.%I FOR SELECT TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))',
                   t, t, v_read);
    EXECUTE format('DROP POLICY IF EXISTS %I_write ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_write ON public.%I FOR ALL TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))  WITH CHECK (public.has_any_role(string_to_array(%L, '','')))',
                   t, t, v_write, v_write);
  END LOOP;
END $p$;
