-- =====================================================================
-- LAB — limits, conformity and panels, for every kind of sample
--
-- The base lab_* tables assume one shape of laboratory. This adds the layer
-- that makes it usable by the four that actually exist in Cambodia — clinical,
-- food, water and materials — and fixes a correctness bug on the way.
--
-- THE BUG. lab_tests carries a single ref_low/ref_high for every patient.
-- Real clinical ranges move with sex and age: a child's alkaline phosphatase
-- is two to three times an adult's, haemoglobin differs by sex, creatinine by
-- both. With one flat range the system calls healthy children abnormal and
-- misses real anaemia in women — and it has been doing so on every result
-- already released.
--
-- THE GENERALISATION. A food or water laboratory has no patients and no age
-- bands. What it has is a SPECIFICATION — a national standard, a Codex limit,
-- a customer's contract — and a MATRIX, the material being tested. "Is this
-- normal for a 40-year-old woman" and "does this bottled water meet the
-- drinking water standard" are the same question asked of different
-- authorities, so both resolve through one function and both end in the same
-- place: a limit, and a verdict against it.
--
-- Which authority applies is decided by lab_samples.domain, not guessed from
-- the data. A blood sample and a well-water sample can both measure lead.
--
-- ESCALATION differs by domain and must not be conflated. A clinical critical
-- value means telephone a clinician now, and accreditation requires recording
-- that you did. An out-of-specification food result means the batch is held
-- and the customer is told — a different action, a different record, and it
-- attaches to a batch rather than a person.
--
-- Flagging happens in a TRIGGER, not only in the browser. The client-side
-- flagFor() was the sole implementation, so a result arriving by any other
-- route — an import, an instrument interface, a direct API call — was stored
-- with no flag at all. The database is the only place that sees every write.
--
-- Depends on: lab_tests, lab_samples, lab_orders, employees (base schema).
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What kind of sample this is.
--
-- Defaults to 'clinical' because every row that already exists is a patient
-- sample; a default of 'other' would silently strip demographic ranges from
-- live clinical data.
-- ---------------------------------------------------------------------
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS domain text NOT NULL DEFAULT 'clinical';

