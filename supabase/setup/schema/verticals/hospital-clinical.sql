-- =====================================================================
-- KAREYA SILO — HOSPITAL: ORDERS, OBSERVATIONS, MEDICATION ADMINISTRATION
-- ---------------------------------------------------------------------
-- Three gaps, in the order they hurt patients.
--
-- 1. THE ORDER LOOP IS OPEN. The Lab module is strong, but nothing tied a
--    doctor's request to an encounter and carried the result back. In
--    practice the order travels on paper, the result comes back on paper,
--    and somewhere in between it is lost. A result nobody reads is the
--    same as a test never done, except that it was paid for.
--
-- 2. NOBODY CHARTS OBSERVATIONS OVER TIME. `encounters` holds one set of
--    vitals per visit — right for an outpatient, useless for an inpatient
--    whose blood pressure is taken every four hours for six days. A
--    deteriorating patient is visible in the trend and invisible in the
--    latest reading.
--
-- 3. PRESCRIBING IS RECORDED; GIVING IS NOT. This is the classic harm
--    gap. Nothing showed whether the 08:00 dose was actually given, so
--    a missed dose and a double dose look identical afterwards.
--
-- SCOPE LIMIT, STATED DELIBERATELY. This does NOT do drug interaction
-- checking, dose-range checking, or any other clinical decision support.
-- That needs a licensed clinical knowledge base, and a half-remembered
-- one is more dangerous than none because it teaches staff to trust it.
-- The only safety check here is a literal match against the allergy text
-- somebody typed onto the patient record, and it is labelled as exactly
-- that wherever it surfaces.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.patients, public.employees, public.encounters,
--             public.prescriptions, public.has_any_role(text[]).
-- Optional:   public.hospital_admissions, public.hospital_charges,
--             public.lab_samples (linked when the ADT vertical is present).
-- =====================================================================

