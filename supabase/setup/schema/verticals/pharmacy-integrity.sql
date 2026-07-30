-- =====================================================================
-- KAREYA SILO — DISPENSING INTEGRITY (pharmacy-integrity)
-- ---------------------------------------------------------------------
-- Dispensing ran in the browser, and one of the things it got wrong is
-- not a data problem.
--
--  1. EXPIRED MEDICINE WAS DISPENSED FIRST. The allocation sorted batches
--     by expiry date ascending and took from the top, filtering only on
--     "has stock left". An expired batch sorts EARLIEST, so it went out
--     ahead of everything in date — the exact opposite of what FEFO is
--     for. FEFO means first-expiry-FIRST-OUT among stock that is still
--     usable; a batch past its date is not stock, it is waste. Nothing
--     anywhere excluded it, and nothing warned.
--
--  2. THE ALLOCATION WAS A LOST UPDATE, on medicine. Batch quantities
--     were read out of React state, decremented in the browser, and
--     written back as absolute numbers in parallel. Two pharmacists
--     dispensing the same drug in the same moment both read the same
--     figures and both wrote, so the shelf said one dispensing had
--     happened when two had.
--
--  3. VOIDING A SALE DID NOT PUT THE MEDICINE BACK. It flipped a status
--     column. The batches stayed decremented, so stock that was never
--     handed to anybody read as gone.
--
--  4. requires_rx WAS DECORATION. The column existed and nothing ever
--     looked at it, so a prescription-only medicine went over the counter
--     with no prescriber and no reference recorded.
--
--  5. SALE NUMBERS CAME FROM A CLOCK, with no unique index.
--
--  6. A BATCH QUANTITY COULD CHANGE WITH NO RECORD OF WHY. Batch tracking
--     exists so that a recall can be answered — which lot, how much of it,
--     where it went. A quantity that moves with nothing saying who moved it
--     or what for breaks that, and it is the number a physical count is
--     checked against.
--
-- What is deliberately NOT here: any drug interaction, contraindication,
-- dose limit or substitution rule. That is pharmacology, it is not
-- something this file can know, and a half-right interaction check is
-- more dangerous than none because it looks like it is watching.
--
-- Idempotent and order-independent. Depends on: pharmacy_products,
-- pharmacy_batches, pharmacy_sales, pharmacy_sale_items.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A BATCH HAS A STATE, AND EXPIRED IS ONE OF THEM
-- ---------------------------------------------------------------------
ALTER TABLE public.pharmacy_batches ADD COLUMN IF NOT EXISTS quarantined boolean DEFAULT false;
ALTER TABLE public.pharmacy_batches ADD COLUMN IF NOT EXISTS quarantine_reason text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pharmacy_batches_qty_non_negative') THEN
    IF EXISTS (SELECT 1 FROM public.pharmacy_batches WHERE quantity < 0) THEN
      RAISE NOTICE 'pharmacy_batches holds negative quantities; the non-negative constraint was not added. Count the shelf and correct them.';
    ELSE
      ALTER TABLE public.pharmacy_batches ADD CONSTRAINT pharmacy_batches_qty_non_negative CHECK (quantity >= 0);
    END IF;
  END IF;
END $$;

-- Dispensable means: some left, in date, and not held back. A batch with
-- no expiry recorded is treated as dispensable — refusing it would stop a
-- pharmacy working over a data-entry gap — but it sorts LAST, so anything
-- with a known date goes first and the gap surfaces rather than hiding.
CREATE OR REPLACE FUNCTION public.pharmacy_batch_is_dispensable(p_batch_id uuid, p_on date DEFAULT CURRENT_DATE)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM pharmacy_batches b
     WHERE b.id = p_batch_id
       AND coalesce(b.quantity, 0) > 0
       AND coalesce(b.quarantined, false) = false
       AND (b.expiry_date IS NULL OR b.expiry_date >= coalesce(p_on, CURRENT_DATE)));
$function$;

GRANT EXECUTE ON FUNCTION public.pharmacy_batch_is_dispensable(uuid, date) TO authenticated;

