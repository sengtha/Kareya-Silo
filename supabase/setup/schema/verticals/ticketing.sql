-- =====================================================================
-- KAREYA SILO — TICKETING: OCCURRENCES, SEATS, TICKETS, ADMISSION
-- ---------------------------------------------------------------------
-- Kareya had three tables with "ticket" in the name and none of them let
-- anybody through a door. `tickets` is the helpdesk. `pawn_tickets` is a
-- pawn contract. `opd_queue_tickets` is a hospital queue number.
--
-- The closest thing that existed was book_tour_seats(), which sells
-- against a capacity under FOR UPDATE — so the concurrency lesson was
-- already learned. But it books PAX, a headcount. There is no seat 14B,
-- no code, and nothing to present at a gate.
--
-- A bus ticket, a cinema ticket, a concert ticket and a theme park pass
-- look like four problems and are one: A FINITE INVENTORY OF ADMISSIONS,
-- SOLD, ISSUED AS A CODE, AND CONSUMED ONCE AT A GATE.
--
--   bus       product = the route     occurrence = the departure   seats
--   cinema    product = the film      occurrence = the showtime    seats
--   concert   product = the show      occurrence = the night       zones
--   park      product = the pass      occurrence = a WINDOW        neither
--
-- SIX DECISIONS THIS FILE EXISTS TO ENFORCE:
--
-- 1. ONE SEAT, ONE TICKET. A partial unique index, not a check in the
--    app. Two phones buying 14B in the same second is not a rare case;
--    it is what happens as a coach fills.
--
-- 2. CAPACITY CANNOT BE OVERSOLD, per class AND per occurrence. Those are
--    two different faults: a full coach and a full sleeper section.
--
-- 3. A TICKET IS ADMITTED ONCE. This is the defining rule of ticketing,
--    and the whole reason a gate needs a computer at all.
--
-- 4. A REFUSED SCAN IS RECORDED. A second scan is either a duplicate
--    print or a ticket passed back over a fence, and neither is visible
--    if only the successful scans are kept. The gate is told WHICH:
--    "already admitted 19:42 at gate B" ends an argument; "invalid"
--    starts one.
--
-- 5. A HELD SEAT THAT IS NOT PAID FOR EXPIRES. Otherwise abandoned carts
--    lock the inventory — the same defect as a meeting room held all
--    afternoon by a meeting nobody attended.
--
-- 6. A CODE IS UNGUESSABLE. Sequential ticket numbers get printed at
--    home. Codes come from gen_random_bytes, not from a counter, and the
--    alphabet drops the characters people misread aloud over a phone.
--
-- ON OFFLINE SCANNING, STATED RATHER THAN GLOSSED. A bus terminal or a
-- park gate with no signal is the normal case here, and this is an online
-- check: admit_ticket() needs the database. The code is deliberately long
-- enough to carry a signature later, but NOTHING HERE VALIDATES OFFLINE
-- and it must not be described as if it does.
--
-- NO FARES, NO SEAT MAPS, NO SHOWTIMES SHIP. A default fare would quietly
-- become somebody's pricing.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.has_any_role(text[]).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHAT CAN BE SOLD
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ticketed_products (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  code          text,
  name          text NOT NULL,
  name_kh       text,
  kind          text DEFAULT 'other' NOT NULL,
  -- transport  — a route
  -- screening  — a film
  -- performance— a show
  -- attraction — a park, a museum, an exhibition
  venue         text,
  description   text,

  -- Whether a buyer picks a seat. A coach and a cinema yes; a standing
  -- concert and a park gate no.
  reserved_seating boolean DEFAULT false,

  -- How long before the start the gate begins admitting. Every venue has
  -- this and calls it "doors open"; a bus calls it boarding. It defaults
  -- to 0 rather than to a guess, because a gate that opens an hour early
  -- is a policy and this file does not have one — but leaving it at 0
  -- means nobody can be scanned in until the second of departure, which
  -- is why the reconciliation says so.
  doors_open_minutes integer DEFAULT 0 NOT NULL,

  -- How many times ONE ticket may be admitted. 1 for a bus or a film.
  -- More for a park pass that allows re-entry; NULL for unlimited within
  -- the occurrence's window, which is what a season pass means.
  max_admissions integer DEFAULT 1,

  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT ticketed_products_pkey PRIMARY KEY (id),
  CONSTRAINT ticketed_products_kind_check CHECK (kind = ANY (ARRAY[
    'transport', 'screening', 'performance', 'attraction', 'other'])),
  CONSTRAINT ticketed_products_admissions_check
    CHECK (max_admissions IS NULL OR max_admissions >= 1),
  CONSTRAINT ticketed_products_doors_check CHECK (doors_open_minutes >= 0)
);

COMMENT ON TABLE public.ticketed_products IS
  'A route, a film, a show or a pass. The thing an occurrence is an occurrence OF.';

CREATE INDEX IF NOT EXISTS idx_ticketed_products_active
  ON public.ticketed_products (is_active, kind);

