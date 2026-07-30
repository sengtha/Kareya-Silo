-- =====================================================================
-- KAREYA SILO — INVENTORY INTEGRITY (inventory-integrity)
-- ---------------------------------------------------------------------
-- The base schema says stock_items.quantity is "maintained by movements".
-- It was not. The BROWSER maintained it, and it did so by reading the
-- current figure out of React state, adding a delta and writing back an
-- ABSOLUTE number. Three consequences, in order of how often they bite:
--
--  1. LOST UPDATES. Two people selling the same item in the same second
--     both read 100 and both write 99. One unit disappears with nothing to
--     show for it. Same for two receipts, and the weighted-average cost
--     was recomputed the same way, so the cost was wrong too. Everything
--     now happens under a row lock taken by the DATABASE, on the
--     database's own value.
--
--  2. THE LOG AND THE SHELF COULD PERMANENTLY DISAGREE. The movement was
--     inserted first and the quantity written second, as two separate
--     round-trips — the frontend even had a "Movement saved but quantity
--     update failed" message for when the second one didn't. Nothing ever
--     reconciled the two afterwards. The quantity is now derived from the
--     movement inside the same transaction that records it, and a direct
--     write to it is refused, so the two cannot come apart.
--
--  3. STOCK COULD GO NEGATIVE, quietly. The check was in the browser, so
--     any stale tab could walk through it.
--
-- Warehouse levels had the same read-add-write pattern with no lock at
-- all. apply_stock_level() moves them by delta inside the statement.
--
-- Idempotent and order-independent. Depends on: stock_items,
-- stock_movements, stock_levels, stock_transfers, warehouses.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A MOVEMENT CARRIES WHAT IT DID
-- Recording only "5 out" makes the log unreconcilable: you can replay it
-- but you cannot check it. Recording the on-hand before and after makes
-- every row self-describing, so drift is detectable rather than merely
-- absent — and so the accounting seam can value a movement from the
-- database's own figures instead of whatever a browser had cached.
-- ---------------------------------------------------------------------
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS quantity_before numeric;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS quantity_after  numeric;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS unit_cost_after numeric;
ALTER TABLE public.stock_movements ADD COLUMN IF NOT EXISTS warehouse_id    uuid;

ALTER TABLE public.stock_items ADD COLUMN IF NOT EXISTS is_active boolean DEFAULT true;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_warehouse_fkey') THEN
    ALTER TABLE public.stock_movements
      ADD CONSTRAINT stock_movements_warehouse_fkey
      FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_qty_positive') THEN
    ALTER TABLE public.stock_movements
      ADD CONSTRAINT stock_movements_qty_positive CHECK (quantity >= 0);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_stock_movements_date ON public.stock_movements (item_id, created_at);

-- ---------------------------------------------------------------------
-- 2. THE QUANTITY IS DERIVED, INSIDE THE SAME TRANSACTION
-- The BEFORE trigger takes the row lock and does the arithmetic on the
-- database's value, so two concurrent movements on one item serialise
-- instead of overwriting each other. The AFTER trigger writes the result.
-- Because both hang off the INSERT, even a movement inserted directly —
-- by some future code path, or by hand in Studio — keeps the item right.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stock_movement_compute()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_item stock_items; v_qty numeric; v_new numeric;
BEGIN
  IF NEW.item_id IS NULL THEN RAISE EXCEPTION 'A stock movement needs an item'; END IF;

  -- The lock is the whole point: everything below reads the row as the
  -- database has it, and nobody else can move this item until we commit.
  SELECT * INTO v_item FROM stock_items WHERE id = NEW.item_id FOR UPDATE;
  IF v_item.id IS NULL THEN RAISE EXCEPTION 'Stock item not found'; END IF;

  v_qty := abs(coalesce(NEW.quantity, 0));
  IF v_qty <= 0 AND NEW.type <> 'adjust' THEN
    RAISE EXCEPTION 'A movement needs a quantity greater than zero';
  END IF;
  NEW.quantity := v_qty;

  IF NEW.type = 'in' THEN
    v_new := coalesce(v_item.quantity, 0) + v_qty;
  ELSIF NEW.type = 'out' THEN
    v_new := coalesce(v_item.quantity, 0) - v_qty;
  ELSE
    -- 'adjust' is a stock-take: the counted figure IS the new on-hand.
    v_new := v_qty;
  END IF;

  IF v_new < 0 THEN
    RAISE EXCEPTION 'Not enough %: % on hand, % going out', v_item.name, coalesce(v_item.quantity, 0), v_qty;
  END IF;

  -- Weighted average, recomputed from the locked row. Only a purchase
  -- receipt at a stated cost re-averages; an issue or a stock-take does
  -- not change what a unit cost to buy.
  IF NEW.type = 'in' AND NEW.reason = 'purchase' AND coalesce(NEW.unit_cost, 0) > 0 THEN
    NEW.unit_cost_after := CASE WHEN v_new > 0
      THEN round((coalesce(v_item.quantity, 0) * coalesce(v_item.cost_price, 0)
                  + v_qty * NEW.unit_cost) / v_new, 6)
      ELSE NEW.unit_cost END;
  ELSE
    NEW.unit_cost_after := coalesce(v_item.cost_price, 0);
  END IF;

  NEW.quantity_before := coalesce(v_item.quantity, 0);
  NEW.quantity_after  := v_new;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_movement_compute ON public.stock_movements;