DO $$ BEGIN
  ALTER TABLE public.lab_samples ADD CONSTRAINT lab_samples_domain_check
    CHECK (domain = ANY (ARRAY['clinical','food','water','environment','material','agriculture','other']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- --- Clinical-only: whose sample it is -------------------------------
-- Sex and date of birth belong to a PATIENT, but this schema has no patient
-- table of its own — a sample carries patient_name / patient_ref, and the
-- clinic vertical owns patients when it is installed. Keeping them on the
-- sample lets the lab stand alone, and matches the paper request form the
-- receptionist is copying from.
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS patient_sex text;
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS patient_dob date;

DO $$ BEGIN
  ALTER TABLE public.lab_samples ADD CONSTRAINT lab_samples_patient_sex_check
    CHECK (patient_sex IS NULL OR patient_sex = ANY (ARRAY['M','F']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- --- Non-clinical: what the material is, and where it came from ------
-- A food or water result is meaningless without the batch it speaks for. If
-- a lot fails, the customer has to know exactly which production run to hold,
-- and that traceability is the deliverable as much as the number is.
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS matrix text;            -- 'drinking water', 'milled rice', 'fish sauce'
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS batch_no text;          -- lot / production run
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS manufacturer text;
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS sampling_point text;    -- tap, borehole, silo 3, intake
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS sampled_by text;        -- lab staff, or the client themselves
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS quantity_received text; -- '500 mL', '1 kg'

CREATE INDEX IF NOT EXISTS idx_lab_samples_domain ON public.lab_samples (domain);
CREATE INDEX IF NOT EXISTS idx_lab_samples_batch ON public.lab_samples (batch_no) WHERE batch_no IS NOT NULL;

-- ---------------------------------------------------------------------
-- Escalation thresholds on the test.
--
-- Separate from the reference range on purpose: a range says "outside
-- normal", a threshold says "act now". A result can be high without being
-- critical, and most are.
-- ---------------------------------------------------------------------
ALTER TABLE public.lab_tests ADD COLUMN IF NOT EXISTS critical_low numeric;
ALTER TABLE public.lab_tests ADD COLUMN IF NOT EXISTS critical_high numeric;

-- A meaningful change since this patient's last result for the same test.
-- Percent, and NULL to disable — for tests where a big swing is ordinary
-- (CRP, D-dimer) a delta check only cries wolf.
ALTER TABLE public.lab_tests ADD COLUMN IF NOT EXISTS delta_check_pct numeric;

-- The limit of detection. Below it a laboratory may not report a number, only
-- "< LOD" — reporting 0.0001 when the method cannot see below 0.001 is a
-- claim the lab cannot defend, and for food and water that is the claim a
-- regulator will challenge first.
ALTER TABLE public.lab_tests ADD COLUMN IF NOT EXISTS limit_of_detection numeric;

-- =====================================================================
-- Authority 1 — CLINICAL: demographic reference ranges
-- =====================================================================

/* Age is stored in DAYS, not years. Neonatal ranges change at 1 day, 7 days
 * and 30 days; years cannot express that, and bilirubin in the first week of
 * life is exactly where getting it wrong matters most.
 *
 * age_min_days is inclusive, age_max_days exclusive, so consecutive bands
 * written [0,30) [30,365) tile without a gap and without overlapping. */
CREATE TABLE IF NOT EXISTS public.lab_reference_ranges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  test_id uuid NOT NULL REFERENCES public.lab_tests(id) ON DELETE CASCADE,
  sex text NOT NULL DEFAULT 'any',          -- M | F | any
  age_min_days integer NOT NULL DEFAULT 0,
  age_max_days integer,                     -- NULL = no upper bound
  ref_low numeric,
  ref_high numeric,
  ref_text text,                            -- qualitative, e.g. 'Negative'
  note text,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_ref_ranges_sex_check CHECK (sex = ANY (ARRAY['M','F','any'])),
  CONSTRAINT lab_ref_ranges_age_order CHECK (age_max_days IS NULL OR age_max_days > age_min_days),
  -- A band with neither a bound nor a text is not a range, it is a typo.
  CONSTRAINT lab_ref_ranges_has_value CHECK (
    ref_low IS NOT NULL OR ref_high IS NOT NULL OR ref_text IS NOT NULL),
  -- One band per (test, sex, starting age): stops the common slip of entering
  -- the same band twice and then wondering which one applied.
  CONSTRAINT lab_ref_ranges_unique UNIQUE (test_id, sex, age_min_days)
);

CREATE INDEX IF NOT EXISTS idx_lab_ref_ranges_test ON public.lab_reference_ranges (test_id);

-- =====================================================================
-- Authority 2 — EVERYTHING ELSE: specifications and their limits
-- =====================================================================

/* A named, versioned standard a sample can be judged against.
 *
 * Versioned because standards are revised, and a certificate issued last year
 * has to keep saying which edition it was issued under. Superseding an edition
 * must never silently re-judge results already released. */
CREATE TABLE IF NOT EXISTS public.lab_specifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,                       -- 'Cambodian Drinking Water Quality Standard'
  name_kh text,
  version text,                             -- '2004', 'Rev. 3', 'Codex STAN 193-1995'
  issuer text,                              -- MISTI, MoH, Codex, the customer
  domain text NOT NULL DEFAULT 'other',
  matrix text,                              -- what it governs; NULL = any matrix
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_spec_domain_check CHECK (domain = ANY (
    ARRAY['clinical','food','water','environment','material','agriculture','other'])),
  CONSTRAINT lab_spec_unique UNIQUE (name, version)
);

/* One limit inside a specification.
 *
 * `absence_required` is the microbiological case and cannot be expressed as a
 * number: "E. coli absent in 100 mL" is a pass/fail on detection, not on a
 * value, and forcing it into max_value = 0 would make a legitimate "not
 * detected" look like a measured zero. */
CREATE TABLE IF NOT EXISTS public.lab_spec_limits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  spec_id uuid NOT NULL REFERENCES public.lab_specifications(id) ON DELETE CASCADE,
  test_id uuid NOT NULL REFERENCES public.lab_tests(id) ON DELETE CASCADE,
  matrix text,                              -- narrows within the spec; NULL = all
  min_value numeric,
  max_value numeric,
  absence_required boolean DEFAULT false,
  unit text,
  note text,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_spec_limits_has_value CHECK (
    min_value IS NOT NULL OR max_value IS NOT NULL OR absence_required),
  CONSTRAINT lab_spec_limits_unique UNIQUE (spec_id, test_id, matrix)
);

CREATE INDEX IF NOT EXISTS idx_lab_spec_limits_spec ON public.lab_spec_limits (spec_id);

-- Which specification this sample is being judged against.
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS spec_id uuid
  REFERENCES public.lab_specifications(id) ON DELETE SET NULL;

-- =====================================================================
-- Panels — an orderable group of tests. Applies to every domain: a potable
-- water suite is the same idea as a CBC.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.lab_panels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  name_kh text,
  code text,
  domain text NOT NULL DEFAULT 'clinical',
  category text,
  price numeric,                            -- NULL = charge the sum of parts
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  CONSTRAINT lab_panels_domain_check CHECK (domain = ANY (
    ARRAY['clinical','food','water','environment','material','agriculture','other']))
);