-- ---------------------------------------------------------------------
-- 2. WHEN
-- A departure, a showtime, a performance — or, for a pass, a WINDOW. The
-- park case is why validity is a range rather than a moment: a two-day
-- pass is not two tickets and is not one moment.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ticket_occurrences (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  product_id    uuid NOT NULL,
  label         text,                          -- 'PP–SR 07:30', 'Screen 2'
  starts_at     timestamp with time zone NOT NULL,
  ends_at       timestamp with time zone,

  -- When a ticket may actually be USED. Usually the same as the
  -- occurrence; a park pass is valid all day whatever time it was bought.
  valid_from    timestamp with time zone,
  valid_until   timestamp with time zone,

  -- The hard ceiling — the coach, the screen, the room. Classes may
  -- divide it but may not exceed it.
  capacity      integer DEFAULT 0 NOT NULL,

  sales_open_at  timestamp with time zone,
  sales_close_at timestamp with time zone,

  location      text,                          -- platform, screen, gate
  status        text DEFAULT 'on_sale' NOT NULL,
  -- scheduled | on_sale | closed | departed | cancelled
  cancel_reason text,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT ticket_occurrences_pkey PRIMARY KEY (id),
  CONSTRAINT ticket_occurrences_product_fkey FOREIGN KEY (product_id)
    REFERENCES public.ticketed_products(id) ON DELETE CASCADE,
  CONSTRAINT ticket_occurrences_capacity_check CHECK (capacity >= 0),
  CONSTRAINT ticket_occurrences_period_check
    CHECK (ends_at IS NULL OR ends_at >= starts_at),
  CONSTRAINT ticket_occurrences_validity_check
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from),
  CONSTRAINT ticket_occurrences_sales_check
    CHECK (sales_close_at IS NULL OR sales_open_at IS NULL OR sales_close_at >= sales_open_at),
  CONSTRAINT ticket_occurrences_status_check CHECK (status = ANY (ARRAY[
    'scheduled', 'on_sale', 'closed', 'departed', 'cancelled']))
);

CREATE INDEX IF NOT EXISTS idx_ticket_occurrences_product
  ON public.ticket_occurrences (product_id, starts_at);
CREATE INDEX IF NOT EXISTS idx_ticket_occurrences_when
  ON public.ticket_occurrences (starts_at);

/** Validity defaults to the occurrence itself. A ticket for the 07:30 is
 *  valid for the 07:30 unless somebody says otherwise, and leaving it
 *  NULL would make every ticket valid forever. */
CREATE OR REPLACE FUNCTION public.ticket_occurrence_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_doors integer;
BEGIN
  SELECT coalesce(doors_open_minutes, 0) INTO v_doors
    FROM ticketed_products WHERE id = NEW.product_id;

  -- Boarding starts before departure and doors open before the film. A
  -- ticket valid only from the exact starting second cannot be scanned
  -- while people are still walking in, which is when it is scanned.
  IF NEW.valid_from IS NULL THEN
    NEW.valid_from := NEW.starts_at - make_interval(mins => coalesce(v_doors, 0));
  END IF;
  IF NEW.valid_until IS NULL THEN
    NEW.valid_until := coalesce(NEW.ends_at, NEW.starts_at + interval '1 day');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ticket_occurrence_defaults ON public.ticket_occurrences;
CREATE TRIGGER trg_ticket_occurrence_defaults
  BEFORE INSERT OR UPDATE ON public.ticket_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.ticket_occurrence_defaults();

-- ---------------------------------------------------------------------
-- 3. CLASSES
-- Sleeper and seater. Stalls and circle. VIP and general admission.
-- Adult and child. Each carries its own price and its own share of the
-- capacity, because "the coach is full" and "the sleeper section is full"
-- are different sentences.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ticket_classes (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  occurrence_id uuid NOT NULL,
  name          text NOT NULL,
  name_kh       text,
  capacity      integer,                       -- NULL = share the occurrence's
  price         numeric DEFAULT 0 NOT NULL,
  sort_order    integer DEFAULT 0 NOT NULL,
  is_active     boolean DEFAULT true,
  CONSTRAINT ticket_classes_pkey PRIMARY KEY (id),
  CONSTRAINT ticket_classes_occurrence_fkey FOREIGN KEY (occurrence_id)
    REFERENCES public.ticket_occurrences(id) ON DELETE CASCADE,
  CONSTRAINT ticket_classes_capacity_check CHECK (capacity IS NULL OR capacity >= 0),
  CONSTRAINT ticket_classes_price_check CHECK (price >= 0),
  CONSTRAINT uq_ticket_class_name UNIQUE (occurrence_id, name)
);

CREATE INDEX IF NOT EXISTS idx_ticket_classes_occurrence
  ON public.ticket_classes (occurrence_id, sort_order);

/** Classes divide the capacity; they cannot invent more of it. Selling
 *  forty sleepers on a thirty-seat coach is caught here rather than at
 *  the roadside. */
CREATE OR REPLACE FUNCTION public.ticket_class_capacity_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_cap integer; v_sum integer;
BEGIN
  SELECT capacity INTO v_cap FROM ticket_occurrences WHERE id = NEW.occurrence_id;
  SELECT coalesce(sum(capacity), 0) INTO v_sum
    FROM ticket_classes
   WHERE occurrence_id = NEW.occurrence_id AND id <> NEW.id AND capacity IS NOT NULL;

  IF NEW.capacity IS NOT NULL AND v_cap > 0 AND v_sum + NEW.capacity > v_cap THEN
    RAISE EXCEPTION 'The classes add up to % but there are only % places.',
      v_sum + NEW.capacity, v_cap;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ticket_class_capacity ON public.ticket_classes;
CREATE TRIGGER trg_ticket_class_capacity
  BEFORE INSERT OR UPDATE ON public.ticket_classes
  FOR EACH ROW EXECUTE FUNCTION public.ticket_class_capacity_check();

-- ---------------------------------------------------------------------
-- 4. SEATS
-- Only where they are reserved. A concert field and a park gate have
-- none, and inventing them would make every sale ask a question nobody
-- has an answer to.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ticket_seats (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  occurrence_id uuid NOT NULL,
  class_id      uuid,
  label         text NOT NULL,                 -- '14B'
  row_label     text,
  seat_no       integer,
  -- A broken seat, a seat held for a wheelchair, a seat over the wheel
  -- arch nobody wants to sell. Blocked is not sold; it is unavailable.
  is_blocked    boolean DEFAULT false,
  block_reason  text,
  sort_order    integer DEFAULT 0 NOT NULL,
  CONSTRAINT ticket_seats_pkey PRIMARY KEY (id),
  CONSTRAINT ticket_seats_occurrence_fkey FOREIGN KEY (occurrence_id)
    REFERENCES public.ticket_occurrences(id) ON DELETE CASCADE,
  CONSTRAINT ticket_seats_class_fkey FOREIGN KEY (class_id)
    REFERENCES public.ticket_classes(id) ON DELETE SET NULL,
  CONSTRAINT ticket_seats_block_check
    CHECK (NOT is_blocked OR coalesce(btrim(block_reason), '') <> ''),
  CONSTRAINT uq_ticket_seat_label UNIQUE (occurrence_id, label)
);

