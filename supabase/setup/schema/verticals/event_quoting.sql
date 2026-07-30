-- =====================================================================
-- KAREYA SILO — EVENTS: PER HEAD, PER TABLE, AND WHAT WAS QUOTED
-- ---------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- 1. THE GUEST COUNT DROVE NOTHING. `event_bookings.guests` sat on the
--    booking and not one charge line referred to it. A wedding is quoted
--    per head — the line said 'Catering — 40 tables' in its NAME and
--    carried a lump sum somebody had multiplied in their head. Move the
--    count from 350 to 400 and the quote did not change by a cent. On the
--    figures in the test suite that is $1,050 the planner has to notice
--    by hand, or eat.
--
-- 2. TABLES ARE NOT GUESTS. A venue charges by the table and a table
--    seats eight or ten. Tables are ceil(guests / seats), so the 351st
--    guest costs a whole extra table. Nobody sells a fraction of one, and
--    a lump sum cannot express a step.
--
-- 3. NO MINIMUM. A venue has a minimum, and a small wedding pays it
--    whatever the arithmetic says. Multiplying rate by guests under-
--    quotes every small event.
--
-- 4. THE TOTAL WAS THE BROWSER'S. `useEvents.tsx:103` summed the service
--    lines in JavaScript and stored nothing. There was no figure anywhere
--    saying what this event was worth.
--
-- 5. THERE WAS NO QUOTE. Services were edited in place, so the moment a
--    price changed there was no record of what the customer had actually
--    agreed to. A wedding is booked months ahead and argued about at the
--    end; the document is the whole point.
--
-- 6. PAYMENTS COULD ONLY BE DELETED. `event_payments` had no void and no
--    refund, so a mistaken receipt was corrected by erasing it.
--
-- 7. TWO WEDDINGS COULD BE BOOKED INTO ONE VENUE ON ONE DAY. Nothing
--    looked.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It ships no prices: no per-head catering rate, no venue charge, no
-- minimum, no table size, no deposit percentage and no cancellation
-- scale. Those are commercial terms that differ by venue, by season and
-- by customer, and a number invented here would be quoted to somebody
-- planning their wedding. Every figure is entered, with a vendor against
-- it.
--
-- Idempotent. Apply AFTER the base schema (event_bookings).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHAT A BOOKING KNOWS ABOUT ITSELF
-- ---------------------------------------------------------------------
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS seats_per_table integer DEFAULT 10;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS total_price numeric DEFAULT 0;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS total_cost numeric DEFAULT 0;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS start_time time;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS end_time time;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS cancelled_at timestamp with time zone;
ALTER TABLE public.event_bookings ADD COLUMN IF NOT EXISTS cancellation_reason text;

COMMENT ON COLUMN public.event_bookings.seats_per_table IS
  'How many sit at one table. Tables are ceil(guests / this), so the guest count decides them.';
COMMENT ON COLUMN public.event_bookings.total_price IS
  'Derived from the service lines. Do not write to it directly.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'event_bookings_seats_check') THEN
    ALTER TABLE public.event_bookings ADD CONSTRAINT event_bookings_seats_check
      CHECK (seats_per_table IS NULL OR seats_per_table > 0);
  END IF;
END $$;

-- How many tables this many guests need. Whole tables only.
CREATE OR REPLACE FUNCTION public.event_tables(p_booking_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT ceil(coalesce(b.guests, 0)::numeric / greatest(coalesce(b.seats_per_table, 10), 1))::integer
    FROM event_bookings b WHERE b.id = p_booking_id;
$$;

-- ---- the payment ledger ---------------------------------------------
ALTER TABLE public.event_payments ADD COLUMN IF NOT EXISTS voided boolean DEFAULT false;
ALTER TABLE public.event_payments ADD COLUMN IF NOT EXISTS void_reason text;
ALTER TABLE public.event_payments ADD COLUMN IF NOT EXISTS method text DEFAULT 'cash';
ALTER TABLE public.event_payments ADD COLUMN IF NOT EXISTS reference text;

-- The existing type check has no room for a refund, and a refund is a
-- movement rather than a deletion.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'event_payments_type_check') THEN
    ALTER TABLE public.event_payments DROP CONSTRAINT event_payments_type_check;
  END IF;
  ALTER TABLE public.event_payments ADD CONSTRAINT event_payments_type_check
    CHECK (type = ANY (ARRAY['deposit', 'installment', 'final', 'refund']));
