-- =====================================================================
-- HOSPITAL VERTICALS — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- These are not unit tests of convenience. Each one asserts something
-- that, if it broke, would be a clinical incident rather than a display
-- bug: a bed holding two patients, a dose signed twice, a billed charge
-- edited after the patient was given the invoice.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/hospital.test.sql
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
  EXCEPTION WHEN others THEN RAISE NOTICE '  ok   % (refused: %)', label, left(SQLERRM, 60); RETURN;
  END;
  RAISE EXCEPTION 'FAIL: % — it was ALLOWED', label;
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO employees (id, name, email, roles)
VALUES ('11111111-1111-1111-1111-111111111111', 'Dr Sok', 'sok@h.kh', ARRAY['Clinician']),
       ('22222222-2222-2222-2222-222222222222', 'Nurse Dara', 'dara@h.kh', ARRAY['Nurse'])
ON CONFLICT DO NOTHING;

\echo '== 1. patient identity'
INSERT INTO patients (id, first_name, last_name, dob, phone)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'Sreyla', 'Chan', '1990-05-04', '012 345 678');
INSERT INTO patients (id, first_name, last_name, dob, phone)
VALUES ('aaaaaaaa-0000-0000-0000-000000000002', 'Vithou', 'Kim', '1985-01-20', '077888999');

