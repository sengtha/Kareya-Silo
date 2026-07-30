-- =====================================================================
-- KAREYA SILO — TOUR: SEATS, MONEY AND CANCELLATION
-- ---------------------------------------------------------------------
-- NAMING NOTE: this file must sort AFTER `tour_itinerary.sql`, whose
-- pricing functions it calls. Verticals apply in alphabetical order and
-- `tour_selling` sorts after `tour_itinerary`. Do not rename either
-- without checking that.
--
-- WHAT WAS WRONG
--
-- 1. THE SEAT COUNT WAS THE BROWSER'S. `useTravel.tsx:93` summed the
--    bookings the browser happened to be holding and compared them with
--    the capacity. Two agents selling the last seat at the same moment
--    both saw it free. Nothing in the database stopped the second one.
--
-- 2. PAYMENT HISTORY WAS ONE COLUMN. `paid_amount` was read, added to and
--    written back (`useTravel.tsx:107`). A tour taken as a deposit, a
--    second instalment and a balance on the day left one number. Who took
--    it, when, how and whether any of it was refunded — all gone.
--
-- 3. THE TOTAL WAS COMPUTED IN THE BROWSER. `total: round2(pax * unit)`
--    at `useTravel.tsx:98`. Change the price afterwards and the total is
--    whatever it was when somebody last pressed a button.
--
-- 4. CANCELLING JUST SET A FLAG. No cancellation charge, no record of
--    when or why, and money already taken sat on the cancelled booking as
--    though it were still earned.
--
-- 5. THE PRICE CAME FROM `base_price`. One number for a party of two and
--    a party of ten. `tour_itinerary.sql` fixed the pricing; this file
--    makes the booking use it.
--
-- Idempotent. Apply AFTER tour_itinerary.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHAT A BOOKING CARRIES
-- ---------------------------------------------------------------------
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS child_pax integer DEFAULT 0;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS single_rooms integer DEFAULT 0;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS child_price numeric DEFAULT 0;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS single_supplement numeric DEFAULT 0;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS costing_id uuid;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS cancelled_at timestamp with time zone;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS cancellation_charge numeric DEFAULT 0;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS cancellation_reason text;
ALTER TABLE public.tour_bookings ADD COLUMN IF NOT EXISTS booked_by uuid;

COMMENT ON COLUMN public.tour_bookings.pax IS
  'Adults. Children are counted separately in child_pax and priced separately.';