-- =====================================================================
-- 1. CLINICAL ORDERS  (the doctor asks for something)
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.clinical_orders (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid NOT NULL,
  admission_id uuid,
  encounter_id uuid,
  ordered_by uuid,
  ordered_at timestamp with time zone DEFAULT now(),
  category text DEFAULT 'lab'::text,        -- lab | radiology | procedure | nursing | diet | consult | other
  description text NOT NULL,
  detail text,
  urgency text DEFAULT 'routine'::text,     -- stat | urgent | routine
  status text DEFAULT 'ordered'::text,      -- ordered | collected | in_progress | resulted | cancelled
  -- Where the work ended up. lab_samples for a lab order; free for others.
  fulfilment_module text,
  fulfilment_id uuid,
  result_summary text,
  resulted_at timestamp with time zone,
  acknowledged_by uuid,                     -- the clinician who READ the result
  acknowledged_at timestamp with time zone,
  cancelled_reason text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT clinical_orders_pkey PRIMARY KEY (id),
  CONSTRAINT clinical_orders_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT clinical_orders_encounter_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT clinical_orders_by_fkey FOREIGN KEY (ordered_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT clinical_orders_ack_fkey FOREIGN KEY (acknowledged_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT clinical_orders_category_check CHECK (category = ANY (ARRAY['lab','radiology','procedure','nursing','diet','consult','other'])),
  CONSTRAINT clinical_orders_urgency_check CHECK (urgency = ANY (ARRAY['stat','urgent','routine'])),
  CONSTRAINT clinical_orders_status_check CHECK (status = ANY (ARRAY['ordered','collected','in_progress','resulted','cancelled'])),
  -- A resulted order has to say when, and a cancelled one has to say why.
  CONSTRAINT clinical_orders_resulted_check CHECK (status <> 'resulted' OR resulted_at IS NOT NULL),
  CONSTRAINT clinical_orders_cancelled_check CHECK (status <> 'cancelled' OR btrim(coalesce(cancelled_reason, '')) <> '')
);
CREATE INDEX IF NOT EXISTS idx_clinical_orders_patient ON public.clinical_orders (patient_id, ordered_at DESC);
CREATE INDEX IF NOT EXISTS idx_clinical_orders_admission ON public.clinical_orders (admission_id);
-- The queue that matters clinically: resulted but nobody has read it.
CREATE INDEX IF NOT EXISTS idx_clinical_orders_unacknowledged
  ON public.clinical_orders (resulted_at) WHERE status = 'resulted' AND acknowledged_at IS NULL;

DO $c$ BEGIN
  IF to_regclass('public.hospital_admissions') IS NOT NULL THEN
    ALTER TABLE public.clinical_orders ADD CONSTRAINT clinical_orders_admission_fkey
      FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** Order sets: the six things always ordered together for chest pain.
 *  Typing them one at a time is how one gets forgotten at 3am. */
CREATE TABLE IF NOT EXISTS public.order_sets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  name_kh text,
  category text DEFAULT 'lab'::text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT order_sets_pkey PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS public.order_set_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  order_set_id uuid NOT NULL,
  category text DEFAULT 'lab'::text,
  description text NOT NULL,
  detail text,
  urgency text DEFAULT 'routine'::text,
  sort_order integer DEFAULT 0,
  CONSTRAINT order_set_items_pkey PRIMARY KEY (id),
  CONSTRAINT order_set_items_set_fkey FOREIGN KEY (order_set_id) REFERENCES public.order_sets(id) ON DELETE CASCADE,
  CONSTRAINT order_set_items_category_check CHECK (category = ANY (ARRAY['lab','radiology','procedure','nursing','diet','consult','other'])),
  CONSTRAINT order_set_items_urgency_check CHECK (urgency = ANY (ARRAY['stat','urgent','routine']))
);
CREATE INDEX IF NOT EXISTS idx_order_set_items_set ON public.order_set_items (order_set_id, sort_order);

/** Place every order in a set at once. Returns how many were placed. */
CREATE OR REPLACE FUNCTION public.place_order_set(
  p_set uuid, p_patient uuid, p_admission uuid DEFAULT NULL,
  p_encounter uuid DEFAULT NULL, p_by uuid DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.order_sets WHERE id = p_set AND is_active) THEN
    RAISE EXCEPTION 'That order set does not exist or is not active';
  END IF;
  INSERT INTO public.clinical_orders
    (patient_id, admission_id, encounter_id, ordered_by, category, description, detail, urgency)
  SELECT p_patient, p_admission, p_encounter, p_by, i.category, i.description, i.detail, i.urgency
    FROM public.order_set_items i
   WHERE i.order_set_id = p_set
   ORDER BY i.sort_order;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

/** Record a result against an order. Acknowledgement is a SEPARATE act:
 *  a result sitting in the system is not a result somebody has read, and
 *  conflating the two is how an abnormal value goes unnoticed. */
CREATE OR REPLACE FUNCTION public.result_order(
  p_order uuid, p_summary text, p_module text DEFAULT NULL, p_fulfilment uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.clinical_orders
     SET status = 'resulted', result_summary = p_summary, resulted_at = now(),
         fulfilment_module = coalesce(p_module, fulfilment_module),
         fulfilment_id = coalesce(p_fulfilment, fulfilment_id)
   WHERE id = p_order AND status <> 'cancelled';
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found, or it was cancelled'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.acknowledge_order(p_order uuid, p_by uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.clinical_orders
     SET acknowledged_by = p_by, acknowledged_at = now()
   WHERE id = p_order AND status = 'resulted' AND acknowledged_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'That order has no unread result'; END IF;
END $$;

/** Results nobody has read yet, oldest first. This is a safety list, not
 *  a report — it is meant to be short and to be worked to zero. */
DROP FUNCTION IF EXISTS public.unacknowledged_results();
CREATE OR REPLACE FUNCTION public.unacknowledged_results()
RETURNS TABLE (
  out_order_id uuid, out_patient_id uuid, out_patient text, out_mrn text,
  out_description text, out_urgency text, out_result text,
  out_resulted_at timestamp with time zone, out_waiting_hours integer
) LANGUAGE sql STABLE AS $$
  SELECT o.id, p.id, btrim(p.first_name || ' ' || coalesce(p.last_name, '')), p.mrn,
         o.description, o.urgency, o.result_summary, o.resulted_at,
         (EXTRACT(EPOCH FROM (now() - o.resulted_at)) / 3600)::integer
    FROM public.clinical_orders o
    JOIN public.patients p ON p.id = o.patient_id
   WHERE o.status = 'resulted' AND o.acknowledged_at IS NULL
   ORDER BY CASE o.urgency WHEN 'stat' THEN 0 WHEN 'urgent' THEN 1 ELSE 2 END, o.resulted_at;
$$;

-- =====================================================================
-- 2. OBSERVATIONS  (the nurse charts what is happening)
-- ---------------------------------------------------------------------
-- One row per set of observations, many per admission. The point is the
-- trend: an early warning score computed from a single reading tells you
-- almost nothing, and from six hours of readings tells you to call
-- somebody.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.patient_observations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid NOT NULL,
  admission_id uuid,
  encounter_id uuid,
  observed_at timestamp with time zone DEFAULT now() NOT NULL,
  observed_by uuid,
  temp_c numeric,
  pulse integer,
  resp_rate integer,
  systolic integer,
  diastolic integer,
  spo2 integer,
  oxygen_therapy boolean,                   -- NULL = nobody recorded it, which is not the same as 'no'
  consciousness text,                       -- alert | voice | pain | unresponsive
  pain_score integer,
  blood_glucose numeric,
  urine_output_ml numeric,
  weight_kg numeric,
  news2 integer,                            -- computed, see below
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT patient_observations_pkey PRIMARY KEY (id),
  CONSTRAINT patient_observations_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT patient_observations_encounter_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT patient_observations_by_fkey FOREIGN KEY (observed_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT patient_observations_conscious_check CHECK (
    consciousness IS NULL OR consciousness = ANY (ARRAY['alert','voice','pain','unresponsive'])),
  CONSTRAINT patient_observations_pain_check CHECK (pain_score IS NULL OR pain_score BETWEEN 0 AND 10),
  CONSTRAINT patient_observations_spo2_check CHECK (spo2 IS NULL OR spo2 BETWEEN 0 AND 100)
);
-- An earlier revision defaulted this to false. Drop it: see the note on
-- news2_completeness below.
ALTER TABLE public.patient_observations ALTER COLUMN oxygen_therapy DROP DEFAULT;

CREATE INDEX IF NOT EXISTS idx_patient_observations_chart
  ON public.patient_observations (patient_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_patient_observations_admission
  ON public.patient_observations (admission_id, observed_at DESC);

DO $c$ BEGIN
  IF to_regclass('public.hospital_admissions') IS NOT NULL THEN
    ALTER TABLE public.patient_observations ADD CONSTRAINT patient_observations_admission_fkey
      FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** NEWS2 — the UK National Early Warning Score 2, published by the Royal
 *  College of Physicians and used unchanged in many hospitals.
 *
 *  This is ARITHMETIC over published bands, not clinical judgement: it
 *  adds up seven parameters and says how far from normal the set is. It
 *  is included because it is a fixed public scoring table that can be
 *  implemented exactly, unlike anything requiring a drug or diagnosis
 *  database. A missing parameter scores zero, so a partial observation
 *  UNDERSTATES the score — the UI has to say which parameters are
 *  missing rather than present the number as complete.
 *
 *  The scale-2 SpO2 bands (for chronic hypercapnic patients) are NOT
 *  implemented; this is scale 1 only. */
CREATE OR REPLACE FUNCTION public.news2_score(
  p_resp integer, p_spo2 integer, p_oxygen boolean, p_temp numeric,
  p_systolic integer, p_pulse integer, p_consciousness text
) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT
    -- respiration rate
    coalesce(CASE WHEN p_resp IS NULL THEN 0
                  WHEN p_resp <= 8 THEN 3
                  WHEN p_resp <= 11 THEN 1
                  WHEN p_resp <= 20 THEN 0
                  WHEN p_resp <= 24 THEN 2
                  ELSE 3 END, 0)
    -- oxygen saturation (scale 1)
  + coalesce(CASE WHEN p_spo2 IS NULL THEN 0
                  WHEN p_spo2 <= 91 THEN 3
                  WHEN p_spo2 <= 93 THEN 2
                  WHEN p_spo2 <= 95 THEN 1
                  ELSE 0 END, 0)
    -- supplemental oxygen
  + CASE WHEN coalesce(p_oxygen, false) THEN 2 ELSE 0 END
    -- temperature
  + coalesce(CASE WHEN p_temp IS NULL THEN 0
                  WHEN p_temp <= 35.0 THEN 3
                  WHEN p_temp <= 36.0 THEN 1
                  WHEN p_temp <= 38.0 THEN 0
                  WHEN p_temp <= 39.0 THEN 1
                  ELSE 2 END, 0)
    -- systolic blood pressure
  + coalesce(CASE WHEN p_systolic IS NULL THEN 0
                  WHEN p_systolic <= 90 THEN 3
                  WHEN p_systolic <= 100 THEN 2
                  WHEN p_systolic <= 110 THEN 1
                  WHEN p_systolic <= 219 THEN 0
                  ELSE 3 END, 0)
    -- pulse
  + coalesce(CASE WHEN p_pulse IS NULL THEN 0
                  WHEN p_pulse <= 40 THEN 3
                  WHEN p_pulse <= 50 THEN 1
                  WHEN p_pulse <= 90 THEN 0
                  WHEN p_pulse <= 110 THEN 1
                  WHEN p_pulse <= 130 THEN 2
                  ELSE 3 END, 0)
    -- consciousness: anything other than alert scores 3
  + CASE WHEN p_consciousness IS NULL OR p_consciousness = 'alert' THEN 0 ELSE 3 END;
$$;

CREATE OR REPLACE FUNCTION public.obs_score_news2()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.news2 := public.news2_score(NEW.resp_rate, NEW.spo2, NEW.oxygen_therapy,
                                  NEW.temp_c, NEW.systolic, NEW.pulse, NEW.consciousness);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_obs_score_news2 ON public.patient_observations;
CREATE TRIGGER trg_obs_score_news2
  BEFORE INSERT OR UPDATE ON public.patient_observations
  FOR EACH ROW EXECUTE FUNCTION public.obs_score_news2();

/** How many of the seven NEWS2 parameters were actually recorded.
 *
 *  A score of 2 from three parameters is not the same claim as a score of
 *  2 from seven, and the chart must not pretend otherwise.
 *
 *  `oxygen_therapy` is deliberately NULLable rather than defaulting to
 *  false. A default would make every observation look as though somebody
 *  had checked whether the patient was on oxygen, and this number would
 *  quietly overstate itself on exactly the sparse observations where
 *  honesty matters most. */
CREATE OR REPLACE FUNCTION public.news2_completeness(p_obs public.patient_observations)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT (CASE WHEN p_obs.resp_rate IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.spo2 IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.oxygen_therapy IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.temp_c IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.systolic IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.pulse IS NULL THEN 0 ELSE 1 END
        + CASE WHEN p_obs.consciousness IS NULL THEN 0 ELSE 1 END);
$$;

-- =====================================================================
-- 3. MEDICATION ADMINISTRATION RECORD
-- ---------------------------------------------------------------------
-- A prescription says what should happen. The MAR says what did. Without
-- the second one, a missed dose and a double dose leave identical
-- traces — which is to say, none.
--
-- Model: a prescription generates scheduled DUE slots; each slot is
-- either given, refused, held, or missed, by a named person, at a real
-- time. The slot is the unit, so "was the 08:00 dose given" has an
-- answer instead of an inference.
-- =====================================================================

ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS admission_id uuid;
ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS route text;          -- oral | IV | IM | SC | topical | other
ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS times_per_day integer;
ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS start_date date;
ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS end_date date;
ALTER TABLE public.prescriptions ADD COLUMN IF NOT EXISTS is_prn boolean DEFAULT false;  -- "as required"

DO $c$ BEGIN
  IF to_regclass('public.hospital_admissions') IS NOT NULL THEN
    ALTER TABLE public.prescriptions ADD CONSTRAINT prescriptions_admission_fkey
      FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE TABLE IF NOT EXISTS public.medication_administrations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  prescription_id uuid NOT NULL,
  patient_id uuid NOT NULL,
  admission_id uuid,
  due_at timestamp with time zone NOT NULL,
  status text DEFAULT 'due'::text,          -- due | given | refused | held | missed | cancelled
  given_at timestamp with time zone,
  given_by uuid,
  witnessed_by uuid,                        -- controlled drugs
  dose_given text,
  reason text,                              -- required for refused | held | missed
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT medication_administrations_pkey PRIMARY KEY (id),
  CONSTRAINT medication_administrations_rx_fkey FOREIGN KEY (prescription_id) REFERENCES public.prescriptions(id) ON DELETE CASCADE,
  CONSTRAINT medication_administrations_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT medication_administrations_by_fkey FOREIGN KEY (given_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT medication_administrations_witness_fkey FOREIGN KEY (witnessed_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT medication_administrations_status_check CHECK (status = ANY (ARRAY['due','given','refused','held','missed','cancelled'])),
  -- Given means somebody gave it, and we know who and when.
  CONSTRAINT medication_administrations_given_check CHECK (
    status <> 'given' OR (given_at IS NOT NULL AND given_by IS NOT NULL)),
  -- Not given means somebody said why. A blank reason is how a missed
  -- dose becomes invisible at handover.
  CONSTRAINT medication_administrations_reason_check CHECK (
    status NOT IN ('refused','held','missed') OR btrim(coalesce(reason, '')) <> '')
);
-- One slot per prescription per due time: generating the schedule twice
-- must not produce two 08:00 doses.
CREATE UNIQUE INDEX IF NOT EXISTS uq_medication_administrations_slot
  ON public.medication_administrations (prescription_id, due_at);
CREATE INDEX IF NOT EXISTS idx_medication_administrations_round
  ON public.medication_administrations (due_at) WHERE status = 'due';
CREATE INDEX IF NOT EXISTS idx_medication_administrations_admission
  ON public.medication_administrations (admission_id, due_at);

DO $c$ BEGIN
  IF to_regclass('public.hospital_admissions') IS NOT NULL THEN
    ALTER TABLE public.medication_administrations ADD CONSTRAINT medication_administrations_admission_fkey
      FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE SET NULL;
  END IF;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** Generate the due slots for a prescription over a date range.
 *
 *  Doses are spread across a 24-hour day from 08:00 — four times a day
 *  becomes 08:00, 14:00, 20:00, 02:00. That is a starting schedule a
 *  ward can adjust, not a clinical instruction. "As required" (PRN)
 *  prescriptions generate nothing: there is no due time for a dose that
 *  is given only when needed.
 *
 *  Idempotent by the unique index, so extending the range re-runs safely. */
CREATE OR REPLACE FUNCTION public.generate_mar_slots(
  p_prescription uuid, p_from date DEFAULT CURRENT_DATE, p_days integer DEFAULT 1
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rx public.prescriptions; v_per_day integer; v_gap interval; v_count integer;
BEGIN
  SELECT * INTO v_rx FROM public.prescriptions WHERE id = p_prescription;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prescription not found'; END IF;
  IF coalesce(v_rx.is_prn, false) THEN RETURN 0; END IF;
  IF v_rx.status <> 'active' THEN RAISE EXCEPTION 'That prescription is %, not active', v_rx.status; END IF;

  v_per_day := greatest(1, least(coalesce(v_rx.times_per_day, 1), 12));
  v_gap := (24.0 / v_per_day) * interval '1 hour';

  INSERT INTO public.medication_administrations (prescription_id, patient_id, admission_id, due_at)
  SELECT v_rx.id, v_rx.patient_id, v_rx.admission_id, slot
    FROM generate_series(
           (p_from + time '08:00') AT TIME ZONE current_setting('TimeZone'),
           ((p_from + greatest(1, p_days) * interval '1 day') + time '08:00') AT TIME ZONE current_setting('TimeZone'),
           v_gap) AS slot
   WHERE (v_rx.end_date IS NULL OR slot::date <= v_rx.end_date)
     AND (v_rx.start_date IS NULL OR slot::date >= v_rx.start_date)
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

/** Record that a dose was given.
 *  Refuses to sign the same slot twice — a second nurse arriving at the
 *  same slot must see that it is done rather than give it again. */
CREATE OR REPLACE FUNCTION public.administer_dose(
  p_slot uuid, p_by uuid, p_dose text DEFAULT NULL, p_witness uuid DEFAULT NULL, p_notes text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status text;
BEGIN
  SELECT status INTO v_status FROM public.medication_administrations WHERE id = p_slot FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That dose is not on the chart'; END IF;
  IF v_status = 'given' THEN RAISE EXCEPTION 'That dose is already signed as given'; END IF;
  IF v_status = 'cancelled' THEN RAISE EXCEPTION 'That dose was cancelled'; END IF;

  UPDATE public.medication_administrations
     SET status = 'given', given_at = now(), given_by = p_by,
         dose_given = coalesce(p_dose, dose_given),
         witnessed_by = coalesce(p_witness, witnessed_by),
         notes = coalesce(p_notes, notes)
   WHERE id = p_slot;
END $$;

/** Record that a dose was NOT given, with the reason. */
CREATE OR REPLACE FUNCTION public.withhold_dose(
  p_slot uuid, p_status text, p_reason text, p_by uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_status NOT IN ('refused','held','missed') THEN
    RAISE EXCEPTION 'A withheld dose must be refused, held or missed';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN
    RAISE EXCEPTION 'A reason is required when a dose is not given';
  END IF;
  UPDATE public.medication_administrations
     SET status = p_status, reason = p_reason, given_by = coalesce(p_by, given_by)
   WHERE id = p_slot AND status IN ('due','missed');
  IF NOT FOUND THEN RAISE EXCEPTION 'That dose is not outstanding'; END IF;
END $$;

/** Doses that fell past their due time and were never signed either way.
 *  This is the number a ward sister should see going up in real time. */
DROP FUNCTION IF EXISTS public.overdue_doses(integer);
CREATE OR REPLACE FUNCTION public.overdue_doses(p_grace_minutes integer DEFAULT 60)
RETURNS TABLE (
  out_slot_id uuid, out_patient_id uuid, out_patient text, out_mrn text,
  out_drug text, out_dose text, out_route text,
  out_due_at timestamp with time zone, out_late_minutes integer
) LANGUAGE sql STABLE AS $$
  SELECT m.id, p.id, btrim(p.first_name || ' ' || coalesce(p.last_name, '')), p.mrn,
         r.drug, r.dose, r.route, m.due_at,
         (EXTRACT(EPOCH FROM (now() - m.due_at)) / 60)::integer
    FROM public.medication_administrations m
    JOIN public.prescriptions r ON r.id = m.prescription_id
    JOIN public.patients p ON p.id = m.patient_id
   WHERE m.status = 'due'
     AND m.due_at < now() - (greatest(0, p_grace_minutes) * interval '1 minute')
   ORDER BY m.due_at;
$$;

/** A literal check of a drug name against the allergy text on the patient
 *  record. NOT a clinical decision support system.
 *
 *  It matches words, and it will both miss things (a brand name that does
 *  not contain the ingredient) and over-fire (a substring coincidence).
 *  Every caller must present it as "this patient's record mentions X",
 *  never as "this drug is unsafe". The honest limitation is the reason it
 *  is safe to ship: nobody can mistake it for pharmacology. */
DROP FUNCTION IF EXISTS public.allergy_text_match(uuid, text);
CREATE OR REPLACE FUNCTION public.allergy_text_match(p_patient uuid, p_drug text)
RETURNS TABLE (out_matched text, out_allergy_text text)
LANGUAGE sql STABLE AS $$
  WITH a AS (SELECT allergies FROM public.patients WHERE id = p_patient),
       w AS (SELECT lower(x) AS word
               FROM a, regexp_split_to_table(coalesce(a.allergies, ''), '[,;/\n]+') AS x
              WHERE btrim(x) <> '')
  SELECT btrim(w.word), (SELECT allergies FROM a)
    FROM w
   WHERE length(btrim(w.word)) >= 4
     AND position(btrim(w.word) IN lower(coalesce(p_drug, ''))) > 0;
$$;

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================

ALTER TABLE public.clinical_orders            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_sets                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_set_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_observations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_administrations ENABLE ROW LEVEL SECURITY;

DO $p$
DECLARE t text;
  -- Same roles as the existing clinical tables in RLS.sql. Reception can
  -- book and bill but has no business in a drug chart, so it is absent
  -- from both lists here.
  v_read  text := 'Clinician,Nurse,Manager';
  v_write text := 'Clinician,Nurse,Manager';
BEGIN
  FOREACH t IN ARRAY ARRAY['clinical_orders','order_sets','order_set_items',
                           'patient_observations','medication_administrations']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_read ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_read ON public.%I FOR SELECT TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))',
                   t, t, v_read);
    EXECUTE format('DROP POLICY IF EXISTS %I_write ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_write ON public.%I FOR ALL TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))  WITH CHECK (public.has_any_role(string_to_array(%L, '','')))',
                   t, t, v_write, v_write);
  END LOOP;
END $p$;
