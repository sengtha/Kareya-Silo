-- =====================================================================
-- KAREYA SILO — HOSPITAL: IDENTITY, QUEUE, ADMISSION / DISCHARGE / TRANSFER
-- ---------------------------------------------------------------------
-- The Clinic module is an outpatient EMR: a patient arrives, is seen,
-- is billed, goes home. A hospital is a different thing. A patient is
-- admitted, occupies a bed for days, is moved between wards, accrues
-- charges from six departments, and is discharged. None of that had
-- anywhere to live.
--
-- What actually makes hospital service bad is rarely the medicine. It is
-- that nobody can answer four questions quickly:
--
--   Who is this patient, and have we seen them before?
--   Whose turn is it?
--   Where is bed 12, and is it free?
--   What has this admission cost so far?
--
-- Each of the four sections below answers exactly one of those.
--
-- DESIGN NOTE — invariants live in the DATABASE, not in the UI. A bed
-- holding two patients, or a patient with two open admissions, is not a
-- display bug; it is a clinical incident. Those are partial unique
-- indexes here, so a race between two receptionists on two computers
-- fails loudly on one of them instead of silently corrupting the ward.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.patients, public.employees, public.encounters,
--             public.has_any_role(text[]).
-- =====================================================================

-- =====================================================================
-- 1. PATIENT IDENTITY
-- ---------------------------------------------------------------------
-- `patients.mrn` existed as a nullable free-text column with no
-- uniqueness and no generator, which means in practice it was blank or
-- hand-typed. Every other failure compounds from here: one patient with
-- five records has no history, and a doctor without history is working
-- blind however good they are.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.patient_number_series (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  prefix text DEFAULT 'MRN'::text,
  next_number integer DEFAULT 1,
  pad_width integer DEFAULT 6,
  CONSTRAINT patient_number_series_pkey PRIMARY KEY (id),
  CONSTRAINT patient_number_series_next_check CHECK (next_number >= 1),
  CONSTRAINT patient_number_series_pad_check CHECK (pad_width BETWEEN 3 AND 12)
);
-- Exactly one row. The partial unique index on a constant is the usual
-- way to say "singleton table" without a separate lock table.
CREATE UNIQUE INDEX IF NOT EXISTS uq_patient_number_series_singleton
  ON public.patient_number_series ((true));
INSERT INTO public.patient_number_series (prefix, next_number, pad_width)
SELECT 'MRN', 1, 6
WHERE NOT EXISTS (SELECT 1 FROM public.patient_number_series);

ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS national_id text;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS name_kh text;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS occupation text;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS commune text;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS district text;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS province text;
-- A merged record is kept, never deleted: a chart printed last year has
-- the old number on it, and somebody will look it up.
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS merged_into uuid;
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS merged_at timestamp with time zone;