SELECT ok((SELECT mrn FROM patients WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'MRN-000001',
          'first patient gets MRN-000001');
SELECT ok((SELECT mrn FROM patients WHERE id = 'aaaaaaaa-0000-0000-0000-000000000002') = 'MRN-000002',
          'second patient gets MRN-000002');
SELECT raises($$INSERT INTO patients (first_name, mrn) VALUES ('Dup', 'MRN-000001')$$,
              'a duplicate MRN is refused');

-- phone written three different ways must normalise to the same thing
SELECT ok(hosp_norm_phone('+855 12 345 678') = hosp_norm_phone('012345678')
      AND hosp_norm_phone('012345678') = hosp_norm_phone('12345678'),
          'three spellings of one phone number normalise together');

SELECT ok((SELECT out_score FROM patient_match_candidates('Sreyla', 'Chan', '1990-05-04', '012345678')
            WHERE out_patient_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 120,
          'exact name + dob + phone scores 120');
SELECT ok((SELECT out_score FROM patient_match_candidates('Sreyla', 'Chan', '1999-01-01', NULL)
            WHERE out_patient_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 50,
          'name alone scores 50');
SELECT ok(NOT EXISTS (SELECT 1 FROM patient_match_candidates('Nobody', 'Here', NULL, NULL)),
          'an unrelated name finds no candidates');

\echo '== 2. queue'
INSERT INTO hospital_departments (id, code, name, kind, queue_prefix)
VALUES ('dddddddd-0000-0000-0000-000000000001', 'OPD', 'General OPD', 'opd', 'A');

SELECT ok((SELECT out_label FROM issue_queue_ticket('dddddddd-0000-0000-0000-000000000001',
             'aaaaaaaa-0000-0000-0000-000000000001', 'normal', 'fever')) = 'A-001',
          'first ticket of the day is A-001');
SELECT ok((SELECT out_label FROM issue_queue_ticket('dddddddd-0000-0000-0000-000000000001',
             'aaaaaaaa-0000-0000-0000-000000000002', 'normal', 'cough')) = 'A-002',
          'second ticket is A-002');
-- an emergency arriving third must be called first
SELECT out_ticket_id AS emergency_ticket FROM issue_queue_ticket(
  'dddddddd-0000-0000-0000-000000000001', NULL, 'emergency', 'chest pain') \gset

SELECT ok((SELECT out_label FROM call_next_ticket('dddddddd-0000-0000-0000-000000000001',
             '11111111-1111-1111-1111-111111111111')) = 'A-003',
          'the emergency case is called before the two waiting ahead of it');
SELECT ok((SELECT out_label FROM call_next_ticket('dddddddd-0000-0000-0000-000000000001',
             '11111111-1111-1111-1111-111111111111')) = 'A-001',
          'then the queue resumes in arrival order');
SELECT ok((SELECT out_waiting FROM queue_status(CURRENT_DATE)
            WHERE out_department_id = 'dddddddd-0000-0000-0000-000000000001') = 1,
          'one patient still waiting');

\echo '== 3. admission, transfer, discharge'
INSERT INTO hospital_wards (id, name, kind) VALUES ('cccccccc-0000-0000-0000-000000000001', 'Ward A', 'general');
INSERT INTO hospital_beds (id, ward_id, code, daily_rate) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'A-01', 25),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001', 'A-02', 25);

SELECT admit_patient('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001',
                     '22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
                     'opd', 'dengue', 'Dengue fever') AS adm \gset

SELECT ok((SELECT status FROM hospital_beds WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001') = 'occupied',
          'admitting marks the bed occupied');
SELECT ok((SELECT admission_no FROM hospital_admissions WHERE id = :'adm') LIKE 'ADM-%-00001',
          'admission number is allocated');

SELECT raises(format($$SELECT admit_patient('aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002')$$),
              'a patient cannot be admitted twice');
SELECT raises($$SELECT admit_patient('aaaaaaaa-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001')$$,
              'an occupied bed cannot take a second patient');
-- and the same must hold if somebody bypasses the function entirely
SELECT raises(format($$INSERT INTO hospital_bed_placements (admission_id, bed_id)
                       VALUES (%L, 'bbbbbbbb-0000-0000-0000-000000000001')$$, :'adm'),
              'the index refuses a second open placement on one bed');

SELECT transfer_patient(:'adm', 'bbbbbbbb-0000-0000-0000-000000000002', 'needs isolation');
SELECT ok((SELECT status FROM hospital_beds WHERE id = 'bbbbbbbb-0000-0000-0000-000000000001') = 'cleaning',
          'the vacated bed goes to cleaning, not straight to available');
SELECT ok((SELECT status FROM hospital_beds WHERE id = 'bbbbbbbb-0000-0000-0000-000000000002') = 'occupied',
          'the new bed is occupied');
SELECT ok((SELECT count(*) FROM hospital_bed_placements WHERE admission_id = :'adm') = 2,
          'both placements are kept as history');
SELECT ok((SELECT count(*) FROM hospital_bed_placements WHERE admission_id = :'adm' AND to_ts IS NULL) = 1,
          'exactly one placement is open');

SELECT ok((SELECT out_patient_name FROM ward_board() WHERE out_bed_code = 'A-02') = 'Sreyla Chan',
          'the ward board shows who is in bed A-02');
SELECT ok((SELECT out_patient_name FROM ward_board() WHERE out_bed_code = 'A-01') IS NULL,
          'and shows A-01 as empty');

\echo '== 4. charges'
SELECT ok(post_bed_day_charges(CURRENT_DATE) = 1, 'one bed-day posted for one open admission');
SELECT ok(post_bed_day_charges(CURRENT_DATE) = 0, 'running it again posts nothing (idempotent)');
SELECT ok((SELECT amount FROM hospital_charges WHERE admission_id = :'adm' AND kind = 'bed') = 25,
          'the bed charge is the bed rate');

INSERT INTO hospital_charges (patient_id, admission_id, kind, description, quantity, unit_price, source_module)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', :'adm', 'lab', 'Full blood count', 1, 12, 'lab');
SELECT ok((SELECT sum(out_amount) FROM admission_charge_summary(:'adm')) = 37,
          'charges total 37 across two kinds');

SELECT assemble_discharge_bill(:'adm') AS inv \gset
SELECT ok((SELECT total FROM clinic_invoices WHERE id = :'inv') = 37, 'the discharge bill totals 37');
SELECT ok((SELECT count(*) FROM clinic_invoice_items WHERE invoice_id = :'inv') = 2, 'with two lines');
SELECT ok((SELECT count(*) FROM hospital_charges WHERE admission_id = :'adm' AND invoice_id IS NULL) = 0,
          'every charge is marked billed');
SELECT raises(format($$SELECT assemble_discharge_bill(%L)$$, :'adm'),
              'billing the same admission twice is refused');
SELECT raises(format($$UPDATE hospital_charges SET unit_price = 999 WHERE admission_id = %L AND kind = 'lab'$$, :'adm'),
              'a billed charge cannot be edited');
SELECT raises(format($$DELETE FROM hospital_charges WHERE admission_id = %L AND kind = 'lab'$$, :'adm'),
              'a billed charge cannot be deleted');

SELECT discharge_patient(:'adm', 'recovered', 'Afebrile 48h');
SELECT ok((SELECT status FROM hospital_admissions WHERE id = :'adm') = 'discharged', 'the admission closes');
SELECT ok((SELECT status FROM hospital_beds WHERE id = 'bbbbbbbb-0000-0000-0000-000000000002') = 'cleaning',
          'discharge frees the bed to cleaning');
SELECT raises(format($$SELECT discharge_patient(%L)$$, :'adm'), 'discharging twice is refused');

\echo '== 5. NEWS2 (published worked examples)'
-- All parameters normal, no oxygen → 0
SELECT ok(news2_score(18, 97, false, 36.5, 120, 70, 'alert') = 0, 'a well patient scores 0');
-- RR 24 (2) + SpO2 92 (2) + on oxygen (2) + temp 38.5 (1) + SBP 95 (2) + HR 115 (2) + voice (3) = 14
SELECT ok(news2_score(24, 92, true, 38.5, 95, 115, 'voice') = 14, 'a peri-arrest set scores 14');
-- single-parameter boundaries
SELECT ok(news2_score(8,  97, false, 36.5, 120, 70, 'alert') = 3, 'RR 8 scores 3');
SELECT ok(news2_score(9,  97, false, 36.5, 120, 70, 'alert') = 1, 'RR 9 scores 1');
SELECT ok(news2_score(12, 97, false, 36.5, 120, 70, 'alert') = 0, 'RR 12 scores 0');
SELECT ok(news2_score(21, 97, false, 36.5, 120, 70, 'alert') = 2, 'RR 21 scores 2');
SELECT ok(news2_score(25, 97, false, 36.5, 120, 70, 'alert') = 3, 'RR 25 scores 3');
SELECT ok(news2_score(18, 97, false, 36.5, 220, 70, 'alert') = 3, 'SBP 220 scores 3 (hypertension counts)');
SELECT ok(news2_score(18, 97, false, 36.5, 120, 70, 'pain')  = 3, 'anything below alert scores 3');
-- a missing parameter must not invent a score
SELECT ok(news2_score(NULL, NULL, false, NULL, NULL, NULL, NULL) = 0, 'an empty observation scores 0, not an error');

INSERT INTO patient_observations (id, patient_id, resp_rate, spo2, oxygen_therapy, temp_c, systolic, pulse, consciousness, observed_by)
VALUES ('eeeeeeee-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        24, 92, true, 38.5, 95, 115, 'voice', '22222222-2222-2222-2222-222222222222');
SELECT ok((SELECT news2 FROM patient_observations WHERE id = 'eeeeeeee-0000-0000-0000-000000000001') = 14,
          'the trigger scores the row on insert');
SELECT ok((SELECT news2_completeness(o) FROM patient_observations o WHERE id = 'eeeeeeee-0000-0000-0000-000000000001') = 7,
          'a full set reports 7 of 7 parameters');
INSERT INTO patient_observations (id, patient_id, pulse)
VALUES ('eeeeeeee-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 115);
SELECT ok((SELECT news2_completeness(o) FROM patient_observations o WHERE id = 'eeeeeeee-0000-0000-0000-000000000002') = 1,
          'a pulse-only observation reports 1 of 7, so the score is not read as complete');
SELECT ok((SELECT news2 FROM patient_observations WHERE id = 'eeeeeeee-0000-0000-0000-000000000002') = 2,
          'and it scores 2 from that one parameter — an understatement, by design');

\echo '== 6. medication administration'
INSERT INTO prescriptions (id, patient_id, drug, dose, route, times_per_day, status, start_date)
VALUES ('ffffffff-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
        'Paracetamol', '1g', 'oral', 4, 'active', CURRENT_DATE);

SELECT ok(generate_mar_slots('ffffffff-0000-0000-0000-000000000001', CURRENT_DATE, 1) = 5,
          'four times a day over one day generates 5 slots (08:00 to 08:00 inclusive)');
SELECT ok(generate_mar_slots('ffffffff-0000-0000-0000-000000000001', CURRENT_DATE, 1) = 0,
          'regenerating the same range adds nothing');

INSERT INTO prescriptions (id, patient_id, drug, times_per_day, status, is_prn)
VALUES ('ffffffff-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001',
        'Morphine', 1, 'active', true);
SELECT ok(generate_mar_slots('ffffffff-0000-0000-0000-000000000002', CURRENT_DATE, 1) = 0,
          'an as-required drug generates no due slots');

SELECT id AS slot FROM medication_administrations
 WHERE prescription_id = 'ffffffff-0000-0000-0000-000000000001' ORDER BY due_at LIMIT 1 \gset

SELECT administer_dose(:'slot', '22222222-2222-2222-2222-222222222222', '1g');
SELECT ok((SELECT status FROM medication_administrations WHERE id = :'slot') = 'given', 'the dose is signed given');
SELECT raises(format($$SELECT administer_dose(%L, '22222222-2222-2222-2222-222222222222')$$, :'slot'),
              'the same dose cannot be signed twice');

SELECT id AS slot2 FROM medication_administrations
 WHERE prescription_id = 'ffffffff-0000-0000-0000-000000000001' AND status = 'due' ORDER BY due_at LIMIT 1 \gset
SELECT raises(format($$SELECT withhold_dose(%L, 'refused', '')$$, :'slot2'),
              'withholding without a reason is refused');
SELECT raises(format($$UPDATE medication_administrations SET status = 'refused', reason = NULL WHERE id = %L$$, :'slot2'),
              'the constraint refuses a reasonless refusal even by direct update');
SELECT withhold_dose(:'slot2', 'refused', 'Patient vomiting');
SELECT ok((SELECT reason FROM medication_administrations WHERE id = :'slot2') = 'Patient vomiting',
          'a refusal keeps its reason');

SELECT raises($$INSERT INTO medication_administrations (prescription_id, patient_id, due_at, status, given_at)
                VALUES ('ffffffff-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001',
                        now() + interval '5 days', 'given', now())$$,
              'given without a named giver is refused');

\echo '== 7. allergy text match (a string check, not pharmacology)'
UPDATE patients SET allergies = 'Penicillin, seafood' WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
SELECT ok(EXISTS (SELECT 1 FROM allergy_text_match('aaaaaaaa-0000-0000-0000-000000000001', 'Penicillin V 500mg')),
          'a recorded allergy matching the drug name is surfaced');
SELECT ok(NOT EXISTS (SELECT 1 FROM allergy_text_match('aaaaaaaa-0000-0000-0000-000000000001', 'Paracetamol')),
          'an unrelated drug does not match');
-- the honest limitation, asserted so nobody mistakes it for a safety net
SELECT ok(NOT EXISTS (SELECT 1 FROM allergy_text_match('aaaaaaaa-0000-0000-0000-000000000001', 'Amoxicillin')),
          'it MISSES a same-class drug under another name — it is a text match, nothing more');

\echo '== 8. orders'
INSERT INTO clinical_orders (id, patient_id, admission_id, ordered_by, category, description, urgency)
VALUES ('99999999-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', :'adm',
        '11111111-1111-1111-1111-111111111111', 'lab', 'Full blood count', 'stat');

SELECT raises($$UPDATE clinical_orders SET status = 'resulted'
                WHERE id = '99999999-0000-0000-0000-000000000001'$$,
              'an order cannot be resulted without a result time');
SELECT result_order('99999999-0000-0000-0000-000000000001', 'Hb 8.1 g/dL — low', 'lab', NULL);
SELECT ok((SELECT count(*) FROM unacknowledged_results()) = 1, 'the unread result appears on the safety list');
SELECT acknowledge_order('99999999-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
SELECT ok((SELECT count(*) FROM unacknowledged_results()) = 0, 'acknowledging clears it');
SELECT raises($$SELECT acknowledge_order('99999999-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111')$$,
              'acknowledging twice is refused');
SELECT raises($$UPDATE clinical_orders SET status = 'cancelled', cancelled_reason = ''
                WHERE id = '99999999-0000-0000-0000-000000000001'$$,
              'cancelling without a reason is refused');

INSERT INTO order_sets (id, name, category) VALUES ('88888888-0000-0000-0000-000000000001', 'Chest pain', 'lab');
INSERT INTO order_set_items (order_set_id, description, category, sort_order) VALUES
  ('88888888-0000-0000-0000-000000000001', 'Troponin', 'lab', 1),
  ('88888888-0000-0000-0000-000000000001', 'ECG', 'procedure', 2),
  ('88888888-0000-0000-0000-000000000001', 'Chest X-ray', 'radiology', 3);
SELECT ok(place_order_set('88888888-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
                          NULL, NULL, '11111111-1111-1111-1111-111111111111') = 3,
          'an order set places all three orders at once');

\echo '== 9. merge'
INSERT INTO patients (id, first_name, last_name, dob, phone)
VALUES ('aaaaaaaa-0000-0000-0000-000000000003', 'Sreyla', 'Chan', '1990-05-04', '012345678');
INSERT INTO clinical_orders (patient_id, category, description)
VALUES ('aaaaaaaa-0000-0000-0000-000000000003', 'lab', 'Urine dipstick');

SELECT merge_patients('aaaaaaaa-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'same person');
SELECT ok((SELECT merged_into FROM patients WHERE id = 'aaaaaaaa-0000-0000-0000-000000000003')
            = 'aaaaaaaa-0000-0000-0000-000000000001', 'the duplicate points at the survivor');
SELECT ok((SELECT count(*) FROM clinical_orders WHERE patient_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 0,
          'nothing is left behind on the merged record');
SELECT ok(EXISTS (SELECT 1 FROM clinical_orders WHERE patient_id = 'aaaaaaaa-0000-0000-0000-000000000001'
                    AND description = 'Urine dipstick'), 'the history moved to the survivor');
SELECT ok(NOT EXISTS (SELECT 1 FROM patient_match_candidates('Sreyla', 'Chan', '1990-05-04', NULL)
                       WHERE out_patient_id = 'aaaaaaaa-0000-0000-0000-000000000003'),
          'a merged record stops appearing as a candidate');
SELECT raises($$SELECT merge_patients('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
              'merging a patient into itself is refused');

-- The guard that matters: a NEW table referencing patients must stop the merge.
CREATE TABLE public.some_future_clinical_table (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid REFERENCES public.patients(id));
SELECT raises($$SELECT merge_patients('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
              'a table merge_patients has not been taught about blocks the merge');
DROP TABLE public.some_future_clinical_table;

\echo ''
\echo 'ALL HOSPITAL ASSERTIONS PASSED'

\echo '== 10. the lab is now attached to the patient index'
INSERT INTO lab_samples (id, accession_no, patient_id, patient_name, domain, status)
VALUES ('77777777-0000-0000-0000-000000000001', 'ACC-1', 'aaaaaaaa-0000-0000-0000-000000000001', 'Sreyla Chan', 'clinical', 'received');
SELECT ok((SELECT count(*) FROM lab_samples WHERE patient_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1,
          'a lab sample can be attached to a patient record by id, not by typed name');
