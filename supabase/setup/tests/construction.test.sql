-- =====================================================================
-- CONSTRUCTION ESTIMATING — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- construction_boq was item_no, description, unit, quantity, unit_rate,
-- amount: a spreadsheet with a border round it. These assertions are about
-- the things a building estimate needs that a flat list cannot hold.
--
-- The central one is the rate build-up. A rate for concrete is not a
-- number somebody remembered; it is cement plus sand plus aggregate plus
-- labour plus plant, each with its own wastage. The test that matters most
-- below is the one where the price of cement moves and the bill can say
-- exactly what that did to the tender.
--
-- The figures used here are arbitrary and chosen to make the arithmetic
-- checkable by hand. They are NOT a price book and nothing should be
-- quoted from them.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/construction.test.sql
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

CREATE OR REPLACE FUNCTION act_as(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT user_id INTO v_uid FROM employees WHERE email = p_email;
  PERFORM set_config('request.jwt.claims', json_build_object('email', p_email)::text, false);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), false);
END $$;

-- ---------------------------------------------------------------- setup
INSERT INTO auth.users (id, email) VALUES
  ('c0100000-0000-0000-0000-000000000001', 'sarin@build.kh'),
  ('c0100000-0000-0000-0000-000000000002', 'phalla@build.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('c0200000-0000-0000-0000-000000000001', 'c0100000-0000-0000-0000-000000000001', 'Sarin (estimator)', 'sarin@build.kh',  ARRAY['Site Manager']),
  ('c0200000-0000-0000-0000-000000000002', 'c0100000-0000-0000-0000-000000000002', 'Phalla (driver)',   'phalla@build.kh', ARRAY['Driver'])
ON CONFLICT DO NOTHING;

SELECT act_as('sarin@build.kh');

-- A deliberately simple price book, sized so every total below can be
-- checked on paper.
INSERT INTO estimate_resources (id, code, name, resource_type, unit, unit_cost, price_source) VALUES
  ('c0300000-0000-0000-0000-000000000001', 'MAT-CEM', 'Cement 50kg',      'material', 'bag',  10.00, 'Supplier quotation, kept on file'),
  ('c0300000-0000-0000-0000-000000000002', 'MAT-SND', 'River sand',       'material', 'm3',   20.00, 'Supplier quotation, kept on file'),
  ('c0300000-0000-0000-0000-000000000003', 'MAT-AGG', 'Crushed stone',    'material', 'm3',   30.00, 'Supplier quotation, kept on file'),
  ('c0300000-0000-0000-0000-000000000004', 'LAB-MAS', 'Mason',            'labour',   'hour',  2.50, 'Own payroll'),
  ('c0300000-0000-0000-0000-000000000005', 'LAB-GEN', 'General labourer', 'labour',   'hour',  1.50, 'Own payroll'),
  ('c0300000-0000-0000-0000-000000000006', 'PLT-MIX', 'Concrete mixer',   'plant',    'hour',  4.00, 'Own plant, hourly running cost')
ON CONFLICT DO NOTHING;

\echo ''
\echo '== 1. the price book keeps its own history'

SELECT ok((SELECT count(*) FROM resource_price_history WHERE resource_id = 'c0300000-0000-0000-0000-000000000001') = 1,
  'putting a resource in the book records its opening price');
SELECT ok((SELECT new_cost FROM resource_price_history WHERE resource_id = 'c0300000-0000-0000-0000-000000000001') = 10.00,
  'at the figure entered');
SELECT ok((SELECT old_cost FROM resource_price_history WHERE resource_id = 'c0300000-0000-0000-0000-000000000001') IS NULL,
  'with nothing before it');
SELECT ok((SELECT changed_by FROM resource_price_history WHERE resource_id = 'c0300000-0000-0000-0000-000000000001')
          = 'c0200000-0000-0000-0000-000000000001',
  'and who entered it');

SELECT raises($$UPDATE resource_price_history SET new_cost = 1$$,
  'a price change record cannot be edited');
SELECT raises($$DELETE FROM resource_price_history$$,
  'nor removed');

\echo ''
\echo '== 2. THE HEADLINE: a rate is built up, not remembered'

INSERT INTO rate_templates (id, code, description, unit, trade)
VALUES ('c0400000-0000-0000-0000-000000000001', 'C-25', 'Concrete grade 25, placed and compacted', 'm3', 'Concrete');

-- Deliberately round numbers. Cement: 7 bags x 1.05 wastage x 10.00 = 73.50
-- Sand:      0.5 m3 x 1.10 x 20.00 = 11.00
-- Aggregate: 0.8 m3 x 1.10 x 30.00 = 26.40
-- Mason:     2 h x 2.50            =  5.00
-- Labourer:  4 h x 1.50            =  6.00
-- Mixer:     0.5 h x 4.00          =  2.00
--                    material 110.90 | labour 11.00 | plant 2.00 | total 123.90
INSERT INTO rate_components (template_id, resource_id, quantity_per_unit, wastage_percent, sort_order) VALUES
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000001', 7,   5,  1),
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000002', 0.5, 10, 2),
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000003', 0.8, 10, 3),
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000004', 2,   0,  4),
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000005', 4,   0,  5),
  ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000006', 0.5, 0,  6);

SELECT ok((SELECT out_material FROM rate_template_cost('c0400000-0000-0000-0000-000000000001')) = 110.90,
  'material comes to 110.90 a cubic metre, wastage included');
SELECT ok((SELECT out_labour FROM rate_template_cost('c0400000-0000-0000-0000-000000000001')) = 11.00,
  'labour to 11.00');
SELECT ok((SELECT out_plant FROM rate_template_cost('c0400000-0000-0000-0000-000000000001')) = 2.00,
  'plant to 2.00');
SELECT ok((SELECT out_total FROM rate_template_cost('c0400000-0000-0000-0000-000000000001')) = 123.90,
  'and the rate costs 123.90 — a number with six things behind it, not one somebody typed');

SELECT ok((SELECT count(*) FROM rate_build_up('c0400000-0000-0000-0000-000000000001')) = 6,
  'the build-up sheet shows every line');
SELECT ok((SELECT out_gross_qty FROM rate_build_up('c0400000-0000-0000-0000-000000000001')
            WHERE out_resource = 'Cement 50kg') = 7.35,
  '7 bags at 5% wastage is 7.35 bags actually bought');
SELECT ok((SELECT sum(out_line_cost) FROM rate_build_up('c0400000-0000-0000-0000-000000000001')) = 123.90,
  'and the sheet adds up to the rate');

SELECT raises($$
  INSERT INTO rate_components (template_id, resource_id, quantity_per_unit, wastage_percent)
  VALUES ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000001', 1, 150)
$$, 'a wastage of 150% is refused — that is not wastage, that is a typo');

\echo ''
\echo '== 3. cost and price are different numbers'

INSERT INTO construction_estimates (id, title, client_name, overhead_percent, margin_percent)
VALUES ('c0500000-0000-0000-0000-000000000001', 'Two-storey house, Kandal', 'Mr Sok', 10, 15);

SELECT ok((SELECT estimate_number FROM construction_estimates WHERE id = 'c0500000-0000-0000-0000-000000000001')
            LIKE 'EST-' || to_char(CURRENT_DATE, 'YYYY') || '-%',
  'the estimate takes its number from the database');
SELECT ok((SELECT revision FROM construction_estimates WHERE id = 'c0500000-0000-0000-0000-000000000001') = 'A',
  'and starts at revision A');

INSERT INTO boq_sections (id, estimate_id, title, sort_order) VALUES
  ('c0600000-0000-0000-0000-000000000001', 'c0500000-0000-0000-0000-000000000001', 'Preliminaries', 1),
  ('c0600000-0000-0000-0000-000000000002', 'c0500000-0000-0000-0000-000000000001', 'Substructure',  2);
INSERT INTO boq_sections (id, estimate_id, parent_id, title, sort_order) VALUES
  ('c0600000-0000-0000-0000-000000000003', 'c0500000-0000-0000-0000-000000000001',
   'c0600000-0000-0000-0000-000000000002', 'Concrete work', 1);

INSERT INTO boq_items (id, estimate_id, section_id, description, item_type, unit, quantity, rate_template_id, sort_order)
VALUES ('c0700000-0000-0000-0000-000000000001', 'c0500000-0000-0000-0000-000000000001',
        'c0600000-0000-0000-0000-000000000003',
        'Concrete grade 25 in foundations', 'measured', 'm3', 40, 'c0400000-0000-0000-0000-000000000001', 1);

SELECT ok((SELECT rate_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 123.90,
  'the item takes its cost from the build-up');
-- 123.90 x 1.10 x 1.15 = 156.7335
SELECT ok((SELECT rate_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 156.7335,
  'and its selling rate is that plus 10% overhead and 15% margin');
SELECT ok((SELECT amount_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 4956.00,
  '40 cubic metres cost 4,956.00');
SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 6269.34,
  'and sell for 6,269.34 — the difference is visible, which is the whole point');

\echo ''
\echo '== 4. sections total, however deep the bill goes'

INSERT INTO boq_items (estimate_id, section_id, description, item_type, unit, quantity, rate_cost, sort_order)
VALUES ('c0500000-0000-0000-0000-000000000001', 'c0600000-0000-0000-0000-000000000001',
        'Site hoarding and signage', 'lump', 'item', 1, 800, 1);

SELECT renumber_boq('c0500000-0000-0000-0000-000000000001');

SELECT ok((SELECT out_sell FROM boq_section_totals('c0500000-0000-0000-0000-000000000001')
            WHERE out_title = 'Concrete work') = 6269.34,
  'the innermost section totals its own items');
SELECT ok((SELECT out_sell FROM boq_section_totals('c0500000-0000-0000-0000-000000000001')
            WHERE out_title = 'Substructure') = 6269.34,
  'AND ITS PARENT INCLUDES THEM — a flat list could never do this');
SELECT ok((SELECT out_depth FROM boq_section_totals('c0500000-0000-0000-0000-000000000001')
            WHERE out_title = 'Concrete work') = 2,
  'the nesting is reported so the bill can be indented');
-- 800 x 1.10 x 1.15 = 1012.00
SELECT ok((SELECT out_sell FROM boq_section_totals('c0500000-0000-0000-0000-000000000001')
            WHERE out_title = 'Preliminaries') = 1012.00,
  'preliminaries total on their own');

SELECT ok((SELECT code FROM boq_sections WHERE title = 'Concrete work') = '2.1',
  'renumbering gives a nested section its place in the tree');
SELECT ok((SELECT code FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = '2.1.1',
  'and an item its number under that — nobody types these');

SELECT ok((SELECT out_total_sell FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 7281.34,
  'the estimate totals 7,281.34');
SELECT ok((SELECT out_total_cost FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 5756.00,
  'costs 5,756.00');
SELECT ok((SELECT out_margin FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 1525.34,
  'and makes 1,525.34');
SELECT ok((SELECT out_margin_pct FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 20.95,
  'which is 20.95% of the tender, not the 25% somebody might assume from 10 + 15');

\echo ''
\echo '== 5. a section cannot swallow itself'

SELECT raises($$
  UPDATE boq_sections SET parent_id = 'c0600000-0000-0000-0000-000000000003'
   WHERE id = 'c0600000-0000-0000-0000-000000000002'
$$, 'a section cannot be put inside one of its own sub-sections');
SELECT raises($$
  UPDATE boq_sections SET parent_id = id WHERE id = 'c0600000-0000-0000-0000-000000000001'
$$, 'nor inside itself');

INSERT INTO construction_estimates (id, title) VALUES
  ('c0500000-0000-0000-0000-000000000009', 'Another job');
SELECT raises($$
  INSERT INTO boq_items (estimate_id, section_id, description, unit, quantity, rate_cost)
  VALUES ('c0500000-0000-0000-0000-000000000009', 'c0600000-0000-0000-0000-000000000001',
          'Stray item', 'item', 1, 10)
$$, 'an item cannot be filed under a section belonging to another estimate');

\echo ''
\echo '== 6. provisional and prime cost sums are not measured work'

INSERT INTO boq_items (id, estimate_id, section_id, description, item_type, rate_cost, sort_order)
VALUES ('c0700000-0000-0000-0000-000000000002', 'c0500000-0000-0000-0000-000000000001',
        'c0600000-0000-0000-0000-000000000001',
        'Provisional sum for external works', 'provisional', 15000, 2),
       ('c0700000-0000-0000-0000-000000000003', 'c0500000-0000-0000-0000-000000000001',
        'c0600000-0000-0000-0000-000000000001',
        'Prime cost sum for sanitary ware', 'pc_sum', 8000, 3);

SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000002') = 15000,
  'a provisional sum goes in at the figure agreed, with no margin added on top');
SELECT ok((SELECT quantity FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000002') = 1,
  'and is one of, not a measured quantity');
SELECT ok((SELECT out_provisional FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 15000,
  'provisional sums are totalled apart from measured work');
SELECT ok((SELECT out_pc_sums FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 8000,
  'so are prime cost sums — the client can see how much of the price is not yet firm');
SELECT ok((SELECT out_measured_sell FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 7281.34,
  'and measured work still totals on its own');

INSERT INTO boq_items (id, estimate_id, section_id, description, item_type, sort_order)
VALUES ('c0700000-0000-0000-0000-000000000004', 'c0500000-0000-0000-0000-000000000001',
        'c0600000-0000-0000-0000-000000000001',
        'Rates allow for working within an occupied site', 'note', 4);
SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000004') = 0,
  'a note carries no money');
SELECT ok((SELECT out_item_count FROM estimate_summary('c0500000-0000-0000-0000-000000000001')) = 4,
  'and is not counted as a priced item');

\echo ''
\echo '== 7. THE QUESTION A TYPED RATE COULD NEVER ANSWER'
\echo '   cement moves — what does that do to the tender?'

SELECT ok((SELECT count(*) FROM reprice_estimate('c0500000-0000-0000-0000-000000000001', false)) = 0,
  'with nothing changed, nothing needs re-pricing');

UPDATE estimate_resources SET unit_cost = 12.00, price_source = 'Supplier letter, 14 March'
 WHERE code = 'MAT-CEM';

SELECT ok((SELECT count(*) FROM resource_price_history WHERE resource_id = 'c0300000-0000-0000-0000-000000000001') = 2,
  'the rise is on the record with its source');
SELECT ok((SELECT old_cost FROM resource_price_history
            WHERE resource_id = 'c0300000-0000-0000-0000-000000000001' AND new_cost = 12.00) = 10.00,
  'saying what it was before');

-- 7 x 1.05 x 12.00 = 88.20, so the rate becomes 123.90 - 73.50 + 88.20 = 138.60
SELECT ok((SELECT out_total FROM rate_template_cost('c0400000-0000-0000-0000-000000000001')) = 138.60,
  'the concrete rate moves from 123.90 to 138.60 on its own');

SELECT ok((SELECT count(*) FROM reprice_estimate('c0500000-0000-0000-0000-000000000001', false)) = 1,
  'ONE ITEM IN THE BILL IS AFFECTED, and the estimate can say which');
SELECT ok((SELECT out_change FROM reprice_estimate('c0500000-0000-0000-0000-000000000001', false)) = 14.70,
  'by 14.70 a cubic metre');
SELECT ok((SELECT rate_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 123.90,
  'and asking the question has not changed the bill');

SELECT reprice_estimate('c0500000-0000-0000-0000-000000000001', true);
SELECT ok((SELECT rate_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 138.60,
  'applying it moves the item');
-- 40 x 138.60 x 1.10 x 1.15 = 7013.16
SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 7013.16,
  'and the amount follows the new rate through overhead and margin');
SELECT ok((SELECT count(*) FROM reprice_estimate('c0500000-0000-0000-0000-000000000001', false)) = 0,
  'after which nothing is out of date');

\echo ''
\echo '== 8. an overridden rate is not silently overridden'

SELECT raises($$
  UPDATE boq_items SET rate_override = 100
   WHERE id = 'c0700000-0000-0000-0000-000000000001'
$$, 'overriding a built-up rate without saying why is refused');

UPDATE boq_items SET rate_override = 100, override_reason = 'Client is supplying the cement'
 WHERE id = 'c0700000-0000-0000-0000-000000000001';
SELECT ok((SELECT rate_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 100,
  'with a reason it is accepted');
SELECT ok((SELECT count(*) FROM reprice_estimate('c0500000-0000-0000-0000-000000000001', false)) = 0,
  'and an overridden item is left alone by re-pricing');

UPDATE boq_items SET rate_override = NULL, override_reason = NULL
 WHERE id = 'c0700000-0000-0000-0000-000000000001';
SELECT ok((SELECT rate_cost FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 138.60,
  'clearing the override puts the built-up rate back');

\echo ''
\echo '== 9. what was sent to the client does not move'

SELECT raises($$SELECT issue_estimate('c0500000-0000-0000-0000-000000000009')$$,
  'an estimate with nothing priced in it cannot be issued');

SELECT issue_estimate('c0500000-0000-0000-0000-000000000001');
SELECT ok((SELECT status FROM construction_estimates WHERE id = 'c0500000-0000-0000-0000-000000000001') = 'issued',
  'the estimate is issued');
SELECT ok((SELECT issued_at FROM construction_estimates WHERE id = 'c0500000-0000-0000-0000-000000000001') IS NOT NULL,
  'and stamped with when');

SELECT raises($$UPDATE boq_items SET quantity = 999 WHERE id = 'c0700000-0000-0000-0000-000000000001'$$,
  'an item cannot be changed once the bill has gone out');
SELECT raises($$DELETE FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001'$$,
  'nor removed');
SELECT raises($$INSERT INTO boq_sections (estimate_id, title) VALUES ('c0500000-0000-0000-0000-000000000001', 'Sneaked in')$$,
  'nor a section added to it afterwards');
SELECT raises($$SELECT reprice_estimate('c0500000-0000-0000-0000-000000000001', true)$$,
  'and it cannot be quietly re-priced under the client');
SELECT raises($$SELECT issue_estimate('c0500000-0000-0000-0000-000000000001')$$,
  'issuing it twice is refused');

\echo ''
\echo '== 10. a revision is a copy, so what was sent stays readable'

SELECT revise_estimate('c0500000-0000-0000-0000-000000000001', 'Client moved the boundary wall');

SELECT ok((SELECT status FROM construction_estimates WHERE id = 'c0500000-0000-0000-0000-000000000001') = 'superseded',
  'the issued revision becomes superseded rather than being edited');
SELECT ok((SELECT count(*) FROM construction_estimates
            WHERE estimate_number = (SELECT estimate_number FROM construction_estimates
                                      WHERE id = 'c0500000-0000-0000-0000-000000000001')) = 2,
  'there are now two revisions under one estimate number');
SELECT ok((SELECT revision FROM construction_estimates
            WHERE estimate_number = (SELECT estimate_number FROM construction_estimates
                                      WHERE id = 'c0500000-0000-0000-0000-000000000001')
              AND status = 'draft') = 'B',
  'the new one is revision B');

-- Five rows: three priced items, a provisional sum, a PC sum and a note.
SELECT ok((SELECT count(*) FROM boq_items i
             JOIN construction_estimates e ON e.id = i.estimate_id
            WHERE e.revision = 'B') = 5,
  'every item came across, notes included');
SELECT ok((SELECT count(*) FROM boq_sections s
             JOIN construction_estimates e ON e.id = s.estimate_id
            WHERE e.revision = 'B') = 3,
  'and every section');
SELECT ok((SELECT count(*) FROM boq_sections s
             JOIN construction_estimates e ON e.id = s.estimate_id
            WHERE e.revision = 'B' AND s.parent_id IS NOT NULL) = 1,
  'THE NESTING SURVIVED — the sub-section is still inside its parent');
SELECT ok((SELECT out_total_sell FROM estimate_summary(
             (SELECT id FROM construction_estimates WHERE revision = 'B'))) =
          (SELECT out_total_sell FROM estimate_summary('c0500000-0000-0000-0000-000000000001')),
  'and the copy totals the same as what it was copied from');

-- Revision A is still exactly what the client was given.
SELECT ok((SELECT amount_sell FROM boq_items WHERE id = 'c0700000-0000-0000-0000-000000000001') = 7013.16,
  'revision A still reads as it did when it was sent');

\echo ''
\echo '== 11. an accepted estimate is not revised, it is varied'

UPDATE construction_estimates SET status = 'accepted', accepted_at = now()
 WHERE revision = 'B';
SELECT raises($$SELECT revise_estimate((SELECT id FROM construction_estimates WHERE revision = 'B'))$$,
  'an accepted estimate cannot be revised — after that, changes are variations');

\echo ''
\echo '== 12. old flat bills are brought across, not thrown away'

INSERT INTO construction_projects (id, name, client_name, currency)
VALUES ('c0800000-0000-0000-0000-000000000001', 'Warehouse, Poipet', 'Mrs Chea', 'USD');
INSERT INTO construction_boq (project_id, item_no, description, unit, quantity, unit_rate, amount) VALUES
  ('c0800000-0000-0000-0000-000000000001', '1',  'Excavate to reduce level', 'm3', 200, 4.00,  800.00),
  ('c0800000-0000-0000-0000-000000000001', '2',  'Hardcore filling',          'm3',  80, 12.00, 960.00);

SELECT raises($$SELECT import_legacy_boq('c0500000-0000-0000-0000-000000000009')$$,
  'importing a project with no old bill is refused');

SELECT import_legacy_boq('c0800000-0000-0000-0000-000000000001');

SELECT ok((SELECT count(*) FROM boq_items i JOIN construction_estimates e ON e.id = i.estimate_id
            WHERE e.project_id = 'c0800000-0000-0000-0000-000000000001') = 2,
  'both old rows came across');
SELECT ok((SELECT count(*) FROM construction_boq WHERE project_id = 'c0800000-0000-0000-0000-000000000001') = 2,
  'and the old bill is still there — nothing was destroyed');
SELECT ok((SELECT sum(amount_cost) FROM boq_items i JOIN construction_estimates e ON e.id = i.estimate_id
            WHERE e.project_id = 'c0800000-0000-0000-0000-000000000001') = 1760.00,
  'the imported figures add up to what the old bill said');
SELECT ok((SELECT count(*) FROM boq_items i JOIN construction_estimates e ON e.id = i.estimate_id
            WHERE e.project_id = 'c0800000-0000-0000-0000-000000000001'
              AND i.rate_template_id IS NULL) = 2,
  'with no build-up behind them, which reconciliation then says out loud');

\echo ''
\echo '== 13. what needs looking at'

SELECT ok(EXISTS (SELECT 1 FROM estimating_reconciliation()
                   WHERE out_kind = 'item' AND out_issue LIKE 'Rate typed in%'),
  'a priced item with no build-up is reported');

INSERT INTO rate_templates (id, code, description, unit)
VALUES ('c0400000-0000-0000-0000-000000000009', 'EMPTY', 'A rate nobody finished', 'm2');
SELECT ok(EXISTS (SELECT 1 FROM estimating_reconciliation()
                   WHERE out_kind = 'rate' AND out_ref = 'c0400000-0000-0000-0000-000000000009'),
  'a rate with nothing in it is reported, because it prices at zero');

INSERT INTO estimate_resources (id, code, name, resource_type, unit, unit_cost)
VALUES ('c0300000-0000-0000-0000-000000000009', 'MAT-ZERO', 'Something nobody priced', 'material', 'kg', 0);
INSERT INTO rate_components (template_id, resource_id, quantity_per_unit)
VALUES ('c0400000-0000-0000-0000-000000000001', 'c0300000-0000-0000-0000-000000000009', 5);
SELECT ok(EXISTS (SELECT 1 FROM estimating_reconciliation()
                   WHERE out_kind = 'resource' AND out_ref = 'c0300000-0000-0000-0000-000000000009'),
  'a resource priced at nothing is reported, because everything built on it is understated');

UPDATE estimate_resources SET priced_on = CURRENT_DATE - 400 WHERE code = 'MAT-SND';
SELECT ok(EXISTS (SELECT 1 FROM estimating_reconciliation()
                   WHERE out_kind = 'resource' AND out_issue LIKE 'Last priced%'),
  'a price nobody has checked for over six months is reported');

\echo ''
\echo '== 14. who may price work'

SELECT act_as('phalla@build.kh');
SELECT raises($$SELECT issue_estimate('c0500000-0000-0000-0000-000000000009')$$,
  'a driver cannot send an estimate to a client');
SELECT act_as('sarin@build.kh');

\echo ''
\echo '===================================================================='
\echo ' CONSTRUCTION ESTIMATING: all assertions passed'
\echo '===================================================================='