END $$;

-- ---------------------------------------------------------------------
-- 2. A CHARGE LINE THAT KNOWS HOW IT IS SOLD
-- The existing `cost` and `price` columns stay, but stop being typed:
-- they become what the basis works out. Rows that were there before
-- default to per_event with a quantity of one, which computes to exactly
-- what they already held.
-- ---------------------------------------------------------------------
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS basis text DEFAULT 'per_event';
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS unit_cost numeric DEFAULT 0;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS unit_price numeric DEFAULT 0;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS quantity numeric DEFAULT 1;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS minimum_charge numeric DEFAULT 0;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS minimum_applied boolean DEFAULT false;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS is_optional boolean DEFAULT false;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS sort_order integer DEFAULT 0;
ALTER TABLE public.event_services ADD COLUMN IF NOT EXISTS notes text;

-- Existing rows keep the figures they had.
UPDATE public.event_services
   SET unit_price = coalesce(nullif(unit_price, 0), price),
       unit_cost  = coalesce(nullif(unit_cost, 0), cost)
 WHERE coalesce(unit_price, 0) = 0 AND coalesce(price, 0) <> 0;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'event_services_basis_check') THEN
    ALTER TABLE public.event_services ADD CONSTRAINT event_services_basis_check
      CHECK (basis = ANY (ARRAY['per_guest', 'per_table', 'per_event', 'per_hour', 'per_item']));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'event_services_min_check') THEN
    ALTER TABLE public.event_services ADD CONSTRAINT event_services_min_check
      CHECK (minimum_charge >= 0);
  END IF;
END $$;