CREATE INDEX IF NOT EXISTS idx_ticket_seats_occurrence
  ON public.ticket_seats (occurrence_id, sort_order);

-- ---------------------------------------------------------------------
-- 5. THE TICKET
-- ---------------------------------------------------------------------
/** An unguessable code.
 *
 *  Not a sequence. A ticket numbered 000418 tells the person holding it
 *  exactly what 000419 will be, and they will print it. Eight random
 *  bytes, rendered in an alphabet with no 0/O and no 1/I/L, because these
 *  get read out over a phone by somebody at a bus station. */
CREATE OR REPLACE FUNCTION public.new_ticket_code()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE
  v_alpha text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';   -- 31 characters
  v_out text := '';
  v_bytes bytea;
  i integer;
BEGIN
  LOOP
    v_out := '';
    v_bytes := gen_random_bytes(12);
    FOR i IN 0..11 LOOP
      v_out := v_out || substr(v_alpha, (get_byte(v_bytes, i) % 31) + 1, 1);
    END LOOP;
    -- Grouped for reading aloud.
    v_out := substr(v_out, 1, 4) || '-' || substr(v_out, 5, 4) || '-' || substr(v_out, 9, 4);
    -- tickets_issued, NOT tickets — that name is the helpdesk's.
    EXIT WHEN NOT EXISTS (SELECT 1 FROM tickets_issued WHERE code = v_out);
  END LOOP;
  RETURN v_out;
END;
$$;

