-- =====================================================================
-- INVENTORY INTEGRITY — INVARIANT TESTS
-- ---------------------------------------------------------------------
-- The defects these guard are not hypothetical. The on-hand quantity was
-- computed in the browser from React state and written back as an
-- absolute number, so two people selling the same item in the same second
-- each read the same figure and one sale disappeared. The movement was
-- inserted first and the quantity second, as separate round-trips, so the
-- log and the shelf could disagree for good. Every assertion below is
-- about one of those.
--
-- Run against a scratch database with the base schema, RLS and every
-- vertical loaded:
--
--   createdb scratch
--   psql -d scratch -f supabase/setup/schema/kareya_silo_schema.sql
--   psql -d scratch -f supabase/setup/schema/RLS.sql
--   for f in supabase/setup/schema/verticals/*.sql; do psql -d scratch -f "$f"; done
--   psql -d scratch -f supabase/setup/tests/inventory.test.sql
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
  ('50000000-0000-0000-0000-000000000001', 'store@shop.kh'),
  ('50000000-0000-0000-0000-000000000002', 'clerk@shop.kh')
ON CONFLICT DO NOTHING;

INSERT INTO employees (id, user_id, name, email, roles) VALUES
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'Chan (storekeeper)', 'store@shop.kh', ARRAY['Manager']),
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', 'Nary (clerk)',       'clerk@shop.kh', ARRAY['Reception'])
ON CONFLICT DO NOTHING;

INSERT INTO warehouses (id, name) VALUES
  ('70000000-0000-0000-0000-000000000001', 'Main store'),
  ('70000000-0000-0000-0000-000000000002', 'Branch')
ON CONFLICT DO NOTHING;

SELECT act_as('store@shop.kh');

\echo '== 1. opening stock is a movement, not a number somebody typed'

INSERT INTO stock_items (id, sku, name, cost_price, sale_price, quantity)
VALUES ('80000000-0000-0000-0000-000000000001', 'RICE-25', 'Rice 25kg', 20, 26, 100);

SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 100,
  'an item created with 100 on hand still reads 100');
SELECT ok((SELECT count(*) FROM stock_movements WHERE reason = 'opening') = 1,
  'and the log accounts for where those 100 came from');
SELECT ok((SELECT quantity_after FROM stock_movements WHERE reason = 'opening') = 100,
  'the opening movement records the on-hand it produced');
SELECT ok((SELECT quantity_before FROM stock_movements WHERE reason = 'opening') = 0,
  'and what it started from, so the accounts can value it without asking a browser');

INSERT INTO stock_items (id, sku, name, cost_price, quantity)
VALUES ('80000000-0000-0000-0000-000000000002', 'OIL-1L', 'Cooking oil 1L', 2, 0);
SELECT ok((SELECT count(*) FROM stock_movements WHERE item_id = '80000000-0000-0000-0000-000000000002') = 0,
  'an item created empty needs no opening movement');

\echo '== 2. the on-hand is what the movements add up to'

SELECT ok((apply_stock_movement('80000000-0000-0000-0000-000000000001', 'in', 50, 22, 'purchase', 'PO-1')).quantity_after = 150,
  'a receipt of 50 takes the on-hand to 150');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 150,
  'and the item agrees, in the same transaction');

SELECT ok((apply_stock_movement('80000000-0000-0000-0000-000000000001', 'out', 30, 0, 'sale', 'INV-1')).quantity_after = 120,
  'a sale of 30 takes it to 120');

-- The lost-update case, made deterministic: the second call must read the
-- FIRST call's result, not the figure the caller started from. Under the
-- old browser arithmetic both would have written 149.
SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'out', 1, 0, 'sale', 'A');
SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'out', 1, 0, 'sale', 'B');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 118,
  'two sales in a row take two units, not one');

-- The rule that only lived in the browser, so any stale tab walked past it.
SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'out', 5000, 0, 'sale')$$,
  'more going out than is on hand is refused');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 118,
  'and the refusal left the on-hand alone');

SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'sideways', 1)$$,
  'a movement type this system does not know is refused');
SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'out', 0)$$,
  'a movement of nothing is refused');
SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-0000000000ff', 'in', 5)$$,
  'a movement against an item that does not exist is refused');

SELECT act_as('nobody@elsewhere.kh');
SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'in', 5)$$,
  'somebody who is not an employee cannot move stock');
SELECT act_as('store@shop.kh');

\echo '== 3. a stock-take restates the on-hand'

SELECT ok((apply_stock_movement('80000000-0000-0000-0000-000000000001', 'adjust', 115, 0, 'cycle-count')).quantity_after = 115,
  'a count of 115 makes the on-hand 115, whatever it was');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 115,
  'and the item follows');
SELECT ok((SELECT count(*) FROM stock_reconciliation() WHERE out_sku = 'RICE-25') = 0,
  'the replay agrees with the on-hand after a count');

\echo '== 4. the quantity is not typeable'

-- This is the write the frontend used to make on every single movement.
SELECT raises($$UPDATE stock_items SET quantity = 9999 WHERE sku = 'RICE-25'$$,
  'the on-hand cannot be written directly');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 115,
  'so it still says what the movements say');

-- Everything else about an item is ordinary editable data.
UPDATE stock_items SET sale_price = 27, reorder_level = 20 WHERE sku = 'RICE-25';
SELECT ok((SELECT sale_price FROM stock_items WHERE sku = 'RICE-25') = 27,
  'the price and reorder level are still editable');

SELECT raises($$UPDATE stock_movements SET quantity = 1 WHERE reason = 'opening'$$,
  'a movement cannot be edited after the fact');
SELECT raises($$DELETE FROM stock_movements WHERE reason = 'opening'$$,
  'a movement cannot be deleted');
SELECT raises($$DELETE FROM stock_items WHERE sku = 'RICE-25'$$,
  'an item with history cannot be deleted, taking the history with it');

DELETE FROM stock_items WHERE sku = 'OIL-1L';
SELECT ok(NOT EXISTS (SELECT 1 FROM stock_items WHERE sku = 'OIL-1L'),
  'an item that never moved can still be deleted');

\echo '== 5. weighted-average cost is computed on the database''s figures'

INSERT INTO stock_items (id, sku, name, cost_price, quantity)
VALUES ('80000000-0000-0000-0000-000000000003', 'SUGAR', 'Sugar 1kg', 1.00, 100);

-- 100 at 1.00 plus 100 at 2.00 is 200 at 1.50, and it must be arrived at
-- from the locked row rather than from whatever a browser had cached.
SELECT apply_stock_movement('80000000-0000-0000-0000-000000000003', 'in', 100, 2.00, 'purchase', 'PO-2');
SELECT ok((SELECT round(cost_price, 4) FROM stock_items WHERE sku = 'SUGAR') = 1.5000,
  'a receipt at a new price re-averages the cost');

SELECT apply_stock_movement('80000000-0000-0000-0000-000000000003', 'out', 50, 0, 'sale');
SELECT ok((SELECT round(cost_price, 4) FROM stock_items WHERE sku = 'SUGAR') = 1.5000,
  'selling does not change what a unit cost to buy');

SELECT apply_stock_movement('80000000-0000-0000-0000-000000000003', 'adjust', 140, 0, 'cycle-count');
SELECT ok((SELECT round(cost_price, 4) FROM stock_items WHERE sku = 'SUGAR') = 1.5000,
  'and neither does counting it');

\echo '== 6. warehouse levels move by delta'

SELECT ok(apply_stock_level('80000000-0000-0000-0000-000000000001',
                            '70000000-0000-0000-0000-000000000001', 60) = 60,
  'a first delta creates the level');
SELECT ok(apply_stock_level('80000000-0000-0000-0000-000000000001',
                            '70000000-0000-0000-0000-000000000001', 40) = 100,
  'a second delta adds to it rather than replacing it');
SELECT ok(apply_stock_level('80000000-0000-0000-0000-000000000001',
                            '70000000-0000-0000-0000-000000000001', -25) = 75,
  'and a negative delta takes stock off the shelf');

SELECT raises($$SELECT apply_stock_level('80000000-0000-0000-0000-000000000001',
                                         '70000000-0000-0000-0000-000000000001', -1000)$$,
  'a shelf cannot hold less than nothing');
SELECT ok((SELECT quantity FROM stock_levels
            WHERE item_id = '80000000-0000-0000-0000-000000000001'
              AND warehouse_id = '70000000-0000-0000-0000-000000000001') = 75,
  'and the refusal left the shelf alone');

\echo '== 7. a transfer is one movement of stock, not two'

SELECT ok((transfer_stock('80000000-0000-0000-0000-000000000001',
                          '70000000-0000-0000-0000-000000000001',
                          '70000000-0000-0000-0000-000000000002', 25)).quantity = 25,
  'stock moves from the main store to the branch');
SELECT ok((SELECT quantity FROM stock_levels
            WHERE item_id = '80000000-0000-0000-0000-000000000001'
              AND warehouse_id = '70000000-0000-0000-0000-000000000001') = 50,
  'the source is 25 lighter');
SELECT ok((SELECT quantity FROM stock_levels
            WHERE item_id = '80000000-0000-0000-0000-000000000001'
              AND warehouse_id = '70000000-0000-0000-0000-000000000002') = 25,
  'and the destination 25 heavier');

-- The case two independent writes would get wrong: the destination gains
-- units the source never had.
SELECT raises($$SELECT transfer_stock('80000000-0000-0000-0000-000000000001',
                                      '70000000-0000-0000-0000-000000000001',
                                      '70000000-0000-0000-0000-000000000002', 5000)$$,
  'a transfer of more than the source holds is refused');
SELECT ok((SELECT quantity FROM stock_levels
            WHERE item_id = '80000000-0000-0000-0000-000000000001'
              AND warehouse_id = '70000000-0000-0000-0000-000000000002') = 25,
  'and the destination gained nothing from the attempt');

SELECT raises($$SELECT transfer_stock('80000000-0000-0000-0000-000000000001',
                                      '70000000-0000-0000-0000-000000000001',
                                      '70000000-0000-0000-0000-000000000001', 5)$$,
  'a transfer from a place to itself is refused');
SELECT raises($$SELECT transfer_stock('80000000-0000-0000-0000-000000000001', NULL, NULL, 5)$$,
  'a transfer with neither end is refused');

\echo '== 8. a movement that names a warehouse moves that warehouse too'

SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'in', 10, 21, 'purchase', 'PO-3',
                            CURRENT_DATE, '70000000-0000-0000-0000-000000000002');
SELECT ok((SELECT quantity FROM stock_levels
            WHERE item_id = '80000000-0000-0000-0000-000000000001'
              AND warehouse_id = '70000000-0000-0000-0000-000000000002') = 35,
  'receiving into the branch raises the branch level');
SELECT ok((SELECT quantity FROM stock_items WHERE sku = 'RICE-25') = 125,
  'and the item on-hand at the same time');

SELECT raises($$SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'in', 1, 0, 'purchase', NULL,
                                            CURRENT_DATE, '70000000-0000-0000-0000-0000000000ff')$$,
  'a movement into a warehouse that does not exist is refused');

\echo '== 9. drift is visible'

SELECT ok((SELECT count(*) FROM stock_reconciliation()
            WHERE out_problem LIKE 'The on-hand does not match%') = 0,
  'nothing recorded through the movement path drifts');

-- Reproduce the state an old Silo could genuinely be in: the on-hand was
-- written by a browser and the movements never accounted for it. Only the
-- guard's own flag can produce it now, which is the point.
SELECT set_config('kareya.stock_apply', 'on', false);
UPDATE stock_items SET quantity = quantity + 7 WHERE sku = 'RICE-25';
SELECT set_config('kareya.stock_apply', 'off', false);

SELECT ok(EXISTS (SELECT 1 FROM stock_reconciliation() WHERE out_sku = 'RICE-25'),
  'an on-hand the movements cannot explain is named');
SELECT ok((SELECT out_on_hand - out_from_movements FROM stock_reconciliation() WHERE out_sku = 'RICE-25') = 7,
  'and the report says by how much');

-- Correcting it is a stock-take, like it would be in the shop.
SELECT apply_stock_movement('80000000-0000-0000-0000-000000000001', 'adjust', 125, 0, 'cycle-count', 'Recount');
SELECT ok((SELECT count(*) FROM stock_reconciliation() WHERE out_sku = 'RICE-25'
            AND out_problem LIKE 'The on-hand does not match%') = 0,
  'and a count settles it');

\echo '== 10. the guards are on the table, not only in the function'

SELECT ok(NOT EXISTS (SELECT 1 FROM pg_policies
                       WHERE tablename = 'stock_movements' AND cmd IN ('UPDATE','DELETE','ALL')),
  'no client policy grants an edit or delete on the movement log');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_items_qty_non_negative'),
  'a non-negative on-hand is a constraint, not only a refusal');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_levels_qty_non_negative'),
  'and so is a non-negative shelf');

\echo ''
\echo 'ALL INVENTORY INTEGRITY ASSERTIONS PASSED'