-- What a line is multiplied by. per_guest and per_table read the booking,
-- which is the whole point: change the guest count and the quote moves.
CREATE OR REPLACE FUNCTION public.event_line_quantity(p_booking_id uuid, p_basis text, p_quantity numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_guests integer;
BEGIN
  SELECT coalesce(guests, 0) INTO v_guests FROM event_bookings WHERE id = p_booking_id;
  RETURN CASE p_basis
    WHEN 'per_guest' THEN v_guests
    WHEN 'per_table' THEN event_tables(p_booking_id)
    ELSE coalesce(p_quantity, 1)       -- per_event, per_hour, per_item
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.event_service_compute()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_qty numeric; v_price numeric;
BEGIN
  v_qty := event_line_quantity(NEW.booking_id, coalesce(NEW.basis, 'per_event'), NEW.quantity);
  v_price := round(v_qty * coalesce(NEW.unit_price, 0), 2);

  -- The minimum is the price on a small event. Multiplication never finds it.
  NEW.minimum_applied := v_price < coalesce(NEW.minimum_charge, 0);
  NEW.price := greatest(v_price, coalesce(NEW.minimum_charge, 0));
  NEW.cost  := round(v_qty * coalesce(NEW.unit_cost, 0), 2);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_service_compute ON public.event_services;
CREATE TRIGGER trg_event_service_compute
  BEFORE INSERT OR UPDATE ON public.event_services
  FOR EACH ROW EXECUTE FUNCTION public.event_service_compute();

-- The booking's totals follow its lines, so nothing has to sum them again.
CREATE OR REPLACE FUNCTION public.event_booking_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_id uuid;
BEGIN
  v_id := coalesce(NEW.booking_id, OLD.booking_id);
  UPDATE event_bookings b SET
    total_price = coalesce((SELECT sum(s.price) FROM event_services s
                             WHERE s.booking_id = v_id AND NOT s.is_optional), 0),
    total_cost  = coalesce((SELECT sum(s.cost) FROM event_services s
                             WHERE s.booking_id = v_id AND NOT s.is_optional), 0)
  WHERE b.id = v_id;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_event_booking_totals ON public.event_services;
CREATE TRIGGER trg_event_booking_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.event_services
  FOR EACH ROW EXECUTE FUNCTION public.event_booking_totals();

-- THE FIX FOR THE HEADLINE DEFECT. Change the guest count and every
-- per-head and per-table line moves with it, because the customer's
-- guest list is the one number that changes most and used to change
-- nothing at all.
CREATE OR REPLACE FUNCTION public.reprice_event(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  -- The compute trigger does the arithmetic; this only has to touch the rows.
  WITH bumped AS (
    UPDATE event_services SET quantity = quantity
     WHERE booking_id = p_booking_id RETURNING 1)
  SELECT count(*) INTO v_n FROM bumped;
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.event_guests_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF coalesce(NEW.guests, 0) IS DISTINCT FROM coalesce(OLD.guests, 0)
     OR coalesce(NEW.seats_per_table, 10) IS DISTINCT FROM coalesce(OLD.seats_per_table, 10) THEN
    PERFORM reprice_event(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_guests_changed ON public.event_bookings;
CREATE TRIGGER trg_event_guests_changed
  AFTER UPDATE ON public.event_bookings
  FOR EACH ROW EXECUTE FUNCTION public.event_guests_changed();

-- ---------------------------------------------------------------------
-- 3. ONE VENUE, ONE EVENT, ONE DAY
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_venue_free()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_clash text;
BEGIN
  IF coalesce(trim(NEW.venue), '') = '' OR NEW.event_date IS NULL
     OR NEW.status = 'cancelled' THEN
    RETURN NEW;
  END IF;

  SELECT b.event_name INTO v_clash
    FROM event_bookings b
   WHERE b.id <> NEW.id
     AND lower(trim(b.venue)) = lower(trim(NEW.venue))
     AND b.event_date = NEW.event_date
     AND b.status <> 'cancelled'
   LIMIT 1;

  IF v_clash IS NOT NULL THEN
    RAISE EXCEPTION '% is already booked at % on %. A venue holds one event at a time.',
      v_clash, NEW.venue, NEW.event_date;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_venue_free ON public.event_bookings;
CREATE TRIGGER trg_event_venue_free
  BEFORE INSERT OR UPDATE ON public.event_bookings
  FOR EACH ROW EXECUTE FUNCTION public.event_venue_free();

-- ---------------------------------------------------------------------
-- 4. THE QUOTE — WHAT THE CUSTOMER WAS ACTUALLY SENT
-- The services stay editable. A quote is a frozen photograph of them,
-- numbered and dated, so what was agreed in March survives whatever is
-- edited in October.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.event_quotes (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  booking_id   uuid NOT NULL,
  quote_no     text,
  revision     text DEFAULT 'A' NOT NULL,
  guests       integer DEFAULT 0 NOT NULL,      -- the count this price was built on
  tables       integer DEFAULT 0 NOT NULL,
  total_price  numeric DEFAULT 0 NOT NULL,
  total_cost   numeric DEFAULT 0 NOT NULL,
  quote_date   date DEFAULT CURRENT_DATE NOT NULL,
  valid_until  date,
  status       text DEFAULT 'sent' NOT NULL,    -- sent | accepted | declined | superseded
  decided_on   date,
  decline_reason text,
  prepared_by  uuid,
  notes        text,
  created_at   timestamp with time zone DEFAULT now(),
  CONSTRAINT event_quotes_pkey PRIMARY KEY (id),
  CONSTRAINT event_quotes_booking_fkey FOREIGN KEY (booking_id)
    REFERENCES public.event_bookings(id) ON DELETE CASCADE,
  CONSTRAINT event_quotes_prepared_fkey FOREIGN KEY (prepared_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT event_quotes_status_check CHECK (status = ANY (ARRAY[
    'sent', 'accepted', 'declined', 'superseded']))
);

CREATE TABLE IF NOT EXISTS public.event_quote_lines (
  id              uuid DEFAULT gen_random_uuid() NOT NULL,
  quote_id        uuid NOT NULL,
  name            text NOT NULL,
  vendor_name     text,
  basis           text,
  quantity        numeric DEFAULT 0,
  unit_price      numeric DEFAULT 0,
  minimum_applied boolean DEFAULT false,
  price           numeric DEFAULT 0,
  cost            numeric DEFAULT 0,
  is_optional     boolean DEFAULT false,
  sort_order      integer DEFAULT 0,
  CONSTRAINT event_quote_lines_pkey PRIMARY KEY (id),
  CONSTRAINT event_quote_lines_quote_fkey FOREIGN KEY (quote_id)
    REFERENCES public.event_quotes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_event_quotes_booking ON public.event_quotes (booking_id);
CREATE INDEX IF NOT EXISTS idx_event_quote_lines_quote ON public.event_quote_lines (quote_id);

-- A photograph that can be retouched is not a photograph.
CREATE OR REPLACE FUNCTION public.event_quote_line_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF coalesce(current_setting('kareya.event_issuing', true), '') <> 'on' THEN
    RAISE EXCEPTION 'A quote line cannot be changed. Issue a new revision instead.';
  END IF;
  RETURN coalesce(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_event_quote_line_frozen ON public.event_quote_lines;
CREATE TRIGGER trg_event_quote_line_frozen
  BEFORE INSERT OR UPDATE OR DELETE ON public.event_quote_lines
  FOR EACH ROW EXECUTE FUNCTION public.event_quote_line_frozen();

-- ---- numbering -------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.event_quote_series (
  id      boolean DEFAULT true NOT NULL,
  prefix  text DEFAULT 'EVQ-',
  width   integer DEFAULT 4,
  period  text,
  last_no bigint DEFAULT 0,
  CONSTRAINT event_quote_series_pkey PRIMARY KEY (id),
  CONSTRAINT event_quote_series_singleton CHECK (id = true)
);
INSERT INTO public.event_quote_series (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.allocate_event_quote_no(p_on date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_s event_quote_series; v_period text; v_no bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('event_quote_series'));
  SELECT * INTO v_s FROM event_quote_series WHERE id;
  IF v_s.id IS NULL THEN INSERT INTO event_quote_series (id) VALUES (true) RETURNING * INTO v_s; END IF;
  v_period := to_char(p_on, 'YYYY');
  IF coalesce(v_s.period, '') <> v_period THEN
    UPDATE event_quote_series SET period = v_period, last_no = 1 WHERE id RETURNING last_no INTO v_no;
  ELSE
    UPDATE event_quote_series SET last_no = last_no + 1 WHERE id RETURNING last_no INTO v_no;
  END IF;
  RETURN coalesce(v_s.prefix, 'EVQ-') || v_period || '-' || lpad(v_no::text, greatest(coalesce(v_s.width, 4), 1), '0');
END;
$$;

-- Freeze the current services into a numbered revision.
CREATE OR REPLACE FUNCTION public.issue_event_quote(
  p_booking_id uuid, p_valid_until date DEFAULT NULL)
 RETURNS event_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_b event_bookings; v_q event_quotes; v_id uuid; v_me uuid;
  v_prev event_quotes; v_rev text; v_no text; v_n integer;
BEGIN
  SELECT * INTO v_b FROM event_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status = 'cancelled' THEN RAISE EXCEPTION 'That event was cancelled'; END IF;

  SELECT count(*) INTO v_n FROM event_services WHERE booking_id = p_booking_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'There is nothing on this event to quote yet.';
  END IF;
  IF coalesce(v_b.guests, 0) <= 0 THEN
    RAISE EXCEPTION 'Set how many guests. On an event priced per head, that number IS the price.';
  END IF;

  -- The revision carries the quote number forward: one reference, several
  -- versions, which is what a customer expects to see.
  SELECT * INTO v_prev FROM event_quotes
   WHERE booking_id = p_booking_id ORDER BY created_at DESC LIMIT 1;
  IF v_prev.id IS NULL THEN
    v_rev := 'A'; v_no := allocate_event_quote_no(coalesce(v_b.event_date, CURRENT_DATE));
  ELSE
    v_rev := chr(ascii(v_prev.revision) + 1); v_no := v_prev.quote_no;
    UPDATE event_quotes SET status = 'superseded'
     WHERE booking_id = p_booking_id AND status = 'sent';
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  INSERT INTO event_quotes (booking_id, quote_no, revision, guests, tables,
                            total_price, total_cost, valid_until, status, prepared_by)
  VALUES (p_booking_id, v_no, v_rev, v_b.guests, event_tables(p_booking_id),
          coalesce(v_b.total_price, 0), coalesce(v_b.total_cost, 0),
          p_valid_until, 'sent', v_me)
  RETURNING id INTO v_id;

  PERFORM set_config('kareya.event_issuing', 'on', true);
  INSERT INTO event_quote_lines (quote_id, name, vendor_name, basis, quantity, unit_price,
                                 minimum_applied, price, cost, is_optional, sort_order)
  SELECT v_id, s.name, v.name, s.basis,
         event_line_quantity(p_booking_id, coalesce(s.basis, 'per_event'), s.quantity),
         s.unit_price, s.minimum_applied, s.price, s.cost, s.is_optional, s.sort_order
    FROM event_services s
    LEFT JOIN event_vendors v ON v.id = s.vendor_id
   WHERE s.booking_id = p_booking_id
   ORDER BY s.sort_order, s.name;
  PERFORM set_config('kareya.event_issuing', 'off', true);

  SELECT * INTO v_q FROM event_quotes WHERE id = v_id;
  RETURN v_q;
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_event_quote(p_quote_id uuid)
 RETURNS event_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_q event_quotes;
BEGIN
  SELECT * INTO v_q FROM event_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status <> 'sent' THEN RAISE EXCEPTION 'This quote is already %', v_q.status; END IF;
  IF v_q.valid_until IS NOT NULL AND v_q.valid_until < CURRENT_DATE THEN
    RAISE EXCEPTION 'This price expired on %. Issue a new revision.', v_q.valid_until;
  END IF;

  UPDATE event_quotes SET status = 'accepted', decided_on = CURRENT_DATE
   WHERE id = p_quote_id RETURNING * INTO v_q;

  UPDATE event_bookings SET status = 'confirmed'
   WHERE id = v_q.booking_id AND status = 'inquiry';
  RETURN v_q;
END;
$$;

CREATE OR REPLACE FUNCTION public.decline_event_quote(p_quote_id uuid, p_reason text)
 RETURNS event_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_q event_quotes;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A declined quote needs a reason. It is the only part worth reading later.';
  END IF;
  SELECT * INTO v_q FROM event_quotes WHERE id = p_quote_id FOR UPDATE;
  IF v_q.id IS NULL THEN RAISE EXCEPTION 'That quote does not exist'; END IF;
  IF v_q.status <> 'sent' THEN RAISE EXCEPTION 'This quote is already %', v_q.status; END IF;

  UPDATE event_quotes SET status = 'declined', decided_on = CURRENT_DATE,
                          decline_reason = p_reason
   WHERE id = p_quote_id RETURNING * INTO v_q;
  RETURN v_q;
END;
$$;

-- What the event is worth, read the way a planner reads it.
DROP FUNCTION IF EXISTS public.event_summary(uuid);
CREATE OR REPLACE FUNCTION public.event_summary(p_booking_id uuid)
 RETURNS TABLE (
   out_guests      integer,
   out_tables      integer,
   out_price       numeric,
   out_cost        numeric,
   out_margin      numeric,
   out_margin_pct  numeric,
   out_per_head    numeric,
   out_optional    numeric,
   out_paid        numeric,
   out_due         numeric
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE v_b event_bookings; v_opt numeric; v_paid numeric;
BEGIN
  SELECT * INTO v_b FROM event_bookings WHERE id = p_booking_id;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;

  SELECT coalesce(sum(price), 0) INTO v_opt
    FROM event_services WHERE booking_id = p_booking_id AND is_optional;
  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM event_payments WHERE booking_id = p_booking_id AND NOT coalesce(voided, false);

  out_guests     := coalesce(v_b.guests, 0);
  out_tables     := event_tables(p_booking_id);
  out_price      := round(coalesce(v_b.total_price, 0), 2);
  out_cost       := round(coalesce(v_b.total_cost, 0), 2);
  out_margin     := round(coalesce(v_b.total_price, 0) - coalesce(v_b.total_cost, 0), 2);
  out_margin_pct := CASE WHEN coalesce(v_b.total_price, 0) = 0 THEN 0
                         ELSE round(100 * (v_b.total_price - v_b.total_cost) / v_b.total_price, 2) END;
  -- The figure a customer asks for first, and the one a lump sum hides.
  out_per_head   := CASE WHEN coalesce(v_b.guests, 0) = 0 THEN 0
                         ELSE round(coalesce(v_b.total_price, 0) / v_b.guests, 2) END;
  out_optional   := round(v_opt, 2);
  out_paid       := round(v_paid, 2);
  out_due        := round(greatest(coalesce(v_b.total_price, 0) - v_paid, 0), 2);
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. MONEY IN STAGES
-- An event is booked months ahead and paid in instalments, so what is due
-- and when is part of the deal rather than something to remember.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.event_payment_schedule (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  booking_id  uuid NOT NULL,
  label       text NOT NULL,                  -- 'Deposit', 'Second instalment', 'Balance'
  due_on      date,
  amount      numeric,                        -- either a figure...
  percent     numeric,                        -- ...or a share of the total
  sort_order  integer DEFAULT 0,
  CONSTRAINT event_payment_schedule_pkey PRIMARY KEY (id),
  CONSTRAINT event_payment_schedule_booking_fkey FOREIGN KEY (booking_id)
    REFERENCES public.event_bookings(id) ON DELETE CASCADE,
  -- One or the other. Both would be two answers to one question.
  CONSTRAINT event_payment_schedule_amount_check
    CHECK ((amount IS NOT NULL AND percent IS NULL) OR (amount IS NULL AND percent IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_event_payment_schedule_booking ON public.event_payment_schedule (booking_id);

DROP FUNCTION IF EXISTS public.event_schedule_due(uuid);
CREATE OR REPLACE FUNCTION public.event_schedule_due(p_booking_id uuid)
 RETURNS TABLE (
   out_label   text,
   out_due_on  date,
   out_amount  numeric,
   out_overdue boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT s.label, s.due_on,
         round(coalesce(s.amount, coalesce(b.total_price, 0) * s.percent / 100.0), 2),
         s.due_on IS NOT NULL AND s.due_on < CURRENT_DATE
           AND coalesce((SELECT sum(p.amount) FROM event_payments p
                          WHERE p.booking_id = p_booking_id AND NOT coalesce(p.voided, false)), 0)
               < (SELECT coalesce(sum(round(coalesce(s2.amount,
                                      coalesce(b.total_price, 0) * s2.percent / 100.0), 2)), 0)
                    FROM event_payment_schedule s2
                   WHERE s2.booking_id = p_booking_id
                     AND s2.due_on IS NOT NULL AND s2.due_on <= s.due_on)
    FROM event_payment_schedule s
    JOIN event_bookings b ON b.id = s.booking_id
   WHERE s.booking_id = p_booking_id
   ORDER BY s.sort_order, s.due_on NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION public.event_payment_is_a_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A payment cannot be deleted. Void it, which leaves the record and the reason.';
  END IF;
  IF OLD.amount IS DISTINCT FROM NEW.amount OR OLD.date IS DISTINCT FROM NEW.date
     OR OLD.booking_id IS DISTINCT FROM NEW.booking_id THEN
    RAISE EXCEPTION 'A payment cannot be rewritten. Void it and take a new one.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_event_payment_is_a_record ON public.event_payments;
CREATE TRIGGER trg_event_payment_is_a_record
  BEFORE UPDATE OR DELETE ON public.event_payments
  FOR EACH ROW EXECUTE FUNCTION public.event_payment_is_a_record();

CREATE OR REPLACE FUNCTION public.record_event_payment(
  p_booking_id uuid, p_amount numeric, p_type text DEFAULT 'deposit',
  p_method text DEFAULT 'cash', p_reference text DEFAULT NULL,
  p_on date DEFAULT CURRENT_DATE)
 RETURNS event_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b event_bookings; v_paid numeric; v_p event_payments; v_me uuid;
BEGIN
  SELECT * INTO v_b FROM event_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF coalesce(p_amount, 0) = 0 THEN RAISE EXCEPTION 'A payment has to be an amount'; END IF;

  SELECT coalesce(sum(amount), 0) INTO v_paid
    FROM event_payments WHERE booking_id = p_booking_id AND NOT coalesce(voided, false);

  IF p_amount > 0 AND v_paid + p_amount > coalesce(v_b.total_price, 0) + 0.005 THEN
    RAISE EXCEPTION 'That is % more than the event is for. Taken so far: % of %.',
      round(v_paid + p_amount - coalesce(v_b.total_price, 0), 2),
      round(v_paid, 2), round(coalesce(v_b.total_price, 0), 2);
  END IF;
  IF p_amount < 0 AND v_paid + p_amount < -0.005 THEN
    RAISE EXCEPTION 'That would refund more than was ever taken. Taken so far: %.', round(v_paid, 2);
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  INSERT INTO event_payments (booking_id, date, amount,
                              type, method, reference, received_by)
  VALUES (p_booking_id, coalesce(p_on, CURRENT_DATE), p_amount,
          CASE WHEN p_amount < 0 THEN 'refund' ELSE coalesce(p_type, 'deposit') END,
          coalesce(p_method, 'cash'), p_reference, v_me)
  RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_event_payment(p_payment_id uuid, p_reason text)
 RETURNS event_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_p event_payments;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a payment needs a reason. It stays on the record.';
  END IF;
  SELECT * INTO v_p FROM event_payments WHERE id = p_payment_id FOR UPDATE;
  IF v_p.id IS NULL THEN RAISE EXCEPTION 'That payment does not exist'; END IF;
  IF coalesce(v_p.voided, false) THEN RAISE EXCEPTION 'That payment was already voided'; END IF;

  UPDATE event_payments SET voided = true, void_reason = p_reason
   WHERE id = p_payment_id RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_event_booking(p_booking_id uuid, p_reason text)
 RETURNS event_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b event_bookings;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A cancellation needs a reason.';
  END IF;
  SELECT * INTO v_b FROM event_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status = 'cancelled' THEN RAISE EXCEPTION 'That event was already cancelled'; END IF;

  -- Kareya holds no cancellation scale: how much of a deposit is kept when
  -- a wedding is called off is a term of the contract, not of the software.
  UPDATE event_bookings
     SET status = 'cancelled', cancelled_at = now(), cancellation_reason = p_reason
   WHERE id = p_booking_id RETURNING * INTO v_b;
  RETURN v_b;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Priced per head with no head count. The defect this vertical exists
  -- to stop, seen from the other end.
  SELECT 'event', b.id, b.event_name,
         'Has per-head or per-table charges but no guest count, so those lines price at nothing.'
    FROM event_bookings b
   WHERE coalesce(b.guests, 0) = 0 AND b.status <> 'cancelled'
     AND EXISTS (SELECT 1 FROM event_services s
                  WHERE s.booking_id = b.id AND s.basis IN ('per_guest', 'per_table'))

  UNION ALL
  -- The guest count moved after the customer was quoted.
  SELECT 'event', b.id, b.event_name,
         'Quoted at ' || q.guests::text || ' guests but the booking now says '
         || coalesce(b.guests, 0)::text || '. Issue a new revision.'
    FROM event_bookings b
    JOIN event_quotes q ON q.booking_id = b.id AND q.status = 'accepted'
   WHERE coalesce(b.guests, 0) <> q.guests

  UNION ALL
  -- Sold below what the vendors charge.
  SELECT 'event', b.id, b.event_name,
         'Sells at ' || round(coalesce(b.total_price, 0), 2)::text
         || ' against vendor costs of ' || round(coalesce(b.total_cost, 0), 2)::text || '.'
    FROM event_bookings b
   WHERE b.status <> 'cancelled' AND coalesce(b.total_price, 0) > 0
     AND coalesce(b.total_price, 0) < coalesce(b.total_cost, 0)

  UNION ALL
  -- A line whose vendor was never named.
  SELECT 'event', b.id, b.event_name,
         'Service "' || s.name || '" carries a cost with no vendor against it.'
    FROM event_services s JOIN event_bookings b ON b.id = s.booking_id
   WHERE coalesce(s.cost, 0) > 0 AND s.vendor_id IS NULL AND b.status <> 'cancelled'

  UNION ALL
  -- An instalment that has come and gone.
  SELECT 'event', b.id, b.event_name,
         'Instalment "' || d.out_label || '" was due on ' || d.out_due_on::text || ' and is short.'
    FROM event_bookings b
    CROSS JOIN LATERAL event_schedule_due(b.id) d
   WHERE b.status NOT IN ('cancelled', 'completed') AND d.out_overdue

  UNION ALL
  -- The day arrives and the money has not.
  SELECT 'event', b.id, b.event_name,
         'Runs on ' || b.event_date::text || ' with ' || sum.out_due::text || ' still uncollected.'
    FROM event_bookings b
    CROSS JOIN LATERAL event_summary(b.id) sum
   WHERE b.status NOT IN ('cancelled', 'completed')
     AND b.event_date IS NOT NULL AND b.event_date <= CURRENT_DATE + 7
     AND sum.out_due > 0.005

  UNION ALL
  -- Money left on a cancelled event.
  SELECT 'event', b.id, b.event_name,
         'Cancelled with ' || sum.out_paid::text || ' taken and nothing refunded.'
    FROM event_bookings b
    CROSS JOIN LATERAL event_summary(b.id) sum
   WHERE b.status = 'cancelled' AND sum.out_paid > 0.005

  UNION ALL
  -- Confirmed on nothing anybody signed.
  SELECT 'event', b.id, b.event_name,
         'Confirmed with no accepted quote behind it.'
    FROM event_bookings b
   WHERE b.status IN ('confirmed', 'in_progress')
     AND NOT EXISTS (SELECT 1 FROM event_quotes q
                      WHERE q.booking_id = b.id AND q.status = 'accepted');
$$;

GRANT EXECUTE ON FUNCTION public.event_tables(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_line_quantity(uuid, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reprice_event(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_event_quote_no(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_event_quote(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_event_quote(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_event_quote(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_summary(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_schedule_due(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_event_payment(uuid, numeric, text, text, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_event_payment(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_event_booking(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.event_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- Vendor costs are what the planner pays, and the customer must not see
-- them. Same roles as the rest of events.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['event_quotes', 'event_quote_lines', 'event_payment_schedule']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                      USING (public.has_any_role(ARRAY['Event Planner','Cashier','Accountant','Manager']))$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Event Planner','Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Event Planner','Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