CREATE TABLE IF NOT EXISTS public.lab_panel_tests (
  panel_id uuid NOT NULL REFERENCES public.lab_panels(id) ON DELETE CASCADE,
  test_id uuid NOT NULL REFERENCES public.lab_tests(id) ON DELETE CASCADE,
  sort_order integer DEFAULT 0,
  PRIMARY KEY (panel_id, test_id)
);

-- =====================================================================
-- Verdict and escalation, on the order
-- =====================================================================

-- Conformity is the non-clinical verdict and is NOT a substitute for
-- result_flag — a report shows the number, the limit and the verdict.
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS conformity text;   -- pass | fail | NULL
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS is_critical boolean DEFAULT false;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS below_lod boolean DEFAULT false;

-- Clinical escalation: who was telephoned, by whom, when.
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS critical_notified_at timestamptz;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS critical_notified_to text;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS critical_notified_by uuid
  REFERENCES public.employees(id) ON DELETE SET NULL;

-- Non-clinical escalation: an out-of-specification result opens an
-- investigation. Different action, different record — a batch is held, not a
-- person telephoned — so it is a separate field rather than a reused one.
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS oos_investigation_ref text;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS oos_raised_at timestamptz;

-- Delta check (clinical): how far this moved from the patient's last result.
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS delta_pct numeric;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS delta_failed boolean DEFAULT false;

-- The limit that was actually applied. Stored, not recomputed: ranges and
-- specifications get edited, and a released report must keep saying what it
-- said when it was released.
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS applied_ref_low numeric;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS applied_ref_high numeric;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS applied_ref_text text;
ALTER TABLE public.lab_orders ADD COLUMN IF NOT EXISTS applied_source text;   -- sex+age | age | test | spec

DO $$ BEGIN
  ALTER TABLE public.lab_orders ADD CONSTRAINT lab_orders_conformity_check
    CHECK (conformity IS NULL OR conformity = ANY (ARRAY['pass','fail']));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_lab_orders_critical ON public.lab_orders (is_critical) WHERE is_critical;
CREATE INDEX IF NOT EXISTS idx_lab_orders_fail ON public.lab_orders (conformity) WHERE conformity = 'fail';

-- =====================================================================
-- Resolution — one function, two authorities
-- =====================================================================

/* The limit that applies to one sample for one test.
 *
 * Dispatches on the sample's domain, because the same analyte is judged by
 * different authorities depending on what it came out of: lead in blood is a
 * clinical reference range, lead in bottled water is a specification limit.
 *
 * CLINICAL resolution is most-specific-first and deterministic:
 *   1. a band matching the patient's sex AND age
 *   2. a band with sex 'any' matching the age
 *   3. the flat ref_low/ref_high on lab_tests
 * Ties inside a tier break to the NARROWEST age band, so a neonatal band
 * always beats a wide catch-all. With no date of birth on file, only an
 * unbounded band can honestly apply — guessing would mean judging a newborn
 * against an adult range.
 *
 * NON-CLINICAL resolution prefers a limit written for this exact matrix over
 * the specification's general one, then falls back to the flat range.
 *
 * Output columns are prefixed out_ because a bare `ref_low` in a RETURNS
 * TABLE shadows the identically named column in the queries below it. */