DO $c$ BEGIN
  ALTER TABLE public.patients ADD CONSTRAINT patients_merged_into_fkey
    FOREIGN KEY (merged_into) REFERENCES public.patients(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- The LIMS identified its subjects by TYPED NAME (patient_name, patient_dob,
-- patient_ref) and never by id. That is defensible for a standalone lab
-- taking walk-ins, and useless inside a hospital: a result that cannot be
-- attached to a record is a result the ward has to go looking for, which
-- is the "results never reach the doctor" failure in its concrete form.
--
-- Nullable on purpose. A lab doing food and water samples has no patient
-- at all, and an existing clinical lab keeps working on typed names until
-- somebody links its history.
ALTER TABLE public.lab_samples ADD COLUMN IF NOT EXISTS patient_id uuid;
DO $c$ BEGIN
  ALTER TABLE public.lab_samples ADD CONSTRAINT lab_samples_patient_fkey
    FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;
CREATE INDEX IF NOT EXISTS idx_lab_samples_patient ON public.lab_samples (patient_id);

-- Two patients may share a name; none may share a number.
CREATE UNIQUE INDEX IF NOT EXISTS uq_patients_mrn
  ON public.patients (mrn) WHERE mrn IS NOT NULL AND mrn <> '';

/** Normalised name for matching: letters only, lowercased, collapsed.
 *  Deliberately crude — it is a candidate finder for a human to judge,
 *  never an automatic merge. */
CREATE OR REPLACE FUNCTION public.hosp_norm_name(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(lower(coalesce(p, '')), '[^a-zក-៿]+', '', 'g');
$$;

/** Phone reduced to its last 8 digits. Cambodian numbers get written
 *  +855 12 345 678, 012345678 and 12345678 by three different clerks. */
CREATE OR REPLACE FUNCTION public.hosp_norm_phone(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT right(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), 8);
$$;

CREATE INDEX IF NOT EXISTS idx_patients_norm_name
  ON public.patients (public.hosp_norm_name(first_name || coalesce(last_name, '')));
CREATE INDEX IF NOT EXISTS idx_patients_norm_phone
  ON public.patients (public.hosp_norm_phone(phone));

/** Allocate the next medical record number.
 *  Locks the singleton row, so two receptionists registering at the same
 *  moment queue rather than collide. */
CREATE OR REPLACE FUNCTION public.allocate_mrn()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.patient_number_series; v_out text;
BEGIN
  SELECT * INTO v_row FROM public.patient_number_series LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.patient_number_series DEFAULT VALUES RETURNING * INTO v_row;
  END IF;
  v_out := v_row.prefix || '-' || lpad(v_row.next_number::text, v_row.pad_width, '0');
  UPDATE public.patient_number_series SET next_number = next_number + 1 WHERE id = v_row.id;
  RETURN v_out;
END $$;

CREATE OR REPLACE FUNCTION public.patients_assign_mrn()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.mrn IS NULL OR btrim(NEW.mrn) = '' THEN
    NEW.mrn := public.allocate_mrn();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_patients_assign_mrn ON public.patients;
CREATE TRIGGER trg_patients_assign_mrn
  BEFORE INSERT ON public.patients
  FOR EACH ROW EXECUTE FUNCTION public.patients_assign_mrn();

/** Possible duplicates of a patient about to be registered.
 *
 *  Scored, not decided. The clerk sees the candidates and chooses; the
 *  system never merges on its own, because merging two people who merely
 *  share a name and a birth year is worse than holding two records for
 *  one person. */
DROP FUNCTION IF EXISTS public.patient_match_candidates(text, text, date, text);
CREATE OR REPLACE FUNCTION public.patient_match_candidates(
  p_first text, p_last text, p_dob date, p_phone text
) RETURNS TABLE (
  out_patient_id uuid, out_mrn text, out_name text, out_dob date,
  out_phone text, out_score integer, out_basis text
) LANGUAGE sql STABLE AS $$
  WITH probe AS (
    SELECT public.hosp_norm_name(coalesce(p_first, '') || coalesce(p_last, '')) AS n,
           public.hosp_norm_phone(p_phone) AS ph
  )
  SELECT p.id, p.mrn,
         btrim(p.first_name || ' ' || coalesce(p.last_name, '')),
         p.dob, p.phone,
         ( CASE WHEN public.hosp_norm_name(p.first_name || coalesce(p.last_name, '')) = probe.n
                     AND probe.n <> '' THEN 50 ELSE 0 END
         + CASE WHEN p.dob IS NOT NULL AND p_dob IS NOT NULL AND p.dob = p_dob THEN 30 ELSE 0 END
         + CASE WHEN probe.ph <> '' AND public.hosp_norm_phone(p.phone) = probe.ph THEN 40 ELSE 0 END
         )::integer,
         btrim(concat_ws(' + ',
           CASE WHEN public.hosp_norm_name(p.first_name || coalesce(p.last_name, '')) = probe.n
                     AND probe.n <> '' THEN 'name' END,
           CASE WHEN p.dob IS NOT NULL AND p_dob IS NOT NULL AND p.dob = p_dob THEN 'date of birth' END,
           CASE WHEN probe.ph <> '' AND public.hosp_norm_phone(p.phone) = probe.ph THEN 'phone' END))
  FROM public.patients p, probe
  WHERE p.merged_into IS NULL
    AND ( (public.hosp_norm_name(p.first_name || coalesce(p.last_name, '')) = probe.n AND probe.n <> '')
       OR (probe.ph <> '' AND public.hosp_norm_phone(p.phone) = probe.ph) )
  ORDER BY 6 DESC, p.created_at
  LIMIT 10;
$$;

/** Merge a duplicate into the surviving record.
 *
 *  Every table that references a patient has to be repointed. The list is
 *  written out rather than discovered, and the function RAISES if it
 *  finds a referencing table it was not told about — a silent miss here
 *  means a patient's history quietly disappears, which is the one
 *  outcome worse than the duplicate we set out to fix. */
CREATE OR REPLACE FUNCTION public.merge_patients(p_source uuid, p_target uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_known text[] := ARRAY['clinic_appointments','encounters','prescriptions','clinic_invoices',
                          'lab_samples','opd_queue_tickets','hospital_admissions','hospital_charges',
                          'patient_observations','medication_administrations','clinical_orders',
                          'patient_coverage','patients'];
  v_unknown text;
  v_table text;
BEGIN
  IF p_source = p_target THEN RAISE EXCEPTION 'Cannot merge a patient into itself'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = p_source) THEN
    RAISE EXCEPTION 'Source patient not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = p_target AND merged_into IS NULL) THEN
    RAISE EXCEPTION 'Target patient not found, or is itself merged'; END IF;

  -- Anything pointing at patients that this function does not handle.
  SELECT string_agg(DISTINCT c.relname, ', ') INTO v_unknown
  FROM pg_constraint fk
  JOIN pg_class c ON c.oid = fk.conrelid
  JOIN pg_class rc ON rc.oid = fk.confrelid
  WHERE fk.contype = 'f' AND rc.relname = 'patients'
    AND c.relname <> ALL (v_known);
  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION 'merge_patients does not know how to move: %. Add it to the list before merging.', v_unknown;
  END IF;

  -- Moved by name so the two hospital verticals stay order-independent:
  -- the clinical tables install after this one, and a merge attempted in
  -- between should move what exists rather than abort on what does not.
  FOREACH v_table IN ARRAY v_known LOOP
    CONTINUE WHEN v_table = 'patients';
    CONTINUE WHEN to_regclass('public.' || v_table) IS NULL;
    -- Belt and braces: the list above is maintained by hand, and a table
    -- that identifies its patient some other way would otherwise abort a
    -- merge halfway through.
    CONTINUE WHEN NOT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = v_table AND column_name = 'patient_id');
    EXECUTE format('UPDATE public.%I SET patient_id = $1 WHERE patient_id = $2', v_table)
      USING p_target, p_source;
  END LOOP;

  UPDATE public.patients
     SET merged_into = p_target, merged_at = now(),
         notes = btrim(coalesce(notes, '') || E'\n[merged into ' || p_target::text ||
                       coalesce(': ' || p_reason, '') || ']')
   WHERE id = p_source;
END $$;

-- =====================================================================
-- 2. DEPARTMENTS AND THE OUTPATIENT QUEUE
-- ---------------------------------------------------------------------
-- The most visible failure to a patient is not knowing whether they are
-- next or ninetieth. A ticket number costs nothing and changes the whole
-- feel of a morning.
--
-- Emergency cases jump. That is not a nicety — a queue that cannot be
-- jumped is a queue staff will abandon within a week, and then there is
-- no queue at all.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.hospital_departments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  name_kh text,
  kind text DEFAULT 'opd'::text,            -- opd | emergency | ward | theatre | lab | radiology | pharmacy | other
  queue_prefix text,                        -- letter shown on the ticket, e.g. 'A'
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hospital_departments_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_departments_kind_check CHECK (kind = ANY (ARRAY['opd','emergency','ward','theatre','lab','radiology','pharmacy','other']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hospital_departments_code ON public.hospital_departments (lower(code));

CREATE TABLE IF NOT EXISTS public.opd_queue_tickets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  department_id uuid NOT NULL,
  patient_id uuid,
  queue_date date DEFAULT CURRENT_DATE NOT NULL,
  ticket_no integer NOT NULL,
  ticket_label text,                        -- 'A-014' as shown on the slip
  priority text DEFAULT 'normal'::text,     -- emergency | urgent | normal
  status text DEFAULT 'waiting'::text,      -- waiting | called | serving | done | skipped | left
  reason text,
  called_at timestamp with time zone,
  served_by uuid,
  finished_at timestamp with time zone,
  encounter_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT opd_queue_tickets_pkey PRIMARY KEY (id),
  CONSTRAINT opd_queue_tickets_dept_fkey FOREIGN KEY (department_id) REFERENCES public.hospital_departments(id) ON DELETE CASCADE,
  CONSTRAINT opd_queue_tickets_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE SET NULL,
  CONSTRAINT opd_queue_tickets_served_by_fkey FOREIGN KEY (served_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT opd_queue_tickets_encounter_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT opd_queue_tickets_priority_check CHECK (priority = ANY (ARRAY['emergency','urgent','normal'])),
  CONSTRAINT opd_queue_tickets_status_check CHECK (status = ANY (ARRAY['waiting','called','serving','done','skipped','left']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_opd_queue_ticket_no
  ON public.opd_queue_tickets (department_id, queue_date, ticket_no);
CREATE INDEX IF NOT EXISTS idx_opd_queue_open
  ON public.opd_queue_tickets (department_id, queue_date, status);

/** Issue today's next ticket for a department. */
DROP FUNCTION IF EXISTS public.issue_queue_ticket(uuid, uuid, text, text);
CREATE OR REPLACE FUNCTION public.issue_queue_ticket(
  p_department uuid, p_patient uuid, p_priority text DEFAULT 'normal', p_reason text DEFAULT NULL
) RETURNS TABLE (out_ticket_id uuid, out_ticket_no integer, out_label text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dept public.hospital_departments; v_no integer; v_label text; v_id uuid;
BEGIN
  SELECT * INTO v_dept FROM public.hospital_departments WHERE id = p_department FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Department not found'; END IF;
  IF NOT v_dept.is_active THEN RAISE EXCEPTION 'Department % is not active', v_dept.name; END IF;

  SELECT coalesce(max(ticket_no), 0) + 1 INTO v_no
    FROM public.opd_queue_tickets
   WHERE department_id = p_department AND queue_date = CURRENT_DATE;

  v_label := coalesce(nullif(v_dept.queue_prefix, ''), upper(left(v_dept.code, 1))) || '-' || lpad(v_no::text, 3, '0');

  INSERT INTO public.opd_queue_tickets (department_id, patient_id, ticket_no, ticket_label, priority, reason)
  VALUES (p_department, p_patient, v_no, v_label, coalesce(p_priority, 'normal'), p_reason)
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id, v_no, v_label;
END $$;

/** Call the next waiting patient: emergency first, then urgent, then in
 *  the order they arrived. Returns nothing when the queue is empty. */
DROP FUNCTION IF EXISTS public.call_next_ticket(uuid, uuid);
CREATE OR REPLACE FUNCTION public.call_next_ticket(p_department uuid, p_employee uuid)
RETURNS TABLE (out_ticket_id uuid, out_label text, out_patient_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id
    FROM public.opd_queue_tickets
   WHERE department_id = p_department AND queue_date = CURRENT_DATE AND status = 'waiting'
   ORDER BY CASE priority WHEN 'emergency' THEN 0 WHEN 'urgent' THEN 1 ELSE 2 END, ticket_no
   FOR UPDATE SKIP LOCKED
   LIMIT 1;
  IF v_id IS NULL THEN RETURN; END IF;

  UPDATE public.opd_queue_tickets
     SET status = 'called', called_at = now(), served_by = p_employee
   WHERE id = v_id;

  RETURN QUERY SELECT t.id, t.ticket_label, t.patient_id FROM public.opd_queue_tickets t WHERE t.id = v_id;
END $$;

/** How long the queue is, and how long it has been waiting. */
DROP FUNCTION IF EXISTS public.queue_status(date);
CREATE OR REPLACE FUNCTION public.queue_status(p_date date DEFAULT CURRENT_DATE)
RETURNS TABLE (
  out_department_id uuid, out_department text, out_waiting integer,
  out_serving integer, out_done integer, out_longest_wait_min integer
) LANGUAGE sql STABLE AS $$
  SELECT d.id, d.name,
         count(*) FILTER (WHERE t.status = 'waiting')::integer,
         count(*) FILTER (WHERE t.status IN ('called','serving'))::integer,
         count(*) FILTER (WHERE t.status = 'done')::integer,
         coalesce(max(EXTRACT(EPOCH FROM (now() - t.created_at)) / 60)
                  FILTER (WHERE t.status = 'waiting'), 0)::integer
    FROM public.hospital_departments d
    LEFT JOIN public.opd_queue_tickets t
           ON t.department_id = d.id AND t.queue_date = p_date
   WHERE d.is_active
   GROUP BY d.id, d.name
   ORDER BY d.name;
$$;

-- =====================================================================
-- 3. WARDS, BEDS, ADMISSIONS
-- ---------------------------------------------------------------------
-- Bed state is DERIVED from placements, never typed in. A bed is
-- occupied because somebody is in it, and the only way to free it is to
-- move or discharge that person. Any other design drifts within a week
-- and then the board lies — which is worse than having no board.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.hospital_wards (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  department_id uuid,
  name text NOT NULL,
  name_kh text,
  kind text DEFAULT 'general'::text,        -- general | private | icu | maternity | paediatric | isolation | recovery
  floor text,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hospital_wards_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_wards_dept_fkey FOREIGN KEY (department_id) REFERENCES public.hospital_departments(id) ON DELETE SET NULL,
  CONSTRAINT hospital_wards_kind_check CHECK (kind = ANY (ARRAY['general','private','icu','maternity','paediatric','isolation','recovery']))
);

CREATE TABLE IF NOT EXISTS public.hospital_beds (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  ward_id uuid NOT NULL,
  code text NOT NULL,                       -- 'B-12'
  daily_rate numeric DEFAULT 0,
  status text DEFAULT 'available'::text,    -- available | occupied | cleaning | blocked | maintenance
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hospital_beds_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_beds_ward_fkey FOREIGN KEY (ward_id) REFERENCES public.hospital_wards(id) ON DELETE CASCADE,
  CONSTRAINT hospital_beds_rate_check CHECK (daily_rate >= 0),
  CONSTRAINT hospital_beds_status_check CHECK (status = ANY (ARRAY['available','occupied','cleaning','blocked','maintenance']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_hospital_beds_code ON public.hospital_beds (ward_id, lower(code));

CREATE TABLE IF NOT EXISTS public.hospital_admissions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  admission_no text,
  patient_id uuid NOT NULL,
  admitted_at timestamp with time zone DEFAULT now(),
  admitted_by uuid,
  attending_id uuid,
  source text DEFAULT 'opd'::text,          -- opd | emergency | referral | transfer_in | direct
  reason text,
  diagnosis text,
  status text DEFAULT 'admitted'::text,     -- admitted | discharged | absconded | deceased | transferred_out
  discharged_at timestamp with time zone,
  discharge_type text,                      -- recovered | improved | referred | against_advice | deceased
  discharge_summary text,
  deposit_id uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hospital_admissions_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_admissions_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT hospital_admissions_admitted_by_fkey FOREIGN KEY (admitted_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT hospital_admissions_attending_fkey FOREIGN KEY (attending_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT hospital_admissions_source_check CHECK (source = ANY (ARRAY['opd','emergency','referral','transfer_in','direct'])),
  CONSTRAINT hospital_admissions_status_check CHECK (status = ANY (ARRAY['admitted','discharged','absconded','deceased','transferred_out'])),
  CONSTRAINT hospital_admissions_discharge_check CHECK (
    discharge_type IS NULL OR discharge_type = ANY (ARRAY['recovered','improved','referred','against_advice','deceased'])),
  -- A discharged admission must say when.
  CONSTRAINT hospital_admissions_closed_check CHECK (
    (status = 'admitted' AND discharged_at IS NULL) OR (status <> 'admitted' AND discharged_at IS NOT NULL))
);
-- One open admission per patient. Two means somebody was admitted twice
-- and half their orders will go to the wrong chart.
CREATE UNIQUE INDEX IF NOT EXISTS uq_hospital_admissions_open_patient
  ON public.hospital_admissions (patient_id) WHERE status = 'admitted';
CREATE UNIQUE INDEX IF NOT EXISTS uq_hospital_admissions_no
  ON public.hospital_admissions (admission_no) WHERE admission_no IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.hospital_bed_placements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  admission_id uuid NOT NULL,
  bed_id uuid NOT NULL,
  from_ts timestamp with time zone DEFAULT now() NOT NULL,
  to_ts timestamp with time zone,
  reason text,
  CONSTRAINT hospital_bed_placements_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_bed_placements_admission_fkey FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE CASCADE,
  CONSTRAINT hospital_bed_placements_bed_fkey FOREIGN KEY (bed_id) REFERENCES public.hospital_beds(id) ON DELETE RESTRICT,
  CONSTRAINT hospital_bed_placements_span_check CHECK (to_ts IS NULL OR to_ts >= from_ts)
);
-- The two invariants that keep the ward board honest.
CREATE UNIQUE INDEX IF NOT EXISTS uq_bed_placement_open_bed
  ON public.hospital_bed_placements (bed_id) WHERE to_ts IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_bed_placement_open_admission
  ON public.hospital_bed_placements (admission_id) WHERE to_ts IS NULL;
CREATE INDEX IF NOT EXISTS idx_bed_placements_admission ON public.hospital_bed_placements (admission_id);

/** Bed status follows placement, both ways. A vacated bed goes to
 *  'cleaning' rather than straight to 'available' — housekeeping decides
 *  when it is ready, not the discharge clerk. */
CREATE OR REPLACE FUNCTION public.hosp_sync_bed_status()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.to_ts IS NULL THEN
    UPDATE public.hospital_beds SET status = 'occupied' WHERE id = NEW.bed_id;
  ELSIF TG_OP = 'UPDATE' AND OLD.to_ts IS NULL AND NEW.to_ts IS NOT NULL THEN
    UPDATE public.hospital_beds SET status = 'cleaning' WHERE id = NEW.bed_id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_hosp_sync_bed_status ON public.hospital_bed_placements;
CREATE TRIGGER trg_hosp_sync_bed_status
  AFTER INSERT OR UPDATE ON public.hospital_bed_placements
  FOR EACH ROW EXECUTE FUNCTION public.hosp_sync_bed_status();

/** Admit a patient into a named bed.
 *  Refuses a bed that is not free, and refuses a second open admission.
 *  Both are also enforced by index; the explicit checks exist to give a
 *  sentence a receptionist can act on rather than a constraint name. */
DROP FUNCTION IF EXISTS public.admit_patient(uuid, uuid, uuid, uuid, text, text, text);
CREATE OR REPLACE FUNCTION public.admit_patient(
  p_patient uuid, p_bed uuid, p_admitted_by uuid DEFAULT NULL, p_attending uuid DEFAULT NULL,
  p_source text DEFAULT 'opd', p_reason text DEFAULT NULL, p_diagnosis text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bed public.hospital_beds; v_admission uuid; v_no text; v_seq integer;
BEGIN
  -- Serialise number allocation. Counting rows to get the next number is
  -- a race between two admitting clerks; the unique index would catch it,
  -- but as a constraint violation rather than as a queue.
  PERFORM pg_advisory_xact_lock(hashtext('hospital_admission_no'));
  SELECT * INTO v_bed FROM public.hospital_beds WHERE id = p_bed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bed not found'; END IF;
  IF v_bed.status <> 'available' THEN
    RAISE EXCEPTION 'Bed % is %, not available', v_bed.code, v_bed.status;
  END IF;
  IF EXISTS (SELECT 1 FROM public.hospital_admissions WHERE patient_id = p_patient AND status = 'admitted') THEN
    RAISE EXCEPTION 'This patient already has an open admission';
  END IF;

  SELECT count(*) + 1 INTO v_seq FROM public.hospital_admissions
   WHERE admitted_at >= date_trunc('year', now());
  v_no := 'ADM-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  INSERT INTO public.hospital_admissions
    (admission_no, patient_id, admitted_by, attending_id, source, reason, diagnosis)
  VALUES (v_no, p_patient, p_admitted_by, p_attending, coalesce(p_source, 'opd'), p_reason, p_diagnosis)
  RETURNING id INTO v_admission;

  INSERT INTO public.hospital_bed_placements (admission_id, bed_id, reason)
  VALUES (v_admission, p_bed, 'admission');

  RETURN v_admission;
END $$;

/** Move a patient to another bed, keeping the history of where they were. */
CREATE OR REPLACE FUNCTION public.transfer_patient(
  p_admission uuid, p_new_bed uuid, p_reason text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bed public.hospital_beds;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.hospital_admissions WHERE id = p_admission AND status = 'admitted') THEN
    RAISE EXCEPTION 'That admission is not open';
  END IF;
  SELECT * INTO v_bed FROM public.hospital_beds WHERE id = p_new_bed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bed not found'; END IF;
  IF v_bed.status <> 'available' THEN
    RAISE EXCEPTION 'Bed % is %, not available', v_bed.code, v_bed.status;
  END IF;

  UPDATE public.hospital_bed_placements SET to_ts = now()
   WHERE admission_id = p_admission AND to_ts IS NULL;

  INSERT INTO public.hospital_bed_placements (admission_id, bed_id, reason)
  VALUES (p_admission, p_new_bed, coalesce(p_reason, 'transfer'));
END $$;

/** Discharge. Frees the bed to cleaning and closes the placement. */
CREATE OR REPLACE FUNCTION public.discharge_patient(
  p_admission uuid, p_type text DEFAULT 'recovered', p_summary text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.hospital_admissions WHERE id = p_admission AND status = 'admitted') THEN
    RAISE EXCEPTION 'That admission is not open';
  END IF;

  UPDATE public.hospital_bed_placements SET to_ts = now()
   WHERE admission_id = p_admission AND to_ts IS NULL;

  UPDATE public.hospital_admissions
     SET status = CASE WHEN p_type = 'deceased' THEN 'deceased' ELSE 'discharged' END,
         discharged_at = now(),
         discharge_type = coalesce(p_type, 'recovered'),
         discharge_summary = coalesce(p_summary, discharge_summary)
   WHERE id = p_admission;
END $$;

/** The ward board: every bed, who is in it, and for how long. */
DROP FUNCTION IF EXISTS public.ward_board();
CREATE OR REPLACE FUNCTION public.ward_board()
RETURNS TABLE (
  out_bed_id uuid, out_bed_code text, out_ward text, out_ward_kind text,
  out_status text, out_daily_rate numeric,
  out_admission_id uuid, out_patient_id uuid, out_patient_name text, out_mrn text,
  out_admitted_at timestamp with time zone, out_days integer, out_attending text
) LANGUAGE sql STABLE AS $$
  SELECT b.id, b.code, w.name, w.kind, b.status, b.daily_rate,
         a.id, p.id, btrim(p.first_name || ' ' || coalesce(p.last_name, '')), p.mrn,
         a.admitted_at,
         CASE WHEN a.id IS NULL THEN NULL
              ELSE greatest(1, (date_part('day', now() - a.admitted_at))::integer + 1) END,
         e.name
    FROM public.hospital_beds b
    JOIN public.hospital_wards w ON w.id = b.ward_id
    LEFT JOIN public.hospital_bed_placements pl ON pl.bed_id = b.id AND pl.to_ts IS NULL
    LEFT JOIN public.hospital_admissions a ON a.id = pl.admission_id AND a.status = 'admitted'
    LEFT JOIN public.patients p ON p.id = a.patient_id
    LEFT JOIN public.employees e ON e.id = a.attending_id
   WHERE w.is_active
   ORDER BY w.name, b.code;
$$;

-- =====================================================================
-- 4. CHARGE CAPTURE
-- ---------------------------------------------------------------------
-- A hospital bill assembled at discharge from paper scraps is both
-- under-billed and un-arguable. Charges are captured where they happen,
-- by whoever does the work, and the bill is a query over them.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.hospital_charges (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  patient_id uuid NOT NULL,
  admission_id uuid,                        -- null for an outpatient charge
  encounter_id uuid,
  department_id uuid,
  charge_date date DEFAULT CURRENT_DATE NOT NULL,
  kind text DEFAULT 'other'::text,          -- bed | consultation | procedure | lab | radiology | drug | consumable | other
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  amount numeric DEFAULT 0,
  source_module text,                       -- lab | pharmacy | radiology | manual
  source_id uuid,
  charged_by uuid,
  invoice_id uuid,                          -- set once billed; never cleared
  -- How the charge divides. These live HERE rather than in the payer
  -- vertical so that the discharge bill is scheme-aware whichever file
  -- installs first: with no payer, scheme_amount stays 0 and the patient
  -- owes the lot, which is exactly right for a self-paying hospital.
  scheme_amount numeric DEFAULT 0,
  patient_amount numeric DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT hospital_charges_pkey PRIMARY KEY (id),
  CONSTRAINT hospital_charges_patient_fkey FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE CASCADE,
  CONSTRAINT hospital_charges_admission_fkey FOREIGN KEY (admission_id) REFERENCES public.hospital_admissions(id) ON DELETE SET NULL,
  CONSTRAINT hospital_charges_encounter_fkey FOREIGN KEY (encounter_id) REFERENCES public.encounters(id) ON DELETE SET NULL,
  CONSTRAINT hospital_charges_dept_fkey FOREIGN KEY (department_id) REFERENCES public.hospital_departments(id) ON DELETE SET NULL,
  CONSTRAINT hospital_charges_invoice_fkey FOREIGN KEY (invoice_id) REFERENCES public.clinic_invoices(id) ON DELETE SET NULL,
  CONSTRAINT hospital_charges_by_fkey FOREIGN KEY (charged_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT hospital_charges_kind_check CHECK (kind = ANY (ARRAY['bed','consultation','procedure','lab','radiology','drug','consumable','other'])),
  CONSTRAINT hospital_charges_qty_check CHECK (quantity > 0)
);
ALTER TABLE public.hospital_charges ADD COLUMN IF NOT EXISTS scheme_amount numeric DEFAULT 0;
ALTER TABLE public.hospital_charges ADD COLUMN IF NOT EXISTS patient_amount numeric DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_hospital_charges_admission ON public.hospital_charges (admission_id);
CREATE INDEX IF NOT EXISTS idx_hospital_charges_unbilled
  ON public.hospital_charges (patient_id) WHERE invoice_id IS NULL;
-- One bed charge per admission per day, whatever happens. Re-running the
-- nightly job, or running it twice from two machines, cannot double-bill
-- a patient for the same night.
CREATE UNIQUE INDEX IF NOT EXISTS uq_hospital_charges_bed_day
  ON public.hospital_charges (admission_id, charge_date) WHERE kind = 'bed';

/** The two halves always add up to the whole. Whatever a scheme does not
 *  cover is the patient's, and there is nowhere for a rounding remainder
 *  to hide — that remainder is somebody's money.
 *
 *  A scheme share larger than the charge RAISES rather than being clamped
 *  down. Clamping was the first version and it was wrong: typing 999 for
 *  99 would have quietly set the patient's share to zero, which reads on
 *  every screen afterwards as though somebody had decided that. The
 *  legitimate paths cannot exceed the charge — covered_amount() bounds
 *  its own result — so anything that does is a mistake worth stopping. */
CREATE OR REPLACE FUNCTION public.hosp_charge_amount()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.amount := round(coalesce(NEW.quantity, 1) * coalesce(NEW.unit_price, 0), 2);
  NEW.scheme_amount := coalesce(NEW.scheme_amount, 0);
  IF NEW.scheme_amount < 0 THEN
    RAISE EXCEPTION 'A scheme cannot pay a negative amount';
  END IF;
  IF round(NEW.scheme_amount, 2) > round(NEW.amount, 2) THEN
    RAISE EXCEPTION 'The scheme share (%) is more than the charge (%). Recompute the coverage instead.',
      NEW.scheme_amount, NEW.amount;
  END IF;
  NEW.patient_amount := NEW.amount - NEW.scheme_amount;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_hosp_charge_amount ON public.hospital_charges;
CREATE TRIGGER trg_hosp_charge_amount
  BEFORE INSERT OR UPDATE OF quantity, unit_price, scheme_amount ON public.hospital_charges
  FOR EACH ROW EXECUTE FUNCTION public.hosp_charge_amount();

DO $c$ BEGIN
  ALTER TABLE public.hospital_charges ADD CONSTRAINT hospital_charges_split_check
    CHECK (scheme_amount >= 0 AND patient_amount >= 0
       AND round(scheme_amount + patient_amount, 2) = round(amount, 2));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

/** A billed charge is history. Editing one after it has been invoiced
 *  would silently change a document the patient is holding. */
CREATE OR REPLACE FUNCTION public.hosp_guard_billed_charge()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.invoice_id IS NOT NULL THEN
      RAISE EXCEPTION 'That charge is already on an invoice and cannot be deleted';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.invoice_id IS NOT NULL
     AND (NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.scheme_amount IS DISTINCT FROM OLD.scheme_amount
       OR NEW.patient_amount IS DISTINCT FROM OLD.patient_amount
       OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price IS DISTINCT FROM OLD.unit_price) THEN
    RAISE EXCEPTION 'That charge is already on an invoice and cannot be changed';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_hosp_guard_billed_charge ON public.hospital_charges;
CREATE TRIGGER trg_hosp_guard_billed_charge
  BEFORE UPDATE OR DELETE ON public.hospital_charges
  FOR EACH ROW EXECUTE FUNCTION public.hosp_guard_billed_charge();

/** Post one bed-day for every open admission.
 *  Idempotent by the unique index above, so it is safe to run on a timer,
 *  by hand, or twice. */
CREATE OR REPLACE FUNCTION public.post_bed_day_charges(p_date date DEFAULT CURRENT_DATE)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count integer;
BEGIN
  INSERT INTO public.hospital_charges
    (patient_id, admission_id, charge_date, kind, description, quantity, unit_price, source_module)
  SELECT a.patient_id, a.id, p_date, 'bed',
         w.name || ' · ' || b.code, 1, b.daily_rate, 'ward'
    FROM public.hospital_admissions a
    JOIN public.hospital_bed_placements pl ON pl.admission_id = a.id AND pl.to_ts IS NULL
    JOIN public.hospital_beds b ON b.id = pl.bed_id
    JOIN public.hospital_wards w ON w.id = b.ward_id
   WHERE a.status = 'admitted'
     AND a.admitted_at::date <= p_date
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

/** What this admission has cost so far, by kind. */
DROP FUNCTION IF EXISTS public.admission_charge_summary(uuid);
CREATE OR REPLACE FUNCTION public.admission_charge_summary(p_admission uuid)
RETURNS TABLE (out_kind text, out_lines integer, out_amount numeric)
LANGUAGE sql STABLE AS $$
  SELECT kind, count(*)::integer, sum(amount)
    FROM public.hospital_charges
   WHERE admission_id = p_admission
   GROUP BY kind
   ORDER BY sum(amount) DESC;
$$;

/** Turn the uninvoiced charges of an admission into one clinic invoice.
 *  Refuses to run twice: charges carry the invoice they went onto, and
 *  the guard above stops them being moved afterwards. */
CREATE OR REPLACE FUNCTION public.assemble_discharge_bill(p_admission uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_adm public.hospital_admissions; v_invoice uuid; v_total numeric;
BEGIN
  SELECT * INTO v_adm FROM public.hospital_admissions WHERE id = p_admission;
  IF NOT FOUND THEN RAISE EXCEPTION 'Admission not found'; END IF;

  -- The patient's share only. What a scheme covers is claimed from the
  -- scheme; putting it on the patient's invoice is how somebody entitled
  -- to free care ends up being asked for money.
  SELECT sum(patient_amount) INTO v_total
    FROM public.hospital_charges WHERE admission_id = p_admission AND invoice_id IS NULL;
  IF coalesce(v_total, 0) = 0 THEN
    RAISE EXCEPTION 'There is nothing left for the patient to pay on this admission';
  END IF;

  INSERT INTO public.clinic_invoices (patient_id, date, status, subtotal, tax, total, notes)
  VALUES (v_adm.patient_id, CURRENT_DATE, 'billed', v_total, 0, v_total,
          'Admission ' || coalesce(v_adm.admission_no, p_admission::text))
  RETURNING id INTO v_invoice;

  INSERT INTO public.clinic_invoice_items (invoice_id, description, kind, quantity, unit_price, amount)
  SELECT v_invoice,
         c.description || ' (' || to_char(c.charge_date, 'DD Mon') || ')',
         CASE c.kind WHEN 'drug' THEN 'medication'
                     WHEN 'bed' THEN 'service'
                     WHEN 'consumable' THEN 'service'
                     WHEN 'radiology' THEN 'procedure'
                     ELSE c.kind END,
         c.quantity, c.unit_price, c.patient_amount
    FROM public.hospital_charges c
   WHERE c.admission_id = p_admission AND c.invoice_id IS NULL AND c.patient_amount > 0
   ORDER BY c.charge_date, c.created_at;

  UPDATE public.hospital_charges SET invoice_id = v_invoice
   WHERE admission_id = p_admission AND invoice_id IS NULL;

  RETURN v_invoice;
END $$;

-- =====================================================================
-- ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
-- Clinical data is the most sensitive thing in the Silo. Read is open to
-- clinical staff; the destructive verbs are not.
-- =====================================================================

ALTER TABLE public.hospital_departments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opd_queue_tickets      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_wards         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_beds          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_admissions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_bed_placements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hospital_charges       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_number_series  ENABLE ROW LEVEL SECURITY;

DO $p$
DECLARE t text;
  -- Matches the roles the existing clinical tables already use in RLS.sql.
  -- Read is NOT open to every authenticated user: a hospital's patient
  -- list is the most sensitive table in the Silo, and the accountant who
  -- can see a bill has no business reading a ward round.
  v_read  text := 'Clinician,Nurse,Reception,Accountant,Manager';
  v_write text := 'Clinician,Nurse,Reception,Manager';
BEGIN
  FOREACH t IN ARRAY ARRAY['hospital_departments','opd_queue_tickets','hospital_wards','hospital_beds',
                           'hospital_admissions','hospital_bed_placements','hospital_charges']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_read ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_read ON public.%I FOR SELECT TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))',
                   t, t, v_read);

    EXECUTE format('DROP POLICY IF EXISTS %I_write ON public.%I', t, t);
    EXECUTE format('CREATE POLICY %I_write ON public.%I FOR ALL TO authenticated USING (public.has_any_role(string_to_array(%L, '','')))  WITH CHECK (public.has_any_role(string_to_array(%L, '','')))',
                   t, t,
                   CASE WHEN t = 'hospital_charges' THEN v_write || ',Accountant' ELSE v_write END,
                   CASE WHEN t = 'hospital_charges' THEN v_write || ',Accountant' ELSE v_write END);
  END LOOP;
END $p$;

DROP POLICY IF EXISTS patient_number_series_read ON public.patient_number_series;
CREATE POLICY patient_number_series_read ON public.patient_number_series
  FOR SELECT TO authenticated USING (public.has_any_role(ARRAY['Reception','Manager']));
DROP POLICY IF EXISTS patient_number_series_write ON public.patient_number_series;
CREATE POLICY patient_number_series_write ON public.patient_number_series
  FOR ALL TO authenticated
  USING (public.has_any_role(ARRAY['Admin','Founder']))
  WITH CHECK (public.has_any_role(ARRAY['Admin','Founder']));