CREATE TRIGGER trg_stock_movement_compute
  BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.stock_movement_compute();

CREATE OR REPLACE FUNCTION public.stock_movement_apply()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- The guard below refuses a hand-written quantity change; this flag is
  -- how the movement path identifies itself as the legitimate writer. It
  -- is transaction-local, so it cannot leak to another statement.
  PERFORM set_config('kareya.stock_apply', 'on', true);
  UPDATE stock_items
     SET quantity   = NEW.quantity_after,
         cost_price = coalesce(NEW.unit_cost_after, cost_price)
   WHERE id = NEW.item_id;
  PERFORM set_config('kareya.stock_apply', 'off', true);
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_movement_apply ON public.stock_movements;
CREATE TRIGGER trg_stock_movement_apply
  AFTER INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.stock_movement_apply();

-- A movement is a record of something that happened. Editing one rewrites
-- history and, worse, would leave the on-hand describing a movement that
-- no longer says what it said. Correct stock with another movement.
CREATE OR REPLACE FUNCTION public.stock_movement_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'A stock movement cannot be % — it is a record of something that happened. Post a correcting movement instead.',
    CASE TG_OP WHEN 'DELETE' THEN 'deleted' ELSE 'edited' END;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_movement_append_only ON public.stock_movements;
CREATE TRIGGER trg_stock_movement_append_only
  BEFORE UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.stock_movement_append_only();