DROP FUNCTION IF EXISTS public.lab_limit_for(uuid, uuid);
CREATE OR REPLACE FUNCTION public.lab_limit_for(p_sample_id uuid, p_test_id uuid)
RETURNS TABLE (
  out_low numeric, out_high numeric, out_text text,
  out_absence boolean, out_source text
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  s record;
  v_age_days integer;
  v record;
BEGIN
  SELECT sm.domain, sm.patient_sex, sm.patient_dob, sm.matrix, sm.spec_id,
         COALESCE(sm.collected_at, sm.received_at, now()) AS at
    INTO s
  FROM public.lab_samples sm WHERE sm.id = p_sample_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::numeric, NULL::numeric, NULL::text, false, 'none'::text;
    RETURN;
  END IF;

  IF s.domain = 'clinical' THEN
    IF s.patient_dob IS NOT NULL THEN
      v_age_days := GREATEST(0, (s.at::date - s.patient_dob));
    END IF;

    SELECT r.ref_low, r.ref_high, r.ref_text,
           CASE WHEN r.sex <> 'any' THEN 'sex+age' ELSE 'age' END AS src
      INTO v
    FROM public.lab_reference_ranges r
    WHERE r.test_id = p_test_id
      AND (r.sex = 'any' OR (s.patient_sex IS NOT NULL AND r.sex = s.patient_sex))
      AND (
        (v_age_days IS NOT NULL
          AND v_age_days >= r.age_min_days
          AND (r.age_max_days IS NULL OR v_age_days < r.age_max_days))
        OR
        (v_age_days IS NULL AND r.age_min_days = 0 AND r.age_max_days IS NULL)
      )
    ORDER BY
      (r.sex <> 'any') DESC,                                      -- sex-specific first
      COALESCE(r.age_max_days, 2147483647) - r.age_min_days ASC,   -- narrowest band first
      r.age_min_days DESC
    LIMIT 1;

    IF FOUND THEN
      RETURN QUERY SELECT v.ref_low, v.ref_high, v.ref_text, false, v.src;
      RETURN;
    END IF;

  ELSIF s.spec_id IS NOT NULL THEN
    SELECT l.min_value, l.max_value, l.note, l.absence_required INTO v
    FROM public.lab_spec_limits l
    WHERE l.spec_id = s.spec_id
      AND l.test_id = p_test_id
      AND (l.matrix IS NULL OR l.matrix = s.matrix)
    ORDER BY (l.matrix IS NOT NULL) DESC     -- matrix-specific beats general
    LIMIT 1;

    IF FOUND THEN
      RETURN QUERY SELECT v.min_value, v.max_value, v.note, v.absence_required, 'spec'::text;
      RETURN;
    END IF;
  END IF;

  -- Fall back to the flat range on the test itself.
  RETURN QUERY
  SELECT t.ref_low, t.ref_high, t.ref_text, false, 'test'::text
  FROM public.lab_tests t WHERE t.id = p_test_id;
END $$;

/* The same patient's previous VERIFIED numeric result for this test.
 *
 * Identity is patient_ref (the MRN) and nothing else. Matching on name would
 * silently merge two people called Sok Dara, and a delta check that compares
 * the wrong patients is worse than none — so a sample with no patient_ref
 * gets no delta rather than a guessed one. */
CREATE OR REPLACE FUNCTION public.lab_previous_result(p_sample_id uuid, p_test_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v_ref text; v_at timestamptz; v_val numeric;
BEGIN
  SELECT s.patient_ref, COALESCE(s.collected_at, s.received_at)
    INTO v_ref, v_at
  FROM public.lab_samples s WHERE s.id = p_sample_id AND s.domain = 'clinical';

  IF v_ref IS NULL OR btrim(v_ref) = '' THEN RETURN NULL; END IF;

  SELECT o.result_value INTO v_val
  FROM public.lab_orders o
  JOIN public.lab_samples s2 ON s2.id = o.sample_id
  WHERE o.test_id = p_test_id
    AND o.sample_id <> p_sample_id
    AND s2.patient_ref = v_ref
    AND o.result_value IS NOT NULL
    AND o.status = 'verified'
    AND COALESCE(s2.collected_at, s2.received_at) < v_at
  ORDER BY COALESCE(s2.collected_at, s2.received_at) DESC
  LIMIT 1;

  RETURN v_val;
END $$;

-- =====================================================================
-- The trigger that grades a result
-- =====================================================================

/* Grade a result the moment it is stored, wherever it came from.
 *
 * Runs on INSERT and whenever result_value changes, so a corrected result is
 * re-graded — including clearing a critical flag that no longer applies,
 * which a one-way trigger would leave stuck on.
 *
 * A hand-set flag on a qualitative test is respected: this only computes when
 * there is a numeric value to compare. */
CREATE OR REPLACE FUNCTION public.lab_grade_result() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_domain text;
  v_low numeric; v_high numeric; v_text text; v_absence boolean; v_src text;
  v_clow numeric; v_chigh numeric; v_delta_pct numeric; v_lod numeric;
  v_prev numeric;
BEGIN
  IF NEW.result_value IS NULL THEN
    NEW.is_critical := false;
    NEW.conformity := NULL;
    NEW.below_lod := false;
    NEW.delta_pct := NULL;
    NEW.delta_failed := false;
    RETURN NEW;
  END IF;

  SELECT s.domain INTO v_domain FROM public.lab_samples s WHERE s.id = NEW.sample_id;

  SELECT l.out_low, l.out_high, l.out_text, l.out_absence, l.out_source
    INTO v_low, v_high, v_text, v_absence, v_src
  FROM public.lab_limit_for(NEW.sample_id, NEW.test_id) l;

  NEW.applied_ref_low  := v_low;
  NEW.applied_ref_high := v_high;
  NEW.applied_ref_text := v_text;
  NEW.applied_source   := v_src;

  SELECT t.critical_low, t.critical_high, t.delta_check_pct, t.limit_of_detection
    INTO v_clow, v_chigh, v_delta_pct, v_lod
  FROM public.lab_tests t WHERE t.id = NEW.test_id;

  -- Below the limit of detection the number is not reportable as a number.
  NEW.below_lod := (v_lod IS NOT NULL AND NEW.result_value < v_lod);

  -- Flag against whichever limit resolved. Same arithmetic for both
  -- authorities — only the source of the bounds differs.
  IF v_low IS NULL AND v_high IS NULL THEN
    NEW.result_flag := COALESCE(NEW.result_flag, 'normal');
  ELSIF v_low IS NOT NULL AND NEW.result_value < v_low THEN
    NEW.result_flag := 'low';
  ELSIF v_high IS NOT NULL AND NEW.result_value > v_high THEN
    NEW.result_flag := 'high';
  ELSE
    NEW.result_flag := 'normal';
  END IF;

  IF v_domain = 'clinical' THEN
    NEW.conformity := NULL;   -- a patient does not "conform"

    -- Critical is independent of the range: a value can sit inside a wide
    -- reference interval and still be a panic value.
    NEW.is_critical := (v_clow IS NOT NULL AND NEW.result_value <= v_clow)
                    OR (v_chigh IS NOT NULL AND NEW.result_value >= v_chigh);

    -- A result that is no longer critical must not keep a stale
    -- acknowledgement, or the next reader believes a call was made about THIS
    -- value when it was made about the one before the correction.
    IF NOT NEW.is_critical THEN
      NEW.critical_notified_at := NULL;
      NEW.critical_notified_to := NULL;
      NEW.critical_notified_by := NULL;
    END IF;

    NEW.delta_pct := NULL;
    NEW.delta_failed := false;
    IF v_delta_pct IS NOT NULL THEN
      v_prev := public.lab_previous_result(NEW.sample_id, NEW.test_id);
      IF v_prev IS NOT NULL AND v_prev <> 0 THEN
        NEW.delta_pct := ROUND(ABS(NEW.result_value - v_prev) / ABS(v_prev) * 100, 1);
        NEW.delta_failed := NEW.delta_pct > v_delta_pct;
      END IF;
    END IF;

  ELSE
    NEW.is_critical := false;
    NEW.delta_pct := NULL;
    NEW.delta_failed := false;

    -- Conformity, only where there is something to conform TO. A test run
    -- without a specification gets no verdict rather than a default pass —
    -- "pass" on a page is a claim, and an unjudged result has not earned it.
    IF v_absence THEN
      -- Detected at all is a failure: absence was required.
      NEW.conformity := CASE WHEN COALESCE(NEW.below_lod, false) THEN 'pass' ELSE 'fail' END;
    ELSIF v_low IS NULL AND v_high IS NULL THEN
      NEW.conformity := NULL;
    ELSE
      NEW.conformity := CASE WHEN NEW.result_flag = 'normal' THEN 'pass' ELSE 'fail' END;
    END IF;

    IF NEW.conformity = 'fail' AND NEW.oos_raised_at IS NULL THEN
      NEW.oos_raised_at := now();
    ELSIF NEW.conformity IS DISTINCT FROM 'fail' THEN
      NEW.oos_raised_at := NULL;
      NEW.oos_investigation_ref := NULL;
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_lab_grade_result ON public.lab_orders;
CREATE TRIGGER trg_lab_grade_result
  BEFORE INSERT OR UPDATE OF result_value ON public.lab_orders
  FOR EACH ROW EXECUTE FUNCTION public.lab_grade_result();

/* An escalated result may not be verified until it has been handled.
 *
 * This is the whole point of recording the handling. Without the guard it is
 * a field people forget, and the audit discovers a year later that nobody was
 * ever called and no batch was ever held. */
CREATE OR REPLACE FUNCTION public.lab_guard_escalation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'verified' AND COALESCE(OLD.status, '') <> 'verified' THEN
    IF NEW.is_critical AND NEW.critical_notified_at IS NULL THEN
      RAISE EXCEPTION
        'Critical result must be reported to the requesting clinician before it can be verified';
    END IF;
    IF NEW.conformity = 'fail' AND COALESCE(btrim(NEW.oos_investigation_ref), '') = '' THEN
      RAISE EXCEPTION
        'Out-of-specification result needs an investigation reference before it can be verified';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_lab_guard_critical_verify ON public.lab_orders;
DROP TRIGGER IF EXISTS trg_lab_guard_escalation ON public.lab_orders;
CREATE TRIGGER trg_lab_guard_escalation
  BEFORE UPDATE ON public.lab_orders
  FOR EACH ROW EXECUTE FUNCTION public.lab_guard_escalation();

-- =====================================================================
-- Ordering a panel
-- =====================================================================

/* Add every active test in a panel to a sample, skipping any already ordered.
 *
 * ON CONFLICT is not available — lab_orders has no unique key on
 * (sample_id, test_id), and adding one would forbid the legitimate case of
 * repeating a test on the same sample after a repeat run. So the skip is an
 * explicit NOT EXISTS. Returns how many were actually added. */
CREATE OR REPLACE FUNCTION public.lab_order_panel(p_sample_id uuid, p_panel_id uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_added integer;
BEGIN
  INSERT INTO public.lab_orders (sample_id, test_id, status)
  SELECT p_sample_id, pt.test_id, 'pending'
  FROM public.lab_panel_tests pt
  JOIN public.lab_tests t ON t.id = pt.test_id AND t.is_active
  WHERE pt.panel_id = p_panel_id
    AND NOT EXISTS (
      SELECT 1 FROM public.lab_orders o
      WHERE o.sample_id = p_sample_id AND o.test_id = pt.test_id
    );
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $$;

/* Whether a whole sample conforms — the line that goes on a certificate of
 * analysis. Any failing test fails the sample; a sample with nothing judged
 * returns NULL rather than 'pass', for the same reason as above. */
CREATE OR REPLACE FUNCTION public.lab_sample_conformity(p_sample_id uuid)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN count(*) FILTER (WHERE o.conformity = 'fail') > 0 THEN 'fail'
           WHEN count(*) FILTER (WHERE o.conformity = 'pass') > 0 THEN 'pass'
           ELSE NULL
         END
  FROM public.lab_orders o WHERE o.sample_id = p_sample_id;
$$;

-- =====================================================================
-- RLS — same shape as the rest of the Silo.
-- =====================================================================
ALTER TABLE public.lab_reference_ranges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_specifications   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_spec_limits      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_panels           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_panel_tests      ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'lab_reference_ranges','lab_specifications','lab_spec_limits',
    'lab_panels','lab_panel_tests']) AS t
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.t || '_rw', r.t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)',
      r.t || '_rw', r.t);
  END LOOP;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.lab_reference_ranges, public.lab_specifications, public.lab_spec_limits,
  public.lab_panels, public.lab_panel_tests
  TO authenticated;