COMMENT ON COLUMN public.tour_bookings.paid_amount IS
  'Derived from tour_booking_payments. Do not write to it directly.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tour_bookings_costing_fkey') THEN
    ALTER TABLE public.tour_bookings ADD CONSTRAINT tour_bookings_costing_fkey
      FOREIGN KEY (costing_id) REFERENCES public.tour_costings(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tour_bookings_booked_by_fkey') THEN
    ALTER TABLE public.tour_bookings ADD CONSTRAINT tour_bookings_booked_by_fkey
      FOREIGN KEY (booked_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
END $$;

-- The total is arithmetic, so the database does it. Adults at the band
-- price, children at the child price, and one supplement per single room.
CREATE OR REPLACE FUNCTION public.tour_booking_recalc()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  NEW.total := round(
      coalesce(NEW.pax, 0) * coalesce(NEW.unit_price, 0)
    + coalesce(NEW.child_pax, 0) * coalesce(NEW.child_price, 0)
    + coalesce(NEW.single_rooms, 0) * coalesce(NEW.single_supplement, 0), 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tour_booking_recalc ON public.tour_bookings;
CREATE TRIGGER trg_tour_booking_recalc
  BEFORE INSERT OR UPDATE ON public.tour_bookings
  FOR EACH ROW EXECUTE FUNCTION public.tour_booking_recalc();

-- ---------------------------------------------------------------------
-- 2. SEATS, COUNTED WHERE THEY CANNOT BE MISCOUNTED
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.tour_departure_seats(uuid);
CREATE OR REPLACE FUNCTION public.tour_departure_seats(p_departure_id uuid)
 RETURNS TABLE (out_capacity integer, out_sold integer, out_remaining integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_cap integer; v_sold integer;
BEGIN
  SELECT capacity INTO v_cap FROM tour_departures WHERE id = p_departure_id;
  IF v_cap IS NULL THEN RAISE EXCEPTION 'That departure does not exist'; END IF;
  -- Children take a seat on the coach whatever they pay.
  SELECT coalesce(sum(coalesce(pax, 0) + coalesce(child_pax, 0)), 0) INTO v_sold
    FROM tour_bookings WHERE departure_id = p_departure_id AND status <> 'cancelled';
  out_capacity := v_cap; out_sold := v_sold; out_remaining := v_cap - v_sold;
  RETURN NEXT;
END;
$$;

-- ---- booking numbers -------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tour_booking_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'TB-',
  width   integer DEFAULT 4,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT tour_booking_series_pkey PRIMARY KEY (id),
  CONSTRAINT tour_booking_series_singleton CHECK (id = true)
);
INSERT INTO public.tour_booking_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_tour_booking_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_s tour_booking_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('tour_booking_series'));
  SELECT * INTO v_s FROM tour_booking_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO tour_booking_series (id) VALUES (true) RETURNING * INTO v_s; END IF;
  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE tour_booking_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE tour_booking_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;
  RETURN coalesce(v_s.prefix, 'TB-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 4), 1), '0');
END;
$$;

-- Take seats. The capacity check and the write are one transaction, under
-- a lock on the departure, so two agents cannot both sell the last seat.
CREATE OR REPLACE FUNCTION public.book_tour_seats(
  p_departure_id uuid,
  p_customer_name text,
  p_pax integer DEFAULT 1,
  p_child_pax integer DEFAULT 0,
  p_single_rooms integer DEFAULT 0,
  p_customer_phone text DEFAULT NULL,
  p_note text DEFAULT NULL)
 RETURNS tour_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_dep tour_departures;
  v_seats record;
  v_price record;
  v_unit numeric; v_child numeric; v_single numeric; v_costing uuid;
  v_b tour_bookings;
  v_me uuid;
BEGIN
  IF coalesce(p_customer_name, '') = '' THEN RAISE EXCEPTION 'A booking needs a name on it'; END IF;
  IF coalesce(p_pax, 0) + coalesce(p_child_pax, 0) <= 0 THEN
    RAISE EXCEPTION 'A booking needs somebody travelling on it';
  END IF;
  IF coalesce(p_single_rooms, 0) > coalesce(p_pax, 0) THEN
    RAISE EXCEPTION 'More single rooms than adults travelling';
  END IF;

  -- The lock is the whole point. Everything below reads a settled world.
  SELECT * INTO v_dep FROM tour_departures WHERE id = p_departure_id FOR UPDATE;
  IF v_dep.id IS NULL THEN RAISE EXCEPTION 'That departure does not exist'; END IF;
  IF v_dep.status IN ('cancelled', 'completed', 'departed') THEN
    RAISE EXCEPTION 'That departure has already %', v_dep.status;
  END IF;

  SELECT * INTO v_seats FROM tour_departure_seats(p_departure_id);
  IF coalesce(p_pax, 0) + coalesce(p_child_pax, 0) > v_seats.out_remaining THEN
    RAISE EXCEPTION 'Only % seat(s) left on this departure', v_seats.out_remaining;
  END IF;

  -- Priced for THIS party size, on the departure date, from the costing
  -- that is valid then.
  SELECT * INTO v_price
    FROM tour_price_for(v_dep.package_id,
                        coalesce(p_pax, 0) + coalesce(p_child_pax, 0),
                        v_dep.depart_date);

  IF v_price.out_price IS NULL THEN
    -- A departure may carry its own negotiated price. Falling back to it
    -- is fine; falling back silently to a package figure nobody costed is
    -- not.
    IF v_dep.price IS NULL THEN
      RAISE EXCEPTION 'No published price covers a party of % on %. Publish a costing, or set a price on the departure.',
        coalesce(p_pax, 0) + coalesce(p_child_pax, 0), v_dep.depart_date;
    END IF;
    v_unit := v_dep.price; v_child := v_dep.price; v_single := 0; v_costing := NULL;
  ELSE
    v_unit := v_price.out_price; v_child := v_price.out_child;
    v_single := v_price.out_single; v_costing := v_price.out_costing_id;
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  INSERT INTO tour_bookings (booking_number, departure_id, customer_name, customer_phone,
                             pax, child_pax, single_rooms, unit_price, child_price,
                             single_supplement, costing_id, paid_amount, status, note, booked_by)
  VALUES (allocate_tour_booking_no(), p_departure_id, p_customer_name, p_customer_phone,
          coalesce(p_pax, 0), coalesce(p_child_pax, 0), coalesce(p_single_rooms, 0),
          v_unit, v_child, v_single, v_costing, 0, 'pending', p_note, v_me)
  RETURNING * INTO v_b;

  RETURN v_b;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. MONEY, KEPT AS A LEDGER
-- One row per movement. A refund is a movement, not an edit.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tour_booking_payments (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  booking_id  uuid NOT NULL,
  paid_on     date DEFAULT CURRENT_DATE NOT NULL,
  amount      numeric NOT NULL,               -- negative for a refund
  method      text DEFAULT 'cash',            -- cash | bank | card | wallet | other
  reference   text,
  kind        text DEFAULT 'payment' NOT NULL,-- deposit | payment | balance | refund
  taken_by    uuid,
  voided      boolean DEFAULT false,
  void_reason text,
  notes       text,
  created_at  timestamp with time zone DEFAULT now(),
  CONSTRAINT tour_booking_payments_pkey PRIMARY KEY (id),
  CONSTRAINT tour_booking_payments_booking_fkey FOREIGN KEY (booking_id)
    REFERENCES public.tour_bookings(id) ON DELETE CASCADE,
  CONSTRAINT tour_booking_payments_taken_fkey FOREIGN KEY (taken_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT tour_booking_payments_kind_check CHECK (kind = ANY (ARRAY[
    'deposit', 'payment', 'balance', 'refund'])),
  CONSTRAINT tour_booking_payments_amount_check CHECK (amount <> 0)
);

CREATE INDEX IF NOT EXISTS idx_tour_booking_payments_booking ON public.tour_booking_payments (booking_id);

-- A ledger you can edit is not a ledger.
CREATE OR REPLACE FUNCTION public.tour_payment_is_a_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A payment cannot be deleted. Void it, which leaves the record and the reason.';
  END IF;
  IF OLD.amount IS DISTINCT FROM NEW.amount
     OR OLD.paid_on IS DISTINCT FROM NEW.paid_on
     OR OLD.booking_id IS DISTINCT FROM NEW.booking_id THEN
    RAISE EXCEPTION 'A payment cannot be rewritten. Void it and take a new one.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tour_payment_is_a_record ON public.tour_booking_payments;
CREATE TRIGGER trg_tour_payment_is_a_record
  BEFORE UPDATE OR DELETE ON public.tour_booking_payments
  FOR EACH ROW EXECUTE FUNCTION public.tour_payment_is_a_record();

-- paid_amount on the booking follows the ledger, always.
CREATE OR REPLACE FUNCTION public.tour_booking_paid_recalc()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_id uuid; v_paid numeric; v_b tour_bookings;
BEGIN
  v_id := coalesce(NEW.booking_id, OLD.booking_id);
  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM tour_booking_payments WHERE booking_id = v_id AND NOT voided;
  SELECT * INTO v_b FROM tour_bookings WHERE id = v_id;

  UPDATE tour_bookings SET
    paid_amount = round(v_paid, 2),
    status = CASE
      WHEN v_b.status = 'cancelled' THEN 'cancelled'
      WHEN v_paid >= v_b.total - 0.005 AND v_b.total > 0 THEN 'paid'
      WHEN v_paid > 0 THEN 'confirmed'
      ELSE 'pending' END
  WHERE id = v_id;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_tour_booking_paid_recalc ON public.tour_booking_payments;
CREATE TRIGGER trg_tour_booking_paid_recalc
  AFTER INSERT OR UPDATE ON public.tour_booking_payments
  FOR EACH ROW EXECUTE FUNCTION public.tour_booking_paid_recalc();

CREATE OR REPLACE FUNCTION public.record_tour_payment(
  p_booking_id uuid,
  p_amount numeric,
  p_method text DEFAULT 'cash',
  p_kind text DEFAULT 'payment',
  p_reference text DEFAULT NULL,
  p_on date DEFAULT CURRENT_DATE)
 RETURNS tour_booking_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b tour_bookings; v_paid numeric; v_p tour_booking_payments; v_me uuid;
BEGIN
  SELECT * INTO v_b FROM tour_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF coalesce(p_amount, 0) = 0 THEN RAISE EXCEPTION 'A payment has to be an amount'; END IF;

  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM tour_booking_payments WHERE booking_id = p_booking_id AND NOT voided;

  IF p_amount > 0 AND v_paid + p_amount > v_b.total + 0.005 THEN
    RAISE EXCEPTION 'That is % more than the booking is for. Taken so far: % of %.',
      round(v_paid + p_amount - v_b.total, 2), round(v_paid, 2), round(v_b.total, 2);
  END IF;
  IF p_amount < 0 AND v_paid + p_amount < -0.005 THEN
    RAISE EXCEPTION 'That would refund more than was ever taken. Taken so far: %.', round(v_paid, 2);
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  INSERT INTO tour_booking_payments (booking_id, paid_on, amount, method, kind, reference, taken_by)
  VALUES (p_booking_id, coalesce(p_on, CURRENT_DATE), p_amount,
          coalesce(p_method, 'cash'),
          CASE WHEN p_amount < 0 THEN 'refund' ELSE coalesce(p_kind, 'payment') END,
          p_reference, v_me)
  RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_tour_payment(p_payment_id uuid, p_reason text)
 RETURNS tour_booking_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_p tour_booking_payments;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a payment needs a reason. It stays on the record.';
  END IF;
  SELECT * INTO v_p FROM tour_booking_payments WHERE id = p_payment_id FOR UPDATE;
  IF v_p.id IS NULL THEN RAISE EXCEPTION 'That payment does not exist'; END IF;
  IF v_p.voided THEN RAISE EXCEPTION 'That payment was already voided'; END IF;

  UPDATE tour_booking_payments SET voided = true, void_reason = p_reason
   WHERE id = p_payment_id RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. CANCELLATION
-- The seats come back, the money does not move by itself, and the reason
-- is written down.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_tour_booking(
  p_booking_id uuid, p_reason text, p_charge numeric DEFAULT 0)
 RETURNS tour_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b tour_bookings;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A cancellation needs a reason. It is the only thing worth reading about it later.';
  END IF;
  SELECT * INTO v_b FROM tour_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status = 'cancelled' THEN RAISE EXCEPTION 'That booking was already cancelled'; END IF;
  IF coalesce(p_charge, 0) < 0 THEN RAISE EXCEPTION 'A cancellation charge cannot be negative'; END IF;
  IF coalesce(p_charge, 0) > v_b.total THEN
    RAISE EXCEPTION 'A cancellation charge of % is more than the booking of %',
      round(p_charge, 2), round(v_b.total, 2);
  END IF;

  -- Kareya holds no cancellation scale. Days-before-departure terms are
  -- the operator's own and they vary by supplier contract, so the charge
  -- is entered rather than derived from a table nobody agreed to.
  UPDATE tour_bookings
     SET status = 'cancelled', cancelled_at = now(),
         cancellation_charge = coalesce(p_charge, 0),
         cancellation_reason = p_reason
   WHERE id = p_booking_id RETURNING * INTO v_b;

  -- The payments are left exactly where they are. A refund is its own
  -- movement, recorded by whoever actually hands the money back.
  RETURN v_b;
END;
$$;

-- What is owed, or owed back, on a cancelled booking.
DROP FUNCTION IF EXISTS public.tour_booking_position(uuid);
CREATE OR REPLACE FUNCTION public.tour_booking_position(p_booking_id uuid)
 RETURNS TABLE (
   out_total     numeric,
   out_paid      numeric,
   out_charge    numeric,   -- cancellation charge, if cancelled
   out_due       numeric,   -- still to collect
   out_refundable numeric   -- to hand back
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_b tour_bookings; v_paid numeric; v_owed numeric;
BEGIN
  SELECT * INTO v_b FROM tour_bookings WHERE id = p_booking_id;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;

  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM tour_booking_payments WHERE booking_id = p_booking_id AND NOT voided;

  -- A cancelled booking is owed the charge, not the tour.
  v_owed := CASE WHEN v_b.status = 'cancelled'
                 THEN coalesce(v_b.cancellation_charge, 0)
                 ELSE coalesce(v_b.total, 0) END;

  out_total      := round(coalesce(v_b.total, 0), 2);
  out_paid       := round(v_paid, 2);
  out_charge     := round(coalesce(v_b.cancellation_charge, 0), 2);
  out_due        := round(greatest(v_owed - v_paid, 0), 2);
  out_refundable := round(greatest(v_paid - v_owed, 0), 2);
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tour_selling_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Sold past the coach. Should be impossible through book_tour_seats;
  -- reported because rows can still arrive another way.
  SELECT 'departure', d.id, p.name || ' ' || d.depart_date::text,
         'Sold ' || s.out_sold::text || ' seats against a capacity of ' || s.out_capacity::text || '.'
    FROM tour_departures d
    JOIN tour_packages p ON p.id = d.package_id
    CROSS JOIN LATERAL tour_departure_seats(d.id) s
   WHERE s.out_sold > s.out_capacity

  UNION ALL
  -- The booking total no longer matches what it is made of.
  SELECT 'booking', b.id, coalesce(b.booking_number, b.customer_name),
         'Total is ' || b.total::text || ' but the parts come to '
         || round(b.pax * b.unit_price + b.child_pax * b.child_price
                  + b.single_rooms * b.single_supplement, 2)::text || '.'
    FROM tour_bookings b
   WHERE abs(coalesce(b.total, 0)
             - round(coalesce(b.pax, 0) * coalesce(b.unit_price, 0)
                   + coalesce(b.child_pax, 0) * coalesce(b.child_price, 0)
                   + coalesce(b.single_rooms, 0) * coalesce(b.single_supplement, 0), 2)) > 0.005

  UNION ALL
  -- paid_amount adrift from the ledger behind it.
  SELECT 'booking', b.id, coalesce(b.booking_number, b.customer_name),
         'Shows ' || coalesce(b.paid_amount, 0)::text || ' paid but the payments come to '
         || coalesce(pay.total, 0)::text || '.'
    FROM tour_bookings b
    LEFT JOIN LATERAL (SELECT coalesce(sum(amount), 0) AS total
                         FROM tour_booking_payments
                        WHERE booking_id = b.id AND NOT voided) pay ON true
   WHERE abs(coalesce(b.paid_amount, 0) - coalesce(pay.total, 0)) > 0.005

  UNION ALL
  -- Money sitting on a cancelled booking that nobody has handed back.
  SELECT 'booking', b.id, coalesce(b.booking_number, b.customer_name),
         'Cancelled with ' || pos.out_refundable::text || ' still to refund.'
    FROM tour_bookings b
    CROSS JOIN LATERAL tour_booking_position(b.id) pos
   WHERE b.status = 'cancelled' AND pos.out_refundable > 0.005

  UNION ALL
  -- Departed with money still outstanding.
  SELECT 'booking', b.id, coalesce(b.booking_number, b.customer_name),
         'Travelled with ' || pos.out_due::text || ' still uncollected.'
    FROM tour_bookings b
    JOIN tour_departures d ON d.id = b.departure_id
    CROSS JOIN LATERAL tour_booking_position(b.id) pos
   WHERE b.status <> 'cancelled' AND d.status IN ('departed', 'completed')
     AND pos.out_due > 0.005

  UNION ALL
  -- Priced off no costing at all.
  SELECT 'booking', b.id, coalesce(b.booking_number, b.customer_name),
         'Priced with no costing behind it, so nothing says where the figure came from.'
    FROM tour_bookings b
   WHERE b.costing_id IS NULL AND b.status <> 'cancelled' AND coalesce(b.unit_price, 0) > 0;
$$;

GRANT EXECUTE ON FUNCTION public.tour_departure_seats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_tour_booking_no(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.book_tour_seats(uuid, text, integer, integer, integer, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_tour_payment(uuid, numeric, text, text, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_tour_payment(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_tour_booking(uuid, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_booking_position(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tour_selling_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
ALTER TABLE public.tour_booking_payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "View tour payments" ON public.tour_booking_payments;
DROP POLICY IF EXISTS "Manage tour payments" ON public.tour_booking_payments;
CREATE POLICY "View tour payments" ON public.tour_booking_payments FOR SELECT TO authenticated
  USING (has_any_role(ARRAY['Travel Agent','Cashier','Accountant','Manager']));
CREATE POLICY "Manage tour payments" ON public.tour_booking_payments FOR ALL TO authenticated
  USING (has_any_role(ARRAY['Travel Agent','Cashier','Accountant','Manager']))
  WITH CHECK (has_any_role(ARRAY['Travel Agent','Cashier','Accountant','Manager']));