CREATE TABLE IF NOT EXISTS public.tickets_issued (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  occurrence_id uuid NOT NULL,
  class_id      uuid,
  seat_id       uuid,
  code          text NOT NULL,

  holder_name   text,
  holder_phone  text,
  holder_doc    text,                          -- ID or passport, for a manifest

  price         numeric DEFAULT 0 NOT NULL,
  status        text DEFAULT 'held' NOT NULL,
  -- held      — in somebody's basket, and it expires
  -- issued    — paid for and printed
  -- admitted  — has been through the gate at least once
  -- void      — cancelled, with a reason; never deleted
  -- refunded  — money back; the seat goes back on sale
  -- expired   — the hold ran out

  -- A hold that nobody pays for must not lock a seat forever.
  held_until    timestamp with time zone,

  admissions_used integer DEFAULT 0 NOT NULL,
  first_admitted_at timestamp with time zone,
  last_admitted_at  timestamp with time zone,

  -- Whatever the money ended up on: a POS sale, an invoice, a booking.
  sale_ref      text,
  issued_at     timestamp with time zone,
  issued_by     uuid,
  void_reason   text,
  refunded_amount numeric,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT tickets_issued_pkey PRIMARY KEY (id),
  CONSTRAINT tickets_issued_occurrence_fkey FOREIGN KEY (occurrence_id)
    REFERENCES public.ticket_occurrences(id) ON DELETE CASCADE,
  CONSTRAINT tickets_issued_class_fkey FOREIGN KEY (class_id)
    REFERENCES public.ticket_classes(id) ON DELETE SET NULL,
  CONSTRAINT tickets_issued_seat_fkey FOREIGN KEY (seat_id)
    REFERENCES public.ticket_seats(id) ON DELETE SET NULL,
  CONSTRAINT tickets_issued_issued_by_fkey FOREIGN KEY (issued_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT tickets_issued_code_key UNIQUE (code),
  CONSTRAINT tickets_issued_price_check CHECK (price >= 0),
  CONSTRAINT tickets_issued_used_check CHECK (admissions_used >= 0),
  CONSTRAINT tickets_issued_status_check CHECK (status = ANY (ARRAY[
    'held', 'issued', 'admitted', 'void', 'refunded', 'expired'])),
  -- A void with no reason is not an audit trail.
  CONSTRAINT tickets_issued_void_check
    CHECK (status <> 'void' OR coalesce(btrim(void_reason), '') <> ''),
  CONSTRAINT tickets_issued_hold_check
    CHECK (status <> 'held' OR held_until IS NOT NULL)
);

COMMENT ON TABLE public.tickets_issued IS
  'An admission. NOT public.tickets, which is the helpdesk — the name was already taken.';

CREATE INDEX IF NOT EXISTS idx_tickets_issued_occurrence
  ON public.tickets_issued (occurrence_id, status);
CREATE INDEX IF NOT EXISTS idx_tickets_issued_holds
  ON public.tickets_issued (held_until) WHERE status = 'held';

/** ONE SEAT, ONE TICKET.
 *
 *  A partial unique index, so the database refuses it rather than the
 *  screen. Void, refunded and expired tickets are excluded, which is
 *  exactly what makes a refund put the seat back on sale. */
CREATE UNIQUE INDEX IF NOT EXISTS uq_ticket_seat_live
  ON public.tickets_issued (seat_id)
  WHERE seat_id IS NOT NULL AND status IN ('held', 'issued', 'admitted');

-- ---------------------------------------------------------------------
-- 6. EVERY SCAN, INCLUDING THE ONES THAT WERE TURNED AWAY
-- A log of successful admissions alone cannot show a ticket being passed
-- back over a fence. The refusals ARE the signal.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ticket_admissions (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  ticket_id    uuid,                           -- NULL when the code was not found
  code_tried   text,
  occurrence_id uuid,
  admitted_at  timestamp with time zone DEFAULT now() NOT NULL,
  gate         text,
  admitted_by  uuid,
  result       text NOT NULL,
  -- admitted | duplicate | too_early | too_late | void | cancelled
  -- | not_found | wrong_occurrence | exhausted
  note         text,
  CONSTRAINT ticket_admissions_pkey PRIMARY KEY (id),
  CONSTRAINT ticket_admissions_ticket_fkey FOREIGN KEY (ticket_id)
    REFERENCES public.tickets_issued(id) ON DELETE SET NULL,
  CONSTRAINT ticket_admissions_by_fkey FOREIGN KEY (admitted_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT ticket_admissions_result_check CHECK (result = ANY (ARRAY[
    'admitted', 'duplicate', 'too_early', 'too_late', 'void', 'cancelled',
    'not_found', 'wrong_occurrence', 'exhausted']))
);

CREATE INDEX IF NOT EXISTS idx_ticket_admissions_ticket
  ON public.ticket_admissions (ticket_id, admitted_at);
CREATE INDEX IF NOT EXISTS idx_ticket_admissions_when
  ON public.ticket_admissions (admitted_at);

/** The log is a record of what happened at a gate. It is not editable. */
CREATE OR REPLACE FUNCTION public.ticket_admissions_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'A scan is what happened at the gate. It cannot be % afterwards.',
    CASE WHEN TG_OP = 'DELETE' THEN 'deleted' ELSE 'changed' END;
END;
$$;

DROP TRIGGER IF EXISTS trg_ticket_admissions_append_only ON public.ticket_admissions;
CREATE TRIGGER trg_ticket_admissions_append_only
  BEFORE UPDATE OR DELETE ON public.ticket_admissions
  FOR EACH ROW EXECUTE FUNCTION public.ticket_admissions_append_only();

-- ---------------------------------------------------------------------
-- 7. WHAT IS LEFT
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.occurrence_availability(uuid);
CREATE OR REPLACE FUNCTION public.occurrence_availability(p_occurrence uuid)
 RETURNS TABLE (
   out_class_id uuid,
   out_class    text,
   out_price    numeric,
   out_capacity integer,
   out_sold     bigint,
   out_held     bigint,
   out_free     integer
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  WITH occ AS (SELECT capacity FROM ticket_occurrences WHERE id = p_occurrence),
  live AS (
    SELECT class_id,
           count(*) FILTER (WHERE status IN ('issued', 'admitted')) AS sold,
           count(*) FILTER (WHERE status = 'held' AND held_until > now()) AS held
      FROM tickets_issued
     WHERE occurrence_id = p_occurrence
     GROUP BY class_id)
  SELECT c.id, c.name, c.price,
         coalesce(c.capacity, (SELECT capacity FROM occ)),
         coalesce(l.sold, 0), coalesce(l.held, 0),
         greatest(coalesce(c.capacity, (SELECT capacity FROM occ))
                  - coalesce(l.sold, 0)::integer - coalesce(l.held, 0)::integer, 0)
    FROM ticket_classes c
    LEFT JOIN live l ON l.class_id = c.id
   WHERE c.occurrence_id = p_occurrence AND c.is_active
   ORDER BY c.sort_order, c.name;
$$;

/** The seat map as a screen needs it: every seat, and whether it can be
 *  had. A blocked seat and a sold seat are different answers. */
DROP FUNCTION IF EXISTS public.seat_map(uuid);
CREATE OR REPLACE FUNCTION public.seat_map(p_occurrence uuid)
 RETURNS TABLE (
   out_seat_id  uuid,
   out_label    text,
   out_row      text,
   out_class_id uuid,
   out_class    text,
   out_price    numeric,
   out_state    text,        -- free | held | sold | admitted | blocked
   out_holder   text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT s.id, s.label, s.row_label, s.class_id, c.name, c.price,
         CASE
           WHEN s.is_blocked THEN 'blocked'
           WHEN t.status = 'admitted' THEN 'admitted'
           WHEN t.status = 'issued' THEN 'sold'
           WHEN t.status = 'held' AND t.held_until > now() THEN 'held'
           ELSE 'free'
         END,
         t.holder_name
    FROM ticket_seats s
    LEFT JOIN ticket_classes c ON c.id = s.class_id
    LEFT JOIN tickets_issued t
           ON t.seat_id = s.id
          AND t.status IN ('held', 'issued', 'admitted')
   WHERE s.occurrence_id = p_occurrence
   ORDER BY s.sort_order, s.row_label NULLS FIRST, s.seat_no NULLS FIRST, s.label;
$$;

-- ---------------------------------------------------------------------
-- 8. SELLING
-- ---------------------------------------------------------------------
/** Put tickets aside while somebody pays.
 *
 *  The occurrence row is locked, so two tills counting the same last two
 *  seats cannot both win. Naming a seat takes that seat; not naming one
 *  takes a place in the class, which is what general admission is. */
DROP FUNCTION IF EXISTS public.hold_tickets(uuid, uuid, integer, uuid[], integer);
CREATE OR REPLACE FUNCTION public.hold_tickets(
  p_occurrence uuid,
  p_class      uuid,
  p_quantity   integer DEFAULT 1,
  p_seats      uuid[] DEFAULT NULL,
  p_minutes    integer DEFAULT 10)
 RETURNS SETOF tickets_issued
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_o ticket_occurrences; v_c ticket_classes; v_p ticketed_products;
  v_free integer; v_want integer; v_seat uuid; v_t tickets_issued; i integer;
BEGIN
  -- The lock is the whole point of doing this here.
  SELECT * INTO v_o FROM ticket_occurrences WHERE id = p_occurrence FOR UPDATE;
  IF v_o.id IS NULL THEN RAISE EXCEPTION 'That departure does not exist'; END IF;
  SELECT * INTO v_p FROM ticketed_products WHERE id = v_o.product_id;

  IF v_o.status = 'cancelled' THEN
    RAISE EXCEPTION '% was cancelled: %', coalesce(v_o.label, v_p.name),
      coalesce(v_o.cancel_reason, 'no reason recorded');
  END IF;
  IF v_o.status <> 'on_sale' THEN
    RAISE EXCEPTION '% is not on sale.', coalesce(v_o.label, v_p.name);
  END IF;
  IF v_o.sales_open_at IS NOT NULL AND now() < v_o.sales_open_at THEN
    RAISE EXCEPTION 'Sales for % open %.', coalesce(v_o.label, v_p.name),
      to_char(v_o.sales_open_at, 'DD Mon HH24:MI');
  END IF;
  IF v_o.sales_close_at IS NOT NULL AND now() > v_o.sales_close_at THEN
    RAISE EXCEPTION 'Sales for % closed %.', coalesce(v_o.label, v_p.name),
      to_char(v_o.sales_close_at, 'DD Mon HH24:MI');
  END IF;

  SELECT * INTO v_c FROM ticket_classes WHERE id = p_class AND occurrence_id = p_occurrence;
  IF v_c.id IS NULL THEN RAISE EXCEPTION 'That is not a class on this departure'; END IF;

  v_want := CASE WHEN p_seats IS NOT NULL AND array_length(p_seats, 1) > 0
                 THEN array_length(p_seats, 1) ELSE greatest(coalesce(p_quantity, 1), 1) END;

  -- Two ceilings, two different sentences.
  SELECT out_free INTO v_free FROM occurrence_availability(p_occurrence)
   WHERE out_class_id = p_class;
  IF coalesce(v_free, 0) < v_want THEN
    RAISE EXCEPTION 'Only % left in %.', coalesce(v_free, 0), v_c.name;
  END IF;

  IF v_o.capacity > 0 THEN
    IF (SELECT count(*) FROM tickets_issued
         WHERE occurrence_id = p_occurrence
           AND (status IN ('issued', 'admitted')
                OR (status = 'held' AND held_until > now()))) + v_want > v_o.capacity THEN
      RAISE EXCEPTION 'Only % places left altogether.',
        v_o.capacity - (SELECT count(*) FROM tickets_issued
                         WHERE occurrence_id = p_occurrence
                           AND (status IN ('issued', 'admitted')
                                OR (status = 'held' AND held_until > now())));
    END IF;
  END IF;

  IF p_seats IS NOT NULL AND array_length(p_seats, 1) > 0 THEN
    FOREACH v_seat IN ARRAY p_seats LOOP
      IF EXISTS (SELECT 1 FROM ticket_seats WHERE id = v_seat AND is_blocked) THEN
        RAISE EXCEPTION 'Seat % is not available: %',
          (SELECT label FROM ticket_seats WHERE id = v_seat),
          (SELECT coalesce(block_reason, 'blocked') FROM ticket_seats WHERE id = v_seat);
      END IF;
      BEGIN
        INSERT INTO tickets_issued (occurrence_id, class_id, seat_id, code, price,
                                    status, held_until)
        VALUES (p_occurrence, p_class, v_seat, new_ticket_code(), v_c.price,
                'held', now() + make_interval(mins => greatest(coalesce(p_minutes, 10), 1)))
        RETURNING * INTO v_t;
      EXCEPTION WHEN unique_violation THEN
        -- The index is what actually stopped it; this is only so the
        -- person at the till reads something they understand.
        RAISE EXCEPTION 'Seat % has just gone.',
          (SELECT label FROM ticket_seats WHERE id = v_seat);
      END;
      RETURN NEXT v_t;
    END LOOP;
  ELSE
    IF v_p.reserved_seating AND EXISTS (SELECT 1 FROM ticket_seats WHERE occurrence_id = p_occurrence) THEN
      RAISE EXCEPTION '% is reserved seating, so a seat has to be chosen.', v_p.name;
    END IF;
    FOR i IN 1..v_want LOOP
      INSERT INTO tickets_issued (occurrence_id, class_id, code, price, status, held_until)
      VALUES (p_occurrence, p_class, new_ticket_code(), v_c.price,
              'held', now() + make_interval(mins => greatest(coalesce(p_minutes, 10), 1)))
      RETURNING * INTO v_t;
      RETURN NEXT v_t;
    END LOOP;
  END IF;
END;
$$;

/** Money taken. The hold becomes a ticket. */
CREATE OR REPLACE FUNCTION public.issue_ticket(
  p_ticket uuid,
  p_holder_name text DEFAULT NULL,
  p_holder_phone text DEFAULT NULL,
  p_holder_doc text DEFAULT NULL,
  p_price numeric DEFAULT NULL,
  p_sale_ref text DEFAULT NULL)
 RETURNS tickets_issued
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_t tickets_issued; v_me uuid;
BEGIN
  SELECT * INTO v_t FROM tickets_issued WHERE id = p_ticket FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'That ticket does not exist'; END IF;
  IF v_t.status = 'issued' THEN RAISE EXCEPTION 'That ticket has already been issued'; END IF;
  IF v_t.status <> 'held' THEN RAISE EXCEPTION 'That ticket is %', v_t.status; END IF;
  IF v_t.held_until < now() THEN
    RAISE EXCEPTION 'That hold ran out at %. The seat went back on sale.',
      to_char(v_t.held_until, 'HH24:MI');
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  UPDATE tickets_issued
     SET status = 'issued', held_until = NULL,
         holder_name = coalesce(p_holder_name, holder_name),
         holder_phone = coalesce(p_holder_phone, holder_phone),
         holder_doc = coalesce(p_holder_doc, holder_doc),
         price = coalesce(p_price, price),
         sale_ref = coalesce(p_sale_ref, sale_ref),
         issued_at = now(), issued_by = v_me
   WHERE id = p_ticket
   RETURNING * INTO v_t;
  RETURN v_t;
END;
$$;

/** Give back every seat somebody put in a basket and walked away from.
 *  Run on a schedule, or from the screen. */
CREATE OR REPLACE FUNCTION public.release_expired_holds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  WITH gone AS (
    UPDATE tickets_issued
       SET status = 'expired'
     WHERE status = 'held' AND held_until < now()
     RETURNING 1)
  SELECT count(*) INTO v_n FROM gone;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- 9. THE GATE
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.admit_ticket(text, uuid, text);
/** Present a code at a gate.
 *
 *  ALWAYS RETURNS, never raises, and ALWAYS LOGS. A refusal at a turnstile
 *  is a normal event, not an error, and it is the refusals that show a
 *  ticket being passed back over a fence — so they are recorded exactly
 *  like the successes.
 *
 *  The answer is a sentence somebody can say out loud. "Already admitted
 *  at 19:42, gate B" ends an argument. "Invalid" starts one. */
CREATE OR REPLACE FUNCTION public.admit_ticket(
  p_code text, p_occurrence uuid DEFAULT NULL, p_gate text DEFAULT NULL)
 RETURNS TABLE (
   out_ok       boolean,
   out_result   text,
   out_message  text,
   out_ticket_id uuid,
   out_holder   text,
   out_class    text,
   out_seat     text,
   out_product  text,
   out_starts   timestamp with time zone,
   out_used     integer,
   out_allowed  integer
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_t tickets_issued; v_o ticket_occurrences; v_p ticketed_products;
  v_me uuid; v_code text; v_result text; v_msg text; v_ok boolean := false;
BEGIN
  -- Typed in lower case, or with the dashes left out. Neither is a
  -- forgery and neither should be turned away.
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
  IF length(v_code) = 12 THEN
    v_code := substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  SELECT * INTO v_t FROM tickets_issued WHERE code = v_code FOR UPDATE;

  IF v_t.id IS NULL THEN
    v_result := 'not_found'; v_msg := 'No such ticket.';
  ELSE
    SELECT * INTO v_o FROM ticket_occurrences WHERE id = v_t.occurrence_id;
    SELECT * INTO v_p FROM ticketed_products WHERE id = v_o.product_id;

    IF p_occurrence IS NOT NULL AND v_t.occurrence_id <> p_occurrence THEN
      v_result := 'wrong_occurrence';
      v_msg := format('This ticket is for %s.', coalesce(v_o.label, to_char(v_o.starts_at, 'DD Mon HH24:MI')));
    ELSIF v_t.status IN ('void', 'refunded') THEN
      v_result := 'void';
      v_msg := format('This ticket was %s: %s', v_t.status,
                      coalesce(v_t.void_reason, 'no reason recorded'));
    ELSIF v_t.status IN ('held', 'expired') THEN
      v_result := 'void';
      v_msg := 'This ticket was never paid for.';
    ELSIF v_o.status = 'cancelled' THEN
      v_result := 'cancelled';
      v_msg := format('%s was cancelled: %s', coalesce(v_o.label, v_p.name),
                      coalesce(v_o.cancel_reason, 'no reason recorded'));
    ELSIF v_o.valid_from IS NOT NULL AND now() < v_o.valid_from THEN
      v_result := 'too_early';
      v_msg := format('Valid from %s.', to_char(v_o.valid_from, 'DD Mon HH24:MI'));
    ELSIF v_o.valid_until IS NOT NULL AND now() > v_o.valid_until THEN
      v_result := 'too_late';
      v_msg := format('Expired %s.', to_char(v_o.valid_until, 'DD Mon HH24:MI'));
    ELSIF v_p.max_admissions IS NOT NULL AND v_t.admissions_used >= v_p.max_admissions THEN
      -- The distinction that matters at a gate: a single-entry ticket
      -- scanned twice is a DUPLICATE and somebody is standing there with
      -- it. A pass that has used all its entries is simply spent.
      IF v_p.max_admissions = 1 THEN
        v_result := 'duplicate';
        v_msg := format('Already admitted at %s%s.',
                        to_char(v_t.last_admitted_at, 'HH24:MI'),
                        coalesce((SELECT ', ' || gate FROM ticket_admissions
                                   WHERE ticket_id = v_t.id AND result = 'admitted'
                                   ORDER BY admitted_at DESC LIMIT 1), ''));
      ELSE
        v_result := 'exhausted';
        v_msg := format('All %s entries have been used.', v_p.max_admissions);
      END IF;
    ELSE
      -- The counter is the guard, and the row is already locked.
      UPDATE tickets_issued
         SET status = 'admitted',
             admissions_used = admissions_used + 1,
             first_admitted_at = coalesce(first_admitted_at, now()),
             last_admitted_at = now()
       WHERE id = v_t.id
       RETURNING * INTO v_t;
      v_ok := true; v_result := 'admitted';
      v_msg := coalesce(v_t.holder_name, 'Admitted');
    END IF;
  END IF;

  INSERT INTO ticket_admissions (ticket_id, code_tried, occurrence_id, gate,
                                 admitted_by, result, note)
  VALUES (v_t.id, v_code, v_t.occurrence_id, p_gate, v_me, v_result, v_msg);

  out_ok := v_ok; out_result := v_result; out_message := v_msg;
  out_ticket_id := v_t.id; out_holder := v_t.holder_name;
  out_class := (SELECT name FROM ticket_classes WHERE id = v_t.class_id);
  out_seat := (SELECT label FROM ticket_seats WHERE id = v_t.seat_id);
  out_product := v_p.name; out_starts := v_o.starts_at;
  out_used := v_t.admissions_used; out_allowed := v_p.max_admissions;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------
-- 10. GIVING MONEY BACK, AND CALLING IT OFF
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_ticket(p_ticket uuid, p_reason text)
 RETURNS tickets_issued
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_t tickets_issued;
BEGIN
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a ticket needs a reason. It stays on the record either way.';
  END IF;
  SELECT * INTO v_t FROM tickets_issued WHERE id = p_ticket FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'That ticket does not exist'; END IF;
  IF v_t.status IN ('void', 'refunded') THEN
    RAISE EXCEPTION 'That ticket is already %', v_t.status;
  END IF;
  IF v_t.status = 'admitted' THEN
    RAISE EXCEPTION 'Somebody has already travelled on that ticket. Refund it instead of pretending it was never used.';
  END IF;

  UPDATE tickets_issued SET status = 'void', void_reason = p_reason, held_until = NULL
   WHERE id = p_ticket RETURNING * INTO v_t;
  RETURN v_t;
END;
$$;

/** Money back. The seat goes with it — which the partial unique index
 *  does on its own, because a refunded ticket is not a live one. */
CREATE OR REPLACE FUNCTION public.refund_ticket(
  p_ticket uuid, p_amount numeric DEFAULT NULL, p_reason text DEFAULT NULL)
 RETURNS tickets_issued
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_t tickets_issued;
BEGIN
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A refund needs a reason.';
  END IF;
  SELECT * INTO v_t FROM tickets_issued WHERE id = p_ticket FOR UPDATE;
  IF v_t.id IS NULL THEN RAISE EXCEPTION 'That ticket does not exist'; END IF;
  IF v_t.status = 'refunded' THEN RAISE EXCEPTION 'That ticket has already been refunded'; END IF;
  IF v_t.status NOT IN ('issued', 'admitted') THEN
    RAISE EXCEPTION 'A ticket that is % has no money to give back', v_t.status;
  END IF;
  IF coalesce(p_amount, v_t.price) > v_t.price THEN
    RAISE EXCEPTION 'That is more than the % the ticket cost.', v_t.price;
  END IF;

  UPDATE tickets_issued
     SET status = 'refunded', refunded_amount = coalesce(p_amount, v_t.price),
         void_reason = p_reason
   WHERE id = p_ticket RETURNING * INTO v_t;
  RETURN v_t;
END;
$$;

/** Calling off a departure. Every live ticket on it is voided, with the
 *  same reason, so nobody turns up to a bus that is not coming. */
CREATE OR REPLACE FUNCTION public.cancel_occurrence(p_occurrence uuid, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  IF coalesce(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Say why it is off. Everybody holding a ticket will ask.';
  END IF;
  UPDATE ticket_occurrences SET status = 'cancelled', cancel_reason = p_reason
   WHERE id = p_occurrence;

  WITH gone AS (
    UPDATE tickets_issued
       SET status = 'void', void_reason = p_reason, held_until = NULL
     WHERE occurrence_id = p_occurrence AND status IN ('held', 'issued')
     RETURNING 1)
  SELECT count(*) INTO v_n FROM gone;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- 11. THE MANIFEST
-- Who is actually on the vehicle. A legal requirement for road transport
-- here, and the list somebody needs in their hand if anything happens.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.passenger_manifest(uuid);
CREATE OR REPLACE FUNCTION public.passenger_manifest(p_occurrence uuid)
 RETURNS TABLE (
   out_seat     text,
   out_class    text,
   out_holder   text,
   out_phone    text,
   out_document text,
   out_code     text,
   out_boarded  boolean,
   out_boarded_at timestamp with time zone
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT s.label, c.name, t.holder_name, t.holder_phone, t.holder_doc, t.code,
         t.status = 'admitted', t.first_admitted_at
    FROM tickets_issued t
    LEFT JOIN ticket_seats s ON s.id = t.seat_id
    LEFT JOIN ticket_classes c ON c.id = t.class_id
   WHERE t.occurrence_id = p_occurrence
     AND t.status IN ('issued', 'admitted')
   ORDER BY s.sort_order NULLS LAST, s.label NULLS LAST, t.holder_name;
$$;

/** What was taken, by product and class, over a period. Refunds come off
 *  rather than being left out, because a day with ten sales and nine
 *  refunds is not a day with ten sales. */
DROP FUNCTION IF EXISTS public.ticket_sales(date, date);
CREATE OR REPLACE FUNCTION public.ticket_sales(p_from date, p_to date)
 RETURNS TABLE (
   out_product  text,
   out_class    text,
   out_issued   bigint,
   out_admitted bigint,
   out_refunded bigint,
   out_gross    numeric,
   out_refunds  numeric,
   out_net      numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT p.name, c.name,
         count(*) FILTER (WHERE t.status IN ('issued', 'admitted')),
         count(*) FILTER (WHERE t.status = 'admitted'),
         count(*) FILTER (WHERE t.status = 'refunded'),
         coalesce(sum(t.price) FILTER (WHERE t.status IN ('issued', 'admitted', 'refunded')), 0),
         coalesce(sum(t.refunded_amount) FILTER (WHERE t.status = 'refunded'), 0),
         coalesce(sum(t.price) FILTER (WHERE t.status IN ('issued', 'admitted', 'refunded')), 0)
         - coalesce(sum(t.refunded_amount) FILTER (WHERE t.status = 'refunded'), 0)
    FROM tickets_issued t
    JOIN ticket_occurrences o ON o.id = t.occurrence_id
    JOIN ticketed_products p ON p.id = o.product_id
    LEFT JOIN ticket_classes c ON c.id = t.class_id
   WHERE coalesce(t.issued_at, t.created_at)::date BETWEEN p_from AND p_to
   GROUP BY p.name, c.name
   ORDER BY p.name, c.name;
$$;

-- ---------------------------------------------------------------------
-- 12. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ticketing_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Somebody tried a code that does not exist, more than once. One is a
  -- typo. Several is somebody trying codes.
  SELECT 'gate', NULL::uuid, coalesce(a.gate, 'gate not named'),
         count(*)::text || ' scans in the last 7 days for codes that do not exist.'
    FROM ticket_admissions a
   WHERE a.result = 'not_found' AND a.admitted_at > now() - interval '7 days'
   GROUP BY a.gate
  HAVING count(*) >= 3

  UNION ALL
  -- The same ticket turned away as a duplicate. Either it was printed
  -- twice or it went back over a fence, and both are worth knowing.
  SELECT 'ticket', t.id, coalesce(t.holder_name, t.code),
         'Turned away ' || count(*)::text || ' time(s) as already admitted.'
    FROM ticket_admissions a
    JOIN tickets_issued t ON t.id = a.ticket_id
   WHERE a.result = 'duplicate' AND a.admitted_at > now() - interval '30 days'
   GROUP BY t.id, t.holder_name, t.code

  UNION ALL
  -- Holds nobody cleared. Every one is a seat that cannot be sold.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         count(*)::text || ' seat(s) held by a sale that was never finished. Give them back.'
    FROM tickets_issued t
    JOIN ticket_occurrences o ON o.id = t.occurrence_id
    JOIN ticketed_products p ON p.id = o.product_id
   WHERE t.status = 'held' AND t.held_until < now()
   GROUP BY o.id, o.label, p.name

  UNION ALL
  -- Sold past the vehicle. Should be impossible through hold_tickets, so
  -- if it appears something wrote to the table directly.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         'Sold ' || count(t.id)::text || ' against a capacity of ' || o.capacity::text || '.'
    FROM ticket_occurrences o
    JOIN ticketed_products p ON p.id = o.product_id
    JOIN tickets_issued t ON t.occurrence_id = o.id
                         AND t.status IN ('issued', 'admitted')
   WHERE o.capacity > 0
   GROUP BY o.id, o.label, p.name, o.capacity
  HAVING count(t.id) > o.capacity

  UNION ALL
  -- Went, and half the tickets were never scanned. Either the gate was
  -- not used or people did not travel; either way the manifest is wrong.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         count(*) FILTER (WHERE t.status = 'issued')::text
         || ' of ' || count(*)::text || ' tickets were never scanned.'
    FROM ticket_occurrences o
    JOIN ticketed_products p ON p.id = o.product_id
    JOIN tickets_issued t ON t.occurrence_id = o.id
                         AND t.status IN ('issued', 'admitted')
   WHERE o.valid_until < now() AND o.valid_until > now() - interval '30 days'
     AND o.status <> 'cancelled'
   GROUP BY o.id, o.label, p.name
  HAVING count(*) FILTER (WHERE t.status = 'issued') > 0

  UNION ALL
  -- On sale with nothing to sell.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         'Is on sale but has no classes, so there is no price and nothing to buy.'
    FROM ticket_occurrences o
    JOIN ticketed_products p ON p.id = o.product_id
   WHERE o.status = 'on_sale'
     AND NOT EXISTS (SELECT 1 FROM ticket_classes c WHERE c.occurrence_id = o.id AND c.is_active)

  UNION ALL
  -- Reserved seating with no seats drawn.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         p.name || ' is reserved seating but this one has no seat map.'
    FROM ticket_occurrences o
    JOIN ticketed_products p ON p.id = o.product_id
   WHERE p.reserved_seating AND o.status IN ('scheduled', 'on_sale')
     AND NOT EXISTS (SELECT 1 FROM ticket_seats s WHERE s.occurrence_id = o.id)

  UNION ALL
  -- Doors that never open. The gate cannot scan anybody in until the
  -- exact second of departure, which is not how boarding works.
  SELECT 'product', p.id, p.name,
         'Doors open at the moment it starts, so nobody can be scanned in while boarding. Set how many minutes before.'
    FROM ticketed_products p
   WHERE p.is_active AND p.doors_open_minutes = 0
     AND p.kind IN ('transport', 'screening', 'performance')
     AND EXISTS (SELECT 1 FROM ticket_occurrences o
                  WHERE o.product_id = p.id AND o.starts_at > now() - interval '30 days')

  UNION ALL
  -- Still on sale after it left.
  SELECT 'occurrence', o.id, coalesce(o.label, p.name),
         'Still on sale, and it started ' || to_char(o.starts_at, 'DD Mon HH24:MI') || '.'
    FROM ticket_occurrences o
    JOIN ticketed_products p ON p.id = o.product_id
   WHERE o.status = 'on_sale' AND o.starts_at < now() - interval '2 hours';
$$;

GRANT EXECUTE ON FUNCTION public.new_ticket_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.occurrence_availability(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seat_map(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hold_tickets(uuid, uuid, integer, uuid[], integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_ticket(uuid, text, text, text, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_expired_holds() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admit_ticket(text, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_ticket(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refund_ticket(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_occurrence(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.passenger_manifest(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ticket_sales(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ticketing_reconciliation() TO authenticated;

-- ---------------------------------------------------------------------
-- 13. ROW LEVEL SECURITY
-- Selling and scanning are counter work, so a Cashier does both. Setting
-- up products, occurrences, classes and seat maps is a management job,
-- because that is where the prices and the capacities live.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ticketed_products', 'ticket_occurrences',
                           'ticket_classes', 'ticket_seats']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Manager','Ticketing Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Manager','Ticketing Manager']))$p$,
                   t || '_write', t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['tickets_issued', 'ticket_admissions']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Cashier','Manager','Ticketing Manager']))
                      WITH CHECK (public.has_any_role(ARRAY['Cashier','Manager','Ticketing Manager']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