-- What can actually go out for a product, soonest-expiring first among
-- stock that is still in date. This is FEFO as it is meant to work.
DROP FUNCTION IF EXISTS public.pharmacy_dispensable_batches(uuid, date);
CREATE OR REPLACE FUNCTION public.pharmacy_dispensable_batches(p_product_id uuid, p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (out_batch_id uuid, out_batch_number text, out_expiry date, out_quantity numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT b.id, b.batch_number, b.expiry_date, b.quantity
    FROM pharmacy_batches b
   WHERE b.product_id = p_product_id
     AND coalesce(b.quantity, 0) > 0
     AND coalesce(b.quarantined, false) = false
     AND (b.expiry_date IS NULL OR b.expiry_date >= coalesce(p_on, CURRENT_DATE))
   ORDER BY b.expiry_date ASC NULLS LAST, b.received_date ASC;
$function$;

GRANT EXECUTE ON FUNCTION public.pharmacy_dispensable_batches(uuid, date) TO authenticated;

-- What must NOT go out, so somebody can pull it off the shelf. Expired
-- stock that nobody has been told about is expired stock that gets sold.
DROP FUNCTION IF EXISTS public.pharmacy_expired_stock(date);
CREATE OR REPLACE FUNCTION public.pharmacy_expired_stock(p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_batch_id     uuid,
   out_product      text,
   out_batch_number text,
   out_expiry       date,
   out_quantity     numeric,
   out_days_expired integer,
   out_value        numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT b.id, p.name, b.batch_number, b.expiry_date, b.quantity,
         (coalesce(p_on, CURRENT_DATE) - b.expiry_date)::integer,
         round(coalesce(b.quantity, 0) * coalesce(b.cost_price, 0), 2)
    FROM pharmacy_batches b
    JOIN pharmacy_products p ON p.id = b.product_id
   WHERE coalesce(b.quantity, 0) > 0
     AND b.expiry_date IS NOT NULL
     AND b.expiry_date < coalesce(p_on, CURRENT_DATE)
   ORDER BY b.expiry_date;
$function$;

GRANT EXECUTE ON FUNCTION public.pharmacy_expired_stock(date) TO authenticated;

-- Stock that will expire soon, so it can be used or returned in time.
DROP FUNCTION IF EXISTS public.pharmacy_expiring_soon(integer, date);
CREATE OR REPLACE FUNCTION public.pharmacy_expiring_soon(p_days integer DEFAULT 90, p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_batch_id     uuid,
   out_product      text,
   out_batch_number text,
   out_expiry       date,
   out_quantity     numeric,
   out_days_left    integer
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT b.id, p.name, b.batch_number, b.expiry_date, b.quantity,
         (b.expiry_date - coalesce(p_on, CURRENT_DATE))::integer
    FROM pharmacy_batches b
    JOIN pharmacy_products p ON p.id = b.product_id
   WHERE coalesce(b.quantity, 0) > 0
     AND coalesce(b.quarantined, false) = false
     AND b.expiry_date IS NOT NULL
     AND b.expiry_date >= coalesce(p_on, CURRENT_DATE)
     AND b.expiry_date <= coalesce(p_on, CURRENT_DATE) + greatest(coalesce(p_days, 90), 0)
   ORDER BY b.expiry_date;
$function$;

GRANT EXECUTE ON FUNCTION public.pharmacy_expiring_soon(integer, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.quarantine_pharmacy_batch(p_batch_id uuid, p_reason text, p_release boolean DEFAULT false)
 RETURNS public.pharmacy_batches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_b pharmacy_batches;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('pharmacist', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only a pharmacist or a manager may hold a batch back';
  END IF;
  IF NOT p_release AND coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Holding a batch back requires a reason';
  END IF;

  UPDATE pharmacy_batches
     SET quarantined = NOT p_release,
         quarantine_reason = CASE WHEN p_release THEN NULL ELSE p_reason END
   WHERE id = p_batch_id
  RETURNING * INTO v_b;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'Batch not found'; END IF;
  RETURN v_b;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.quarantine_pharmacy_batch(uuid, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------
-- 2. EVERY MOVEMENT OF A BATCH IS RECORDED
-- Batch tracking exists so a recall can be answered. That only works if
-- nothing can change a batch quantity without leaving a row saying who
-- changed it and what for. The trigger below is on the table, not in the
-- functions, so there is no path around it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pharmacy_batch_movements (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  batch_id       uuid NOT NULL,
  movement_type  text NOT NULL,        -- opening | receive | dispense | void_return | adjust | write_off
  quantity_delta numeric NOT NULL,
  quantity_after numeric NOT NULL,
  reference      text,
  reason         text,
  employee_id    uuid,
  created_at     timestamp with time zone DEFAULT now(),
  CONSTRAINT pharmacy_batch_movements_pkey PRIMARY KEY (id),
  CONSTRAINT pharmacy_batch_movements_batch_fkey FOREIGN KEY (batch_id)
    REFERENCES public.pharmacy_batches(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_pharmacy_batch_movements_batch
  ON public.pharmacy_batch_movements (batch_id, created_at);

CREATE OR REPLACE FUNCTION public.pharmacy_batch_movement_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_delta  numeric;
  v_type   text := nullif(current_setting('kareya.pharmacy_move', true), '');
  v_reason text := nullif(current_setting('kareya.pharmacy_reason', true), '');
  v_ref    text := nullif(current_setting('kareya.pharmacy_ref', true), '');
  v_emp    uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_delta := coalesce(NEW.quantity, 0);
    v_type  := coalesce(v_type, 'receive');
  ELSE
    v_delta := coalesce(NEW.quantity, 0) - coalesce(OLD.quantity, 0);
    IF v_delta = 0 THEN RETURN NEW; END IF;
    -- A quantity that moves with nothing saying why is the thing that makes
    -- a stock record unusable. Correct a count with adjust_pharmacy_batch().
    IF v_type IS NULL THEN
      RAISE EXCEPTION 'A batch quantity cannot be changed directly. Dispense, void, or use a stock adjustment with a reason.';
    END IF;
  END IF;

  BEGIN
    SELECT id INTO v_emp FROM employees
      WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
      ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  EXCEPTION WHEN OTHERS THEN v_emp := NULL;
  END;

  INSERT INTO pharmacy_batch_movements (batch_id, movement_type, quantity_delta,
                                        quantity_after, reference, reason, employee_id)
  VALUES (NEW.id, v_type, v_delta, coalesce(NEW.quantity, 0), v_ref, v_reason, v_emp);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pharmacy_batch_movement_log ON public.pharmacy_batches;
CREATE TRIGGER trg_pharmacy_batch_movement_log
  AFTER INSERT OR UPDATE OF quantity ON public.pharmacy_batches
  FOR EACH ROW EXECUTE FUNCTION public.pharmacy_batch_movement_log();

-- Batches that were already on the shelf before this file was applied get
-- an opening row, so the ledger adds up to what is there rather than
-- pretending the history it never had.
INSERT INTO public.pharmacy_batch_movements (batch_id, movement_type, quantity_delta, quantity_after, reason)
SELECT b.id, 'opening', coalesce(b.quantity, 0), coalesce(b.quantity, 0),
       'On the shelf before movements were recorded'
  FROM public.pharmacy_batches b
 WHERE NOT EXISTS (SELECT 1 FROM public.pharmacy_batch_movements m WHERE m.batch_id = b.id);

CREATE OR REPLACE FUNCTION public.pharmacy_movement_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  RAISE EXCEPTION 'A batch movement is a record of something that happened. It cannot be changed or removed.';
END;
$function$;

DROP TRIGGER IF EXISTS trg_pharmacy_movement_append_only ON public.pharmacy_batch_movements;
CREATE TRIGGER trg_pharmacy_movement_append_only
  BEFORE UPDATE OR DELETE ON public.pharmacy_batch_movements
  FOR EACH ROW EXECUTE FUNCTION public.pharmacy_movement_append_only();

-- The supported way to correct a batch after a physical count. It takes the
-- counted figure, not a delta, because that is what the person holding the
-- shelf actually knows.
CREATE OR REPLACE FUNCTION public.adjust_pharmacy_batch(p_batch_id uuid, p_counted_quantity numeric, p_reason text)
 RETURNS public.pharmacy_batches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_b pharmacy_batches;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('pharmacist', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only a pharmacist or a manager may adjust stock';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A stock adjustment requires a reason';
  END IF;
  IF p_counted_quantity IS NULL OR p_counted_quantity < 0 THEN
    RAISE EXCEPTION 'A counted quantity cannot be negative';
  END IF;

  SELECT * INTO v_b FROM pharmacy_batches WHERE id = p_batch_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'Batch not found'; END IF;

  PERFORM set_config('kareya.pharmacy_move', 'adjust', true);
  PERFORM set_config('kareya.pharmacy_reason', p_reason, true);
  UPDATE pharmacy_batches SET quantity = p_counted_quantity WHERE id = p_batch_id RETURNING * INTO v_b;
  PERFORM set_config('kareya.pharmacy_move', '', true);
  PERFORM set_config('kareya.pharmacy_reason', '', true);
  RETURN v_b;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.adjust_pharmacy_batch(uuid, numeric, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 3. SALE NUMBERS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pharmacy_sale_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'RX-',
  width   integer DEFAULT 6,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT pharmacy_sale_series_pkey PRIMARY KEY (id),
  CONSTRAINT pharmacy_sale_series_singleton CHECK (id = true)
);
INSERT INTO public.pharmacy_sale_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_pharmacy_sale_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_s pharmacy_sale_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pharmacy_sale_series'));
  SELECT * INTO v_s FROM pharmacy_sale_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO pharmacy_sale_series (id) VALUES (true) RETURNING * INTO v_s; END IF;

  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE pharmacy_sale_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE pharmacy_sale_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;

  RETURN coalesce(v_s.prefix, 'RX-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 6), 1), '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.pharmacy_sale_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.sale_number := allocate_pharmacy_sale_no(CURRENT_DATE);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pharmacy_sale_number ON public.pharmacy_sales;
CREATE TRIGGER trg_pharmacy_sale_number
  BEFORE INSERT ON public.pharmacy_sales
  FOR EACH ROW EXECUTE FUNCTION public.pharmacy_sale_number();

DO $$
DECLARE r record; s record; n integer;
BEGIN
  FOR r IN SELECT sale_number FROM public.pharmacy_sales
            WHERE sale_number IS NOT NULL
            GROUP BY sale_number HAVING count(*) > 1 LOOP
    n := 0;
    FOR s IN SELECT id FROM public.pharmacy_sales WHERE sale_number = r.sale_number ORDER BY created_at LOOP
      n := n + 1;
      IF n > 1 THEN UPDATE public.pharmacy_sales SET sale_number = sale_number || '-' || n WHERE id = s.id; END IF;
    END LOOP;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pharmacy_sales_number
  ON public.pharmacy_sales (sale_number) WHERE sale_number IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4. DISPENSING
-- One transaction. The batches are locked, allocated in date order from
-- the DATABASE's figures, and the sale is written with them.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.dispense_pharmacy_sale(jsonb, text, text, text, text, numeric, numeric);
CREATE OR REPLACE FUNCTION public.dispense_pharmacy_sale(
  p_items          jsonb,                       -- [{product_id, description, quantity, unit_price}]
  p_customer_name  text DEFAULT NULL,
  p_prescriber     text DEFAULT NULL,
  p_rx_reference   text DEFAULT NULL,
  p_payment_method text DEFAULT 'cash',
  p_discount       numeric DEFAULT 0,
  p_tax_rate       numeric DEFAULT 0
)
 RETURNS public.pharmacy_sales
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp    employees;
  v_line   jsonb;
  v_prod   pharmacy_products;
  v_batch  record;
  v_want   numeric;
  v_take   numeric;
  v_left   numeric;
  v_sub    numeric := 0;
  v_disc   numeric;
  v_taxbl  numeric;
  v_tax    numeric;
  v_sale   pharmacy_sales;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('pharmacist', 'cashier', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Your role cannot dispense medicine';
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'There is nothing to dispense';
  END IF;

  -- Everything is checked before anything moves, so a refusal on the last
  -- line does not leave the first one already off the shelf.
  FOR v_line IN SELECT l FROM jsonb_array_elements(p_items) l LOOP
    SELECT * INTO v_prod FROM pharmacy_products WHERE id = (v_line->>'product_id')::uuid;
    IF v_prod.id IS NULL THEN RAISE EXCEPTION 'That product does not exist'; END IF;
    IF coalesce(v_prod.is_active, true) = false THEN
      RAISE EXCEPTION '% is withdrawn and cannot be dispensed', v_prod.name;
    END IF;

    v_want := coalesce((v_line->>'quantity')::numeric, 0);
    IF v_want <= 0 THEN RAISE EXCEPTION 'A line for % has no quantity', v_prod.name; END IF;

    -- The flag existed and nothing ever read it.
    IF coalesce(v_prod.requires_rx, false)
       AND (coalesce(trim(p_prescriber), '') = '' OR coalesce(trim(p_rx_reference), '') = '') THEN
      RAISE EXCEPTION '% is prescription-only. Record the prescriber and the prescription reference.', v_prod.name;
    END IF;

    -- Only stock that is in date counts. The old check summed EVERY batch,
    -- so a shelf full of expired medicine read as plenty in stock.
    IF (SELECT coalesce(sum(out_quantity), 0)
          FROM pharmacy_dispensable_batches(v_prod.id, CURRENT_DATE)) < v_want THEN
      RAISE EXCEPTION 'Not enough % in date: % dispensable, % asked for', v_prod.name,
        (SELECT coalesce(sum(out_quantity), 0) FROM pharmacy_dispensable_batches(v_prod.id, CURRENT_DATE)), v_want;
    END IF;

    v_sub := round(v_sub + v_want * coalesce((v_line->>'unit_price')::numeric, 0), 2);
  END LOOP;

  v_disc  := greatest(coalesce(p_discount, 0), 0);
  v_taxbl := greatest(v_sub - v_disc, 0);
  v_tax   := round(v_taxbl * coalesce(p_tax_rate, 0) / 100, 2);

  INSERT INTO pharmacy_sales (customer_name, prescriber, rx_reference, subtotal, discount,
                              tax_rate, tax_amount, total, payment_method, status, sold_by)
  VALUES (p_customer_name, p_prescriber, p_rx_reference, v_sub, v_disc,
          coalesce(p_tax_rate, 0), v_tax, round(v_taxbl + v_tax, 2),
          coalesce(p_payment_method, 'cash'), 'completed', v_emp.id)
  RETURNING * INTO v_sale;

  PERFORM set_config('kareya.pharmacy_move', 'dispense', true);
  PERFORM set_config('kareya.pharmacy_ref', v_sale.sale_number, true);
  PERFORM set_config('kareya.pharmacy_reason', 'Dispensed', true);

  -- Allocate. FOR UPDATE is what makes two pharmacists dispensing the same
  -- drug at the same moment take two lots off the shelf instead of one.
  FOR v_line IN SELECT l FROM jsonb_array_elements(p_items) l LOOP
    v_left := coalesce((v_line->>'quantity')::numeric, 0);
    FOR v_batch IN
      SELECT b.* FROM pharmacy_batches b
       WHERE b.product_id = (v_line->>'product_id')::uuid
         AND coalesce(b.quantity, 0) > 0
         AND coalesce(b.quarantined, false) = false
         AND (b.expiry_date IS NULL OR b.expiry_date >= CURRENT_DATE)
       ORDER BY b.expiry_date ASC NULLS LAST, b.received_date ASC
       FOR UPDATE
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_batch.quantity, v_left);
      v_left := v_left - v_take;

      UPDATE pharmacy_batches SET quantity = quantity - v_take WHERE id = v_batch.id;

      INSERT INTO pharmacy_sale_items (sale_id, product_id, batch_id, description, quantity, unit_price, line_total)
      VALUES (v_sale.id, v_batch.product_id, v_batch.id, v_line->>'description',
              v_take, coalesce((v_line->>'unit_price')::numeric, 0),
              round(v_take * coalesce((v_line->>'unit_price')::numeric, 0), 2));
    END LOOP;

    -- Another transaction can take stock between the check above and here.
    -- The whole sale fails rather than handing over less than was rung up.
    IF v_left > 0 THEN
      RAISE EXCEPTION 'Somebody else took the last of that stock while this sale was being written. Nothing was dispensed.';
    END IF;
  END LOOP;

  PERFORM set_config('kareya.pharmacy_move', '', true);
  PERFORM set_config('kareya.pharmacy_ref', '', true);
  PERFORM set_config('kareya.pharmacy_reason', '', true);

  RETURN v_sale;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.dispense_pharmacy_sale(jsonb, text, text, text, text, numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. VOIDING PUTS THE MEDICINE BACK
-- The old version flipped a status column and left the batches
-- decremented, so stock nobody had been given read as gone.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_pharmacy_sale(p_sale_id uuid, p_reason text)
 RETURNS public.pharmacy_sales
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_sale pharmacy_sales; v_item pharmacy_sale_items;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('pharmacist', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only a pharmacist or a manager may void a dispensing';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a dispensing requires a reason';
  END IF;

  SELECT * INTO v_sale FROM pharmacy_sales WHERE id = p_sale_id FOR UPDATE;
  IF v_sale.id IS NULL THEN RAISE EXCEPTION 'Sale not found'; END IF;
  IF v_sale.status = 'void' THEN RAISE EXCEPTION 'Sale % is already void', v_sale.sale_number; END IF;

  PERFORM set_config('kareya.pharmacy_move', 'void_return', true);
  PERFORM set_config('kareya.pharmacy_ref', v_sale.sale_number, true);
  PERFORM set_config('kareya.pharmacy_reason', p_reason, true);

  -- The medicine goes back to the batch it came from, so its expiry still
  -- travels with it. Putting it anywhere else would lose that.
  FOR v_item IN SELECT * FROM pharmacy_sale_items WHERE sale_id = p_sale_id LOOP
    IF v_item.batch_id IS NOT NULL THEN
      UPDATE pharmacy_batches SET quantity = coalesce(quantity, 0) + coalesce(v_item.quantity, 0)
       WHERE id = v_item.batch_id;
    END IF;
  END LOOP;

  PERFORM set_config('kareya.pharmacy_move', '', true);
  PERFORM set_config('kareya.pharmacy_ref', '', true);
  PERFORM set_config('kareya.pharmacy_reason', '', true);

  UPDATE pharmacy_sales SET status = 'void' WHERE id = p_sale_id RETURNING * INTO v_sale;
  RETURN v_sale;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.void_pharmacy_sale(uuid, text) TO authenticated;

-- A dispensing record is what somebody was handed. Its lines are not
-- editable; correcting one means voiding it and dispensing again, which
-- is also what puts the stock back.
CREATE OR REPLACE FUNCTION public.pharmacy_sale_is_final()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A dispensing record cannot be deleted. Void it, so the medicine goes back on the shelf and the record stays.';
  END IF;
  IF TG_TABLE_NAME = 'pharmacy_sale_items' THEN
    RAISE EXCEPTION 'What was handed over cannot be edited. Void the sale and dispense again.';
  END IF;
  IF NEW.sale_number IS DISTINCT FROM OLD.sale_number
     OR NEW.total IS DISTINCT FROM OLD.total
     OR NEW.subtotal IS DISTINCT FROM OLD.subtotal THEN
    RAISE EXCEPTION 'Sale % cannot be edited. Void it and dispense again.', OLD.sale_number;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pharmacy_sale_is_final ON public.pharmacy_sales;
CREATE TRIGGER trg_pharmacy_sale_is_final
  BEFORE UPDATE OR DELETE ON public.pharmacy_sales
  FOR EACH ROW EXECUTE FUNCTION public.pharmacy_sale_is_final();

DROP TRIGGER IF EXISTS trg_pharmacy_sale_items_final ON public.pharmacy_sale_items;
CREATE TRIGGER trg_pharmacy_sale_items_final
  BEFORE UPDATE OR DELETE ON public.pharmacy_sale_items
  FOR EACH ROW EXECUTE FUNCTION public.pharmacy_sale_is_final();

-- ---------------------------------------------------------------------
-- 6. WHAT THE SHELF SAYS VERSUS WHAT THE LEDGER SAYS
-- This names drift. It does not correct it: deciding whether a batch of
-- medicine is really there is a job for somebody counting it, and a
-- migration that quietly wrote a number would be inventing the answer.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.pharmacy_reconciliation(date);
CREATE OR REPLACE FUNCTION public.pharmacy_reconciliation(p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_batch_id     uuid,
   out_product      text,
   out_batch_number text,
   out_expiry       date,
   out_on_shelf     numeric,
   out_per_ledger   numeric,
   out_difference   numeric,
   out_issue        text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH led AS (
    SELECT m.batch_id, sum(m.quantity_delta) AS total
      FROM pharmacy_batch_movements m GROUP BY m.batch_id
  )
  SELECT b.id, p.name, b.batch_number, b.expiry_date,
         coalesce(b.quantity, 0),
         coalesce(led.total, 0),
         coalesce(b.quantity, 0) - coalesce(led.total, 0),
         CASE
           WHEN coalesce(b.quantity, 0) < 0
             THEN 'The shelf figure is negative. Count it and adjust.'
           WHEN coalesce(b.quantity, 0) <> coalesce(led.total, 0)
             THEN 'The shelf figure and the movements disagree.'
           WHEN b.expiry_date IS NOT NULL AND b.expiry_date < coalesce(p_on, CURRENT_DATE)
                AND coalesce(b.quantity, 0) > 0
             THEN 'Expired stock is still on the shelf. It will not be dispensed, but it should be removed.'
           ELSE NULL
         END
    FROM pharmacy_batches b
    JOIN pharmacy_products p ON p.id = b.product_id
    LEFT JOIN led ON led.batch_id = b.id
   WHERE coalesce(b.quantity, 0) < 0
      OR coalesce(b.quantity, 0) <> coalesce(led.total, 0)
      OR (b.expiry_date IS NOT NULL AND b.expiry_date < coalesce(p_on, CURRENT_DATE)
          AND coalesce(b.quantity, 0) > 0)
   ORDER BY p.name, b.expiry_date;
$function$;

GRANT EXECUTE ON FUNCTION public.pharmacy_reconciliation(date) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Manage pharmacy sales" ON public.pharmacy_sales;
DROP POLICY IF EXISTS "Manage pharmacy sale items" ON public.pharmacy_sale_items;
DROP POLICY IF EXISTS "Manage pharmacy batches" ON public.pharmacy_batches;

-- Receiving stock stays an ordinary write, and correcting a supplier or a
-- batch number stays an ordinary edit. Taking stock off the shelf does not:
-- the movement trigger refuses a quantity change that arrives without a
-- reason, so dispensing and adjustments have to come through their RPCs.
DROP POLICY IF EXISTS pharmacy_batches_receive ON public.pharmacy_batches;
CREATE POLICY pharmacy_batches_receive ON public.pharmacy_batches
  FOR INSERT TO authenticated
  WITH CHECK (public.has_any_role(ARRAY['Pharmacist', 'Manager']));

DROP POLICY IF EXISTS pharmacy_batches_amend ON public.pharmacy_batches;
CREATE POLICY pharmacy_batches_amend ON public.pharmacy_batches
  FOR UPDATE TO authenticated
  USING (public.has_any_role(ARRAY['Pharmacist', 'Manager']))
  WITH CHECK (public.has_any_role(ARRAY['Pharmacist', 'Manager']));

ALTER TABLE public.pharmacy_batch_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pharmacy_batch_movements_read ON public.pharmacy_batch_movements;
CREATE POLICY pharmacy_batch_movements_read ON public.pharmacy_batch_movements
  FOR SELECT TO authenticated
  USING (public.has_any_role(ARRAY['Pharmacist', 'Cashier', 'Accountant', 'Manager']));

ALTER TABLE public.pharmacy_sale_series ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pharmacy_sale_series_read ON public.pharmacy_sale_series;
CREATE POLICY pharmacy_sale_series_read ON public.pharmacy_sale_series
  FOR SELECT TO authenticated USING (public.is_employee());
DROP POLICY IF EXISTS pharmacy_sale_series_write ON public.pharmacy_sale_series;
CREATE POLICY pharmacy_sale_series_write ON public.pharmacy_sale_series
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_founder()) WITH CHECK (public.is_admin_or_founder());