-- ---------------------------------------------------------------------
-- 3. THE ON-HAND IS NOT TYPEABLE
-- Opening stock becomes an opening movement rather than a number somebody
-- put in a box, so the log accounts for every unit from the first day.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.stock_item_quantity_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Hold the opening figure aside; the AFTER trigger turns it into a
    -- movement, which is what puts it back.
    IF coalesce(NEW.quantity, 0) <> 0 THEN
      NEW.notes := coalesce(NEW.notes, '');
      PERFORM set_config('kareya.stock_opening', NEW.quantity::text, true);
      NEW.quantity := 0;
    ELSE
      PERFORM set_config('kareya.stock_opening', '0', true);
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.quantity IS DISTINCT FROM OLD.quantity
     AND coalesce(current_setting('kareya.stock_apply', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'On-hand quantity is not typed in — it is what the movements add up to. Record a receipt, an issue or a stock-take.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_item_quantity_guard ON public.stock_items;
CREATE TRIGGER trg_stock_item_quantity_guard
  BEFORE INSERT OR UPDATE ON public.stock_items
  FOR EACH ROW EXECUTE FUNCTION public.stock_item_quantity_guard();

CREATE OR REPLACE FUNCTION public.stock_item_opening()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE v_open numeric;
BEGIN
  v_open := coalesce(nullif(current_setting('kareya.stock_opening', true), '')::numeric, 0);
  IF v_open <> 0 THEN
    INSERT INTO stock_movements (item_id, type, quantity, unit_cost, reason, reference, date)
    VALUES (NEW.id, 'in', abs(v_open), coalesce(NEW.cost_price, 0), 'opening', 'Opening balance', CURRENT_DATE);
  END IF;
  PERFORM set_config('kareya.stock_opening', '0', true);
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_item_opening ON public.stock_items;
CREATE TRIGGER trg_stock_item_opening
  AFTER INSERT ON public.stock_items
  FOR EACH ROW EXECUTE FUNCTION public.stock_item_opening();

-- stock_movements.item_id cascades, so deleting an item silently erases
-- everything that ever happened to it — including the movements the
-- accounts were posted from. Retire it instead.
CREATE OR REPLACE FUNCTION public.stock_item_no_delete_with_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM stock_movements WHERE item_id = OLD.id) THEN
    RAISE EXCEPTION 'This item has stock movements behind it. Mark it inactive rather than deleting its history.';
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stock_item_no_delete ON public.stock_items;
CREATE TRIGGER trg_stock_item_no_delete
  BEFORE DELETE ON public.stock_items
  FOR EACH ROW EXECUTE FUNCTION public.stock_item_no_delete_with_history();

-- ---------------------------------------------------------------------
-- 4. THE DOOR
-- One validated entry point, so the frontend stops computing on-hand.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_stock_movement(
  p_item_id      uuid,
  p_type         text,
  p_quantity     numeric,
  p_unit_cost    numeric DEFAULT 0,
  p_reason       text DEFAULT NULL,
  p_reference    text DEFAULT NULL,
  p_date         date DEFAULT NULL,
  p_warehouse_id uuid DEFAULT NULL
)
 RETURNS public.stock_movements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_row stock_movements;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;

  IF p_type NOT IN ('in', 'out', 'adjust') THEN
    RAISE EXCEPTION 'A movement is in, out or adjust — not %', p_type;
  END IF;

  IF p_warehouse_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM warehouses WHERE id = p_warehouse_id) THEN
    RAISE EXCEPTION 'That warehouse does not exist';
  END IF;

  INSERT INTO stock_movements (item_id, type, quantity, unit_cost, reason, reference, date, created_by, warehouse_id)
  VALUES (p_item_id, p_type, abs(coalesce(p_quantity, 0)), coalesce(p_unit_cost, 0),
          p_reason, p_reference, coalesce(p_date, CURRENT_DATE), v_emp.id, p_warehouse_id)
  RETURNING * INTO v_row;

  -- A movement naming a warehouse moves that warehouse's level in the
  -- same transaction. Before this the two were separate round-trips and
  -- could disagree for good.
  IF p_warehouse_id IS NOT NULL THEN
    PERFORM apply_stock_level(p_item_id, p_warehouse_id,
      CASE p_type
        WHEN 'in'  THEN abs(coalesce(p_quantity, 0))
        WHEN 'out' THEN -abs(coalesce(p_quantity, 0))
        ELSE 0 END);
  END IF;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.apply_stock_movement(uuid, text, numeric, numeric, text, text, date, uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. WAREHOUSE LEVELS MOVE BY DELTA
-- The old path read the level out of React state, added, and wrote an
-- absolute figure with no lock whatsoever. This does the arithmetic
-- inside the statement, so concurrent receipts add up.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_stock_level(p_item_id uuid, p_warehouse_id uuid, p_delta numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_qty numeric; v_cur numeric;
BEGIN
  IF p_item_id IS NULL OR p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'An item and a warehouse are both needed';
  END IF;
  IF coalesce(p_delta, 0) = 0 THEN
    SELECT coalesce(quantity, 0) INTO v_qty FROM stock_levels
     WHERE item_id = p_item_id AND warehouse_id = p_warehouse_id;
    RETURN coalesce(v_qty, 0);
  END IF;

  -- FOR UPDATE is what makes this safe where the browser version was not:
  -- the row is read and written under one lock, so two concurrent receipts
  -- add up instead of one overwriting the other.
  SELECT quantity INTO v_cur FROM stock_levels
   WHERE item_id = p_item_id AND warehouse_id = p_warehouse_id
   FOR UPDATE;

  IF NOT FOUND THEN
    IF p_delta < 0 THEN
      RAISE EXCEPTION 'There is no stock of this item at that location to take % from', abs(p_delta);
    END IF;
    -- Two first-touches can race; the unique index catches the loser and
    -- the DO UPDATE turns it into the addition it meant to be.
    INSERT INTO stock_levels (item_id, warehouse_id, quantity)
    VALUES (p_item_id, p_warehouse_id, p_delta)
    ON CONFLICT (item_id, warehouse_id)
    DO UPDATE SET quantity = stock_levels.quantity + p_delta
    RETURNING quantity INTO v_qty;
    RETURN v_qty;
  END IF;

  -- Checked before the write, so the message says what happened rather
  -- than naming a constraint.
  IF coalesce(v_cur, 0) + p_delta < 0 THEN
    RAISE EXCEPTION 'Only % of this item is at that location, and % is going out',
      coalesce(v_cur, 0), abs(p_delta);
  END IF;

  UPDATE stock_levels SET quantity = quantity + p_delta
   WHERE item_id = p_item_id AND warehouse_id = p_warehouse_id
  RETURNING quantity INTO v_qty;

  RETURN v_qty;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.apply_stock_level(uuid, uuid, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.transfer_stock(
  p_item_id uuid, p_from uuid, p_to uuid, p_quantity numeric,
  p_date date DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS public.stock_transfers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_qty numeric; v_row stock_transfers;
BEGIN
  IF NOT is_employee() THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  v_qty := abs(coalesce(p_quantity, 0));
  IF v_qty <= 0 THEN RAISE EXCEPTION 'A transfer needs a quantity greater than zero'; END IF;
  IF p_from IS NULL AND p_to IS NULL THEN
    RAISE EXCEPTION 'A transfer needs a source or a destination';
  END IF;
  IF p_from IS NOT NULL AND p_from = p_to THEN
    RAISE EXCEPTION 'A transfer from a place to itself moves nothing';
  END IF;

  -- Take the stock off the source FIRST. If there is not enough, the whole
  -- transfer fails rather than the destination gaining units the source
  -- never had — which is what two independent writes could produce.
  IF p_from IS NOT NULL THEN PERFORM apply_stock_level(p_item_id, p_from, -v_qty); END IF;
  IF p_to   IS NOT NULL THEN PERFORM apply_stock_level(p_item_id, p_to,    v_qty); END IF;

  INSERT INTO stock_transfers (item_id, from_warehouse_id, to_warehouse_id, quantity, date, notes)
  VALUES (p_item_id, p_from, p_to, v_qty, coalesce(p_date, CURRENT_DATE), p_notes)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transfer_stock(uuid, uuid, uuid, numeric, date, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. WHERE THE FIGURES DISAGREE
-- The triggers stop new drift. Anything a Silo accumulated under the old
-- browser-side arithmetic is still there, and silent. This names it.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.stock_reconciliation();
CREATE OR REPLACE FUNCTION public.stock_reconciliation()
 RETURNS TABLE (
   out_item_id      uuid,
   out_sku          text,
   out_name         text,
   out_on_hand      numeric,
   out_from_movements numeric,
   out_in_warehouses  numeric,
   out_problem      text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH replay AS (
    SELECT i.id,
           -- What the log adds up to. An 'adjust' restates the on-hand
           -- rather than moving it, so the replay restarts from the last
           -- one; anything before it is superseded by the count.
           coalesce((
             SELECT sum(CASE m.type WHEN 'in' THEN m.quantity WHEN 'out' THEN -m.quantity ELSE 0 END)
               FROM stock_movements m
              WHERE m.item_id = i.id
                AND m.created_at > coalesce((SELECT max(a.created_at) FROM stock_movements a
                                              WHERE a.item_id = i.id AND a.type = 'adjust'), '-infinity')
           ), 0)
           + coalesce((SELECT a.quantity FROM stock_movements a
                        WHERE a.item_id = i.id AND a.type = 'adjust'
                        ORDER BY a.created_at DESC LIMIT 1), 0) AS replayed,
           coalesce((SELECT sum(l.quantity) FROM stock_levels l WHERE l.item_id = i.id), 0) AS levelled
      FROM stock_items i
  )
  SELECT i.id, i.sku, i.name,
         coalesce(i.quantity, 0), r.replayed, r.levelled,
         CASE
           WHEN round(coalesce(i.quantity, 0), 4) <> round(r.replayed, 4)
             THEN 'The on-hand does not match what the movements add up to'
           ELSE 'The warehouse levels do not add up to the on-hand'
         END
    FROM stock_items i JOIN replay r ON r.id = i.id
   WHERE round(coalesce(i.quantity, 0), 4) <> round(r.replayed, 4)
      -- Levels only need to agree once somebody has started using them.
      OR (r.levelled <> 0 AND round(r.levelled, 4) <> round(coalesce(i.quantity, 0), 4))
   ORDER BY i.name;
$function$;

GRANT EXECUTE ON FUNCTION public.stock_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- Inserting a movement stays open to Manager/Accountant: the triggers make
-- a direct insert correct, so there is no reason to force it through the
-- function. Editing and deleting one is closed to everybody.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Manage stock movements" ON public.stock_movements;
DROP POLICY IF EXISTS stock_movements_add ON public.stock_movements;
CREATE POLICY stock_movements_add ON public.stock_movements
  FOR INSERT TO authenticated
  WITH CHECK (public.has_any_role(ARRAY['Accountant', 'Manager']));

-- A non-negative shelf, stated as a constraint rather than only as a
-- refusal inside a function — but only where the data already allows it.
-- A Silo that accumulated a negative under the old arithmetic keeps its
-- rows and gets the function-level refusal; stock_reconciliation() and
-- this notice are how somebody finds out.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_levels_qty_non_negative') THEN
    IF EXISTS (SELECT 1 FROM public.stock_levels WHERE quantity < 0) THEN
      RAISE NOTICE 'stock_levels holds negative quantities; the non-negative constraint was not added. Run stock_reconciliation() and correct them.';
    ELSE
      ALTER TABLE public.stock_levels ADD CONSTRAINT stock_levels_qty_non_negative CHECK (quantity >= 0);
    END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stock_items_qty_non_negative') THEN
    IF EXISTS (SELECT 1 FROM public.stock_items WHERE quantity < 0) THEN
      RAISE NOTICE 'stock_items holds negative quantities; the non-negative constraint was not added. Run stock_reconciliation() and correct them.';
    ELSE
      ALTER TABLE public.stock_items ADD CONSTRAINT stock_items_qty_non_negative CHECK (quantity >= 0);
    END IF;
  END IF;
END $$;
