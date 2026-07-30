-- =====================================================================
-- KAREYA SILO — MEETING ROOMS, FOR THE PEOPLE WHO WORK HERE
-- ---------------------------------------------------------------------
-- WHAT WAS MISSING
--
-- A meeting room already existed in two places and neither of them was
-- this one.
--
-- `cowork_spaces` has a 'meeting_room' type and `cowork_bookings` books
-- it — but that is a room being SOLD. It wants a member, a plan
-- allowance, an hourly rate and a charge to invoice. `equipment_bookings`
-- is the same shape for laboratory instruments, charged to a grant.
--
-- Neither is what happens in an office. Staff book a room, for nothing,
-- and invite colleagues. There is no member and no money. And the three
-- things that actually decide whether office room booking works were
-- absent from both:
--
-- 1. RECURRING MEETINGS. The weekly stand-up is most of what a room is
--    used for. Booking it fifty-two times by hand is not a feature, and
--    cancelling one week must not cancel the series.
--
-- 2. WHETHER THE PEOPLE ARE FREE. Booking a room is easy; the room is
--    not usually the scarce thing. Four of the six people you invited
--    being in another meeting is the actual problem, and nothing looked.
--
-- 3. ROOMS HELD AND NOT USED. The commonest complaint about every room
--    booking system ever built. A room booked and not turned up to is a
--    room nobody else could have, so a booking has to be claimed and an
--    unclaimed one has to come back.
--
-- Also here because an office needs them and they are cheap: buffer time
-- between bookings so a room can be turned around, opening hours so
-- nobody books 3am, a booking window so the calendar is not filled to
-- next year, capacity against the number of attendees, and approval for
-- the room the directors use.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- No charging. An internal room is a cost the business already carries;
-- billing a department for it is a management fashion, not a fact, and
-- the co-working vertical already exists for rooms that are genuinely
-- sold. No default rooms, hours, buffers or windows either — every
-- office is different and a default here would be somebody's policy.
--
-- Idempotent. Apply after the base schema (employees).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE ROOMS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.meeting_rooms (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  name          text NOT NULL,
  location      text,                          -- floor, building, wing
  capacity      integer DEFAULT 0 NOT NULL,
  facilities    text[],                        -- projector, whiteboard, video call…
  colour        text,                          -- so a calendar can tell them apart

  -- ---- how it may be booked ----
  opens_at      time,                          -- NULL = any time
  closes_at     time,
  days_open     integer[],                     -- 0 = Sunday … 6 = Saturday; NULL = every day
  min_minutes   integer DEFAULT 15,
  max_minutes   integer,                       -- NULL = no limit
  buffer_minutes integer DEFAULT 0,            -- turnaround between bookings
  max_days_ahead integer,                      -- how far out the calendar may be filled
  min_notice_minutes integer DEFAULT 0,
  -- A room somebody has to ask for.
  requires_approval boolean DEFAULT false,
  approval_role text,

  -- ---- claiming ----
  -- A booking nobody claims within this many minutes of its start is
  -- released, so the room comes back rather than sitting empty and shown
  -- as busy. NULL = the room is never taken back.
  release_after_minutes integer,

  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT meeting_rooms_pkey PRIMARY KEY (id),
  CONSTRAINT meeting_rooms_capacity_check CHECK (capacity >= 0),
  CONSTRAINT meeting_rooms_hours_check CHECK (closes_at IS NULL OR opens_at IS NULL OR closes_at > opens_at),
  CONSTRAINT meeting_rooms_minutes_check
    CHECK (min_minutes > 0 AND (max_minutes IS NULL OR max_minutes >= min_minutes)),
  CONSTRAINT meeting_rooms_buffer_check CHECK (buffer_minutes >= 0),
  CONSTRAINT meeting_rooms_release_check CHECK (release_after_minutes IS NULL OR release_after_minutes > 0)
);

COMMENT ON TABLE public.meeting_rooms IS
  'An internal room, booked by staff for nothing. A room you SELL belongs in cowork_spaces.';

CREATE INDEX IF NOT EXISTS idx_meeting_rooms_active ON public.meeting_rooms (is_active);

-- ---------------------------------------------------------------------
-- 2. RECURRING MEETINGS
-- A series is the pattern; the bookings are the occurrences. Cancelling
-- one week leaves the rest standing, which is the whole reason the two
-- are separate rows.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.meeting_series (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  room_id       uuid NOT NULL,
  title         text NOT NULL,
  organiser_id  uuid,
  frequency     text DEFAULT 'weekly' NOT NULL,   -- daily | weekly | fortnightly | monthly
  days_of_week  integer[],                        -- weekly / fortnightly: which days
  start_time    time NOT NULL,
  end_time      time NOT NULL,
  starts_on     date NOT NULL,
  ends_on       date,                             -- NULL = until somebody stops it
  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT meeting_series_pkey PRIMARY KEY (id),
  CONSTRAINT meeting_series_room_fkey FOREIGN KEY (room_id)
    REFERENCES public.meeting_rooms(id) ON DELETE CASCADE,
  CONSTRAINT meeting_series_organiser_fkey FOREIGN KEY (organiser_id)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT meeting_series_freq_check
    CHECK (frequency = ANY (ARRAY['daily','weekly','fortnightly','monthly'])),
  CONSTRAINT meeting_series_time_check CHECK (end_time > start_time),
  CONSTRAINT meeting_series_dates_check CHECK (ends_on IS NULL OR ends_on >= starts_on)
);

CREATE INDEX IF NOT EXISTS idx_meeting_series_room ON public.meeting_series (room_id);

-- ---------------------------------------------------------------------
-- 3. THE BOOKINGS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.room_bookings (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  room_id       uuid NOT NULL,
  series_id     uuid,                          -- one occurrence of a recurring meeting
  title         text NOT NULL,
  purpose       text,
  organiser_id  uuid,
  starts_at     timestamp with time zone NOT NULL,
  ends_at       timestamp with time zone NOT NULL,
  attendee_count integer DEFAULT 0,            -- headcount, including people not in Kareya
  status        text DEFAULT 'booked' NOT NULL,
  -- 'booked'    — held
  -- 'confirmed' — approved, where the room needs it
  -- 'in_use'    — somebody claimed it
  -- 'completed' — it happened
  -- 'cancelled' — called off, with a reason
  -- 'released'  — nobody claimed it and the room was taken back
  approved_by   uuid,
  claimed_at    timestamp with time zone,
  cancelled_at  timestamp with time zone,
  cancel_reason text,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT room_bookings_pkey PRIMARY KEY (id),
  CONSTRAINT room_bookings_room_fkey FOREIGN KEY (room_id)
    REFERENCES public.meeting_rooms(id) ON DELETE CASCADE,
  CONSTRAINT room_bookings_series_fkey FOREIGN KEY (series_id)
    REFERENCES public.meeting_series(id) ON DELETE SET NULL,
  CONSTRAINT room_bookings_organiser_fkey FOREIGN KEY (organiser_id)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT room_bookings_approved_fkey FOREIGN KEY (approved_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT room_bookings_period_check CHECK (ends_at > starts_at),
  CONSTRAINT room_bookings_count_check CHECK (attendee_count >= 0),
  CONSTRAINT room_bookings_status_check CHECK (status = ANY (ARRAY[
    'booked', 'confirmed', 'in_use', 'completed', 'cancelled', 'released']))
);

-- One room, one meeting at a time. Enforced here rather than in the app,
-- because a screen cannot promise it once two people book from two
-- machines in the same second — which in an office is exactly what
-- happens at five to nine.
--
-- The range is widened by the room's buffer so a turnaround gap cannot be
-- booked over. It is stored rather than computed because an exclusion
-- constraint needs an immutable expression.
ALTER TABLE public.room_bookings
  ADD COLUMN IF NOT EXISTS held_from timestamp with time zone;
ALTER TABLE public.room_bookings
  ADD COLUMN IF NOT EXISTS held_to timestamp with time zone;

CREATE OR REPLACE FUNCTION public.room_booking_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
DECLARE v_buf integer;
BEGIN
  SELECT coalesce(buffer_minutes, 0) INTO v_buf FROM meeting_rooms WHERE id = NEW.room_id;
  NEW.held_from := NEW.starts_at;
  NEW.held_to   := NEW.ends_at + make_interval(mins => coalesce(v_buf, 0));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_room_booking_hold ON public.room_bookings;
CREATE TRIGGER trg_room_booking_hold
  BEFORE INSERT OR UPDATE ON public.room_bookings
  FOR EACH ROW EXECUTE FUNCTION public.room_booking_hold();

DO $ex$ BEGIN
  ALTER TABLE public.room_bookings
    ADD CONSTRAINT room_bookings_no_overlap
    EXCLUDE USING gist (
      room_id WITH =,
      tstzrange(held_from, held_to) WITH &&
    ) WHERE (status NOT IN ('cancelled', 'released'));
EXCEPTION WHEN duplicate_table THEN NULL; WHEN duplicate_object THEN NULL; END $ex$;

CREATE INDEX IF NOT EXISTS idx_room_bookings_room ON public.room_bookings (room_id, starts_at);
CREATE INDEX IF NOT EXISTS idx_room_bookings_series ON public.room_bookings (series_id);
CREATE INDEX IF NOT EXISTS idx_room_bookings_organiser ON public.room_bookings (organiser_id);
CREATE INDEX IF NOT EXISTS idx_room_bookings_starts ON public.room_bookings (starts_at);

-- ---- who is coming ---------------------------------------------------
CREATE TABLE IF NOT EXISTS public.room_booking_attendees (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  booking_id  uuid NOT NULL,
  employee_id uuid NOT NULL,
  response    text DEFAULT 'invited' NOT NULL,   -- invited | accepted | declined | tentative
  is_required boolean DEFAULT true,
  responded_at timestamp with time zone,
  CONSTRAINT room_booking_attendees_pkey PRIMARY KEY (id),
  CONSTRAINT room_booking_attendees_booking_fkey FOREIGN KEY (booking_id)
    REFERENCES public.room_bookings(id) ON DELETE CASCADE,
  CONSTRAINT room_booking_attendees_employee_fkey FOREIGN KEY (employee_id)
    REFERENCES public.employees(id) ON DELETE CASCADE,
  CONSTRAINT room_booking_attendees_response_check
    CHECK (response = ANY (ARRAY['invited','accepted','declined','tentative'])),
  CONSTRAINT uq_room_booking_attendee UNIQUE (booking_id, employee_id)
);

CREATE INDEX IF NOT EXISTS idx_room_attendees_employee ON public.room_booking_attendees (employee_id);

-- ---------------------------------------------------------------------
-- 4. WHETHER THE ROOM MAY BE BOOKED AT ALL
-- The rules a room carries, checked in one place so every caller gets the
-- same answer and the same words.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_room_rules(
  p_room_id uuid, p_starts timestamp with time zone, p_ends timestamp with time zone,
  p_attendees integer DEFAULT 0)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_r meeting_rooms; v_tz text; v_from timestamp; v_to timestamp; v_mins numeric;
BEGIN
  SELECT * INTO v_r FROM meeting_rooms WHERE id = p_room_id;
  IF v_r.id IS NULL THEN RAISE EXCEPTION 'That room does not exist'; END IF;
  IF NOT v_r.is_active THEN RAISE EXCEPTION '% is not in use.', v_r.name; END IF;
  IF p_ends <= p_starts THEN RAISE EXCEPTION 'A meeting has to end after it begins'; END IF;

  -- Opening hours are a wall-clock idea, so they are read on a wall clock.
  -- The discount settings already carry the business timezone; falling back
  -- to UTC would silently shift every office's opening hours.
  SELECT timezone INTO v_tz FROM discount_settings WHERE id;
  v_from := p_starts AT TIME ZONE coalesce(v_tz, 'UTC');
  v_to   := p_ends   AT TIME ZONE coalesce(v_tz, 'UTC');
  v_mins := extract(epoch FROM (p_ends - p_starts)) / 60.0;

  IF v_mins < coalesce(v_r.min_minutes, 0) THEN
    RAISE EXCEPTION '% is booked in blocks of at least % minutes.', v_r.name, v_r.min_minutes;
  END IF;
  IF v_r.max_minutes IS NOT NULL AND v_mins > v_r.max_minutes THEN
    RAISE EXCEPTION '% cannot be held for more than % minutes at a time.', v_r.name, v_r.max_minutes;
  END IF;

  IF v_r.days_open IS NOT NULL AND array_length(v_r.days_open, 1) > 0
     AND NOT (extract(dow FROM v_from)::integer = ANY (v_r.days_open)) THEN
    RAISE EXCEPTION '% is not open that day.', v_r.name;
  END IF;
  IF v_r.opens_at IS NOT NULL AND v_from::time < v_r.opens_at THEN
    RAISE EXCEPTION '% opens at %.', v_r.name, v_r.opens_at;
  END IF;
  IF v_r.closes_at IS NOT NULL AND v_to::time > v_r.closes_at THEN
    RAISE EXCEPTION '% closes at %.', v_r.name, v_r.closes_at;
  END IF;
  -- A meeting that runs past midnight would pass both checks above while
  -- being outside the room's hours for most of its length.
  IF v_from::date <> v_to::date AND (v_r.opens_at IS NOT NULL OR v_r.closes_at IS NOT NULL) THEN
    RAISE EXCEPTION '% keeps opening hours, so a meeting cannot run past midnight.', v_r.name;
  END IF;

  IF v_r.max_days_ahead IS NOT NULL
     AND p_starts > now() + make_interval(days => v_r.max_days_ahead) THEN
    RAISE EXCEPTION '% can only be booked % days ahead.', v_r.name, v_r.max_days_ahead;
  END IF;
  IF coalesce(v_r.min_notice_minutes, 0) > 0
     AND p_starts < now() + make_interval(mins => v_r.min_notice_minutes) THEN
    RAISE EXCEPTION '% needs % minutes notice.', v_r.name, v_r.min_notice_minutes;
  END IF;

  IF v_r.capacity > 0 AND coalesce(p_attendees, 0) > v_r.capacity THEN
    RAISE EXCEPTION '% seats %, and % are coming.', v_r.name, v_r.capacity, p_attendees;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. BOOKING ONE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_room(
  p_room_id      uuid,
  p_title        text,
  p_starts       timestamp with time zone,
  p_ends         timestamp with time zone,
  p_attendees    uuid[] DEFAULT NULL,
  p_attendee_count integer DEFAULT NULL,
  p_purpose      text DEFAULT NULL,
  p_series_id    uuid DEFAULT NULL)
 RETURNS room_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_r meeting_rooms; v_b room_bookings; v_me uuid; v_count integer; v_status text;
BEGIN
  IF coalesce(trim(p_title), '') = '' THEN
    RAISE EXCEPTION 'A meeting needs a title. "Meeting" on a wall planner tells nobody anything.';
  END IF;
  SELECT * INTO v_r FROM meeting_rooms WHERE id = p_room_id;
  IF v_r.id IS NULL THEN RAISE EXCEPTION 'That room does not exist'; END IF;

  -- The headcount is whichever is larger: the people invited through
  -- Kareya, or the number somebody typed for guests who are not in it.
  v_count := greatest(coalesce(p_attendee_count, 0),
                      coalesce(array_length(p_attendees, 1), 0));

  PERFORM check_room_rules(p_room_id, p_starts, p_ends, v_count);

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  -- A room that needs asking for starts as a request, not a holding.
  v_status := CASE WHEN v_r.requires_approval THEN 'booked' ELSE 'confirmed' END;

  -- The exclusion constraint is what actually stops a double booking; the
  -- message here is only so the person reads something they understand.
  BEGIN
    INSERT INTO room_bookings (room_id, series_id, title, purpose, organiser_id,
                               starts_at, ends_at, attendee_count, status)
    VALUES (p_room_id, p_series_id, p_title, p_purpose, v_me,
            p_starts, p_ends, v_count, v_status)
    RETURNING * INTO v_b;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION '% is already taken then.', v_r.name;
  END;

  IF p_attendees IS NOT NULL THEN
    INSERT INTO room_booking_attendees (booking_id, employee_id)
    SELECT v_b.id, x FROM unnest(p_attendees) AS x
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_b;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_room_booking(p_booking_id uuid)
 RETURNS room_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b room_bookings; v_r meeting_rooms; v_me uuid;
BEGIN
  SELECT * INTO v_b FROM room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status <> 'booked' THEN RAISE EXCEPTION 'That booking is already %', v_b.status; END IF;

  SELECT * INTO v_r FROM meeting_rooms WHERE id = v_b.room_id;
  IF v_r.requires_approval AND coalesce(v_r.approval_role, '') <> ''
     AND NOT has_any_role(ARRAY[v_r.approval_role]) THEN
    RAISE EXCEPTION '% is approved by a %.', v_r.name, v_r.approval_role;
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  UPDATE room_bookings SET status = 'confirmed', approved_by = v_me
   WHERE id = p_booking_id RETURNING * INTO v_b;
  RETURN v_b;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_room_booking(p_booking_id uuid, p_reason text)
 RETURNS room_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b room_bookings;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Say why the meeting is off. The people who cleared their morning will want to know.';
  END IF;
  SELECT * INTO v_b FROM room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status IN ('cancelled', 'released') THEN
    RAISE EXCEPTION 'That booking is already %', v_b.status;
  END IF;

  -- Cancelling one occurrence leaves the series alone. That is the whole
  -- reason a series and its bookings are separate rows.
  UPDATE room_bookings
     SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason
   WHERE id = p_booking_id RETURNING * INTO v_b;
  RETURN v_b;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. CLAIMING A ROOM, AND TAKING BACK AN UNCLAIMED ONE
-- The commonest complaint about every room booking system ever built: a
-- room held all afternoon by a meeting that never happened.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_room(p_booking_id uuid)
 RETURNS room_bookings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_b room_bookings;
BEGIN
  SELECT * INTO v_b FROM room_bookings WHERE id = p_booking_id FOR UPDATE;
  IF v_b.id IS NULL THEN RAISE EXCEPTION 'That booking does not exist'; END IF;
  IF v_b.status = 'released' THEN
    RAISE EXCEPTION 'That room was given back because nobody claimed it. Book it again.';
  END IF;
  IF v_b.status NOT IN ('booked', 'confirmed') THEN
    RAISE EXCEPTION 'That booking is already %', v_b.status;
  END IF;
  -- Claiming a room the day before does not hold it for the day before.
  IF now() < v_b.starts_at - interval '15 minutes' THEN
    RAISE EXCEPTION 'That meeting has not started yet.';
  END IF;

  UPDATE room_bookings SET status = 'in_use', claimed_at = now()
   WHERE id = p_booking_id RETURNING * INTO v_b;
  RETURN v_b;
END;
$$;

-- Give back every room whose meeting nobody turned up to. Run on a
-- schedule, or from the screen; it changes nothing that was claimed.
CREATE OR REPLACE FUNCTION public.release_unclaimed_rooms()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  WITH gone AS (
    UPDATE room_bookings b
       SET status = 'released',
           cancel_reason = 'Nobody claimed the room'
      FROM meeting_rooms r
     WHERE r.id = b.room_id
       AND b.status IN ('booked', 'confirmed')
       AND r.release_after_minutes IS NOT NULL
       AND now() > b.starts_at + make_interval(mins => r.release_after_minutes)
       -- Only while the meeting would still have been running. A booking
       -- that finished hours ago is over, not released.
       AND now() < b.ends_at
     RETURNING 1)
  SELECT count(*) INTO v_n FROM gone;
  RETURN v_n;
END;
$$;

-- Close off meetings that have ended. A claimed one happened; an
-- unclaimed one is a no-show and is worth being able to count.
CREATE OR REPLACE FUNCTION public.close_past_meetings()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  WITH done AS (
    UPDATE room_bookings
       SET status = 'completed'
     WHERE status = 'in_use' AND ends_at < now()
     RETURNING 1)
  SELECT count(*) INTO v_n FROM done;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. WHETHER THE PEOPLE ARE FREE
-- The room is rarely the scarce thing. Four of the six you invited being
-- in another meeting is the actual problem, and it is reported rather
-- than refused: people are double-booked all the time and choose which
-- one to go to.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.attendee_clashes(uuid);
CREATE OR REPLACE FUNCTION public.attendee_clashes(p_booking_id uuid)
 RETURNS TABLE (
   out_employee_id uuid,
   out_name        text,
   out_clash_title text,
   out_starts      timestamp with time zone,
   out_ends        timestamp with time zone,
   out_required    boolean
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT e.id, e.name, other.title, other.starts_at, other.ends_at, a.is_required
    FROM room_bookings b
    JOIN room_booking_attendees a ON a.booking_id = b.id
    JOIN employees e ON e.id = a.employee_id
    JOIN room_booking_attendees oa ON oa.employee_id = a.employee_id
    JOIN room_bookings other ON other.id = oa.booking_id
   WHERE b.id = p_booking_id
     AND other.id <> b.id
     AND other.status NOT IN ('cancelled', 'released')
     AND a.response <> 'declined'
     AND oa.response <> 'declined'
     AND tstzrange(other.starts_at, other.ends_at) && tstzrange(b.starts_at, b.ends_at)
   ORDER BY a.is_required DESC, e.name;
$$;

-- Free rooms in a window, so somebody can be shown what they can have
-- rather than guessing and being told no.
DROP FUNCTION IF EXISTS public.free_rooms(timestamp with time zone, timestamp with time zone, integer);
CREATE OR REPLACE FUNCTION public.free_rooms(
  p_starts timestamp with time zone, p_ends timestamp with time zone,
  p_seats integer DEFAULT 0)
 RETURNS TABLE (out_room_id uuid, out_name text, out_capacity integer, out_location text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT r.id, r.name, r.capacity, r.location
    FROM meeting_rooms r
   WHERE r.is_active
     AND (coalesce(p_seats, 0) = 0 OR r.capacity = 0 OR r.capacity >= p_seats)
     AND NOT EXISTS (
       SELECT 1 FROM room_bookings b
        WHERE b.room_id = r.id
          AND b.status NOT IN ('cancelled', 'released')
          AND tstzrange(b.held_from, b.held_to) && tstzrange(p_starts, p_ends))
   ORDER BY
     -- The smallest room that fits first: putting two people in the
     -- boardroom is how the boardroom is never available.
     CASE WHEN r.capacity = 0 THEN 2147483647 ELSE r.capacity END, r.name;
$$;

-- What one person has on, so a screen can show a day at a glance.
DROP FUNCTION IF EXISTS public.my_meetings(uuid, date, date);
CREATE OR REPLACE FUNCTION public.my_meetings(
  p_employee_id uuid, p_from date, p_to date)
 RETURNS TABLE (
   out_booking_id uuid,
   out_title      text,
   out_room       text,
   out_starts     timestamp with time zone,
   out_ends       timestamp with time zone,
   out_status     text,
   out_organising boolean,
   out_response   text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT b.id, b.title, r.name, b.starts_at, b.ends_at, b.status,
         b.organiser_id = p_employee_id,
         coalesce(a.response, CASE WHEN b.organiser_id = p_employee_id THEN 'accepted' END)
    FROM room_bookings b
    JOIN meeting_rooms r ON r.id = b.room_id
    LEFT JOIN room_booking_attendees a
           ON a.booking_id = b.id AND a.employee_id = p_employee_id
   WHERE b.status NOT IN ('cancelled', 'released')
     AND (b.organiser_id = p_employee_id OR a.id IS NOT NULL)
     AND b.starts_at::date BETWEEN p_from AND p_to
   ORDER BY b.starts_at;
$$;

CREATE OR REPLACE FUNCTION public.respond_to_meeting(p_booking_id uuid, p_response text)
 RETURNS room_booking_attendees
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_a room_booking_attendees; v_me uuid;
BEGIN
  IF p_response NOT IN ('accepted', 'declined', 'tentative') THEN
    RAISE EXCEPTION 'An answer is accepted, declined or tentative';
  END IF;
  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');
  IF v_me IS NULL THEN RAISE EXCEPTION 'Only somebody invited can answer for themselves'; END IF;

  UPDATE room_booking_attendees
     SET response = p_response, responded_at = now()
   WHERE booking_id = p_booking_id AND employee_id = v_me
   RETURNING * INTO v_a;
  IF v_a.id IS NULL THEN RAISE EXCEPTION 'You are not on that meeting'; END IF;
  RETURN v_a;
END;
$$;

-- ---------------------------------------------------------------------
-- 8. THE WEEKLY STAND-UP
-- Generating occurrences is where recurring meetings usually go wrong:
-- one taken room must not stop the other fifty-one being booked. Days
-- that clash are skipped and REPORTED, not silently dropped.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.generate_meeting_series(uuid, date);
CREATE OR REPLACE FUNCTION public.generate_meeting_series(
  p_series_id uuid, p_until date DEFAULT NULL)
 RETURNS TABLE (out_on date, out_booked boolean, out_why text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_s meeting_series; v_tz text; v_day date; v_end date;
  v_starts timestamp with time zone; v_ends timestamp with time zone;
  v_step integer; v_week integer;
BEGIN
  SELECT * INTO v_s FROM meeting_series WHERE id = p_series_id;
  IF v_s.id IS NULL THEN RAISE EXCEPTION 'That series does not exist'; END IF;
  IF NOT v_s.is_active THEN RAISE EXCEPTION 'That series has been stopped'; END IF;

  v_end := coalesce(p_until, v_s.ends_on);
  IF v_end IS NULL THEN
    RAISE EXCEPTION 'Say how far to book. A meeting with no end fills the calendar to the horizon.';
  END IF;
  IF v_end < v_s.starts_on THEN RETURN; END IF;

  SELECT timezone INTO v_tz FROM discount_settings WHERE id;
  v_tz := coalesce(v_tz, 'UTC');
  v_step := CASE v_s.frequency WHEN 'daily' THEN 1 ELSE 7 END;

  v_day := v_s.starts_on;
  WHILE v_day <= v_end LOOP
    -- Which days this pattern actually falls on.
    IF v_s.frequency IN ('weekly', 'fortnightly')
       AND v_s.days_of_week IS NOT NULL AND array_length(v_s.days_of_week, 1) > 0
       AND NOT (extract(dow FROM v_day)::integer = ANY (v_s.days_of_week)) THEN
      v_day := v_day + 1;
      CONTINUE;
    END IF;
    IF v_s.frequency = 'fortnightly' THEN
      v_week := floor((v_day - v_s.starts_on) / 7.0)::integer;
      IF v_week % 2 <> 0 THEN v_day := v_day + 1; CONTINUE; END IF;
    END IF;
    IF v_s.frequency = 'monthly'
       AND extract(day FROM v_day)::integer <> extract(day FROM v_s.starts_on)::integer THEN
      v_day := v_day + 1;
      CONTINUE;
    END IF;

    v_starts := (v_day + v_s.start_time) AT TIME ZONE v_tz;
    v_ends   := (v_day + v_s.end_time)   AT TIME ZONE v_tz;

    out_on := v_day;
    BEGIN
      PERFORM book_room(v_s.room_id, v_s.title, v_starts, v_ends, NULL, NULL, NULL, v_s.id);
      out_booked := true; out_why := NULL;
    EXCEPTION WHEN others THEN
      -- One week being unavailable must not stop the rest. The reason is
      -- handed back so somebody can move that one occurrence.
      out_booked := false; out_why := left(SQLERRM, 120);
    END;
    RETURN NEXT;

    v_day := v_day + CASE
      WHEN v_s.frequency = 'daily' THEN 1
      WHEN v_s.frequency = 'monthly' THEN 1
      ELSE 1 END;
  END LOOP;
END;
$$;

-- Stopping a series leaves what already happened alone and clears what
-- has not. A weekly meeting that ends in March should not vanish from
-- February's record.
CREATE OR REPLACE FUNCTION public.stop_meeting_series(p_series_id uuid, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_n integer;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Say why the meeting is ending.';
  END IF;
  UPDATE meeting_series SET is_active = false, ends_on = coalesce(ends_on, CURRENT_DATE)
   WHERE id = p_series_id;

  WITH gone AS (
    UPDATE room_bookings
       SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason
     WHERE series_id = p_series_id
       AND status IN ('booked', 'confirmed')
       AND starts_at > now()
     RETURNING 1)
  SELECT count(*) INTO v_n FROM gone;
  RETURN v_n;
END;
$$;

-- ---------------------------------------------------------------------
-- 9. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.meeting_room_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Rooms held and not used. The whole reason claiming exists.
  --
  -- Two different failures, counted together: a booking that ran its
  -- course with nobody claiming it, and one the room was taken back from.
  -- The second is a fact the moment it happens, so it counts even while
  -- its slot is still running.
  SELECT 'room', r.id, r.name,
         count(b.id)::text || ' booking(s) in the last 30 days that nobody claimed.'
    FROM meeting_rooms r
    JOIN room_bookings b ON b.room_id = r.id
   WHERE b.starts_at > now() - interval '30 days'
     AND (b.status = 'released'
          OR (b.ends_at < now() AND b.status IN ('booked', 'confirmed')))
   GROUP BY r.id, r.name
  HAVING count(b.id) > 0

  UNION ALL
  -- Booked for more people than there are chairs.
  SELECT 'booking', b.id, b.title,
         r.name || ' seats ' || r.capacity::text || ' and ' || b.attendee_count::text || ' are coming.'
    FROM room_bookings b JOIN meeting_rooms r ON r.id = b.room_id
   WHERE b.status NOT IN ('cancelled', 'released')
     AND r.capacity > 0 AND b.attendee_count > r.capacity

  UNION ALL
  -- Waiting on somebody to say yes, and starting soon.
  SELECT 'booking', b.id, b.title,
         'Still waiting on approval and it starts ' || to_char(b.starts_at, 'DD Mon HH24:MI') || '.'
    FROM room_bookings b JOIN meeting_rooms r ON r.id = b.room_id
   WHERE b.status = 'booked' AND r.requires_approval
     AND b.starts_at BETWEEN now() AND now() + interval '2 days'

  UNION ALL
  -- A recurring meeting that has run out of bookings.
  SELECT 'series', s.id, s.title,
         'Recurring but has nothing booked after today. Generate more, or stop it.'
    FROM meeting_series s
   WHERE s.is_active
     AND NOT EXISTS (SELECT 1 FROM room_bookings b
                      WHERE b.series_id = s.id AND b.starts_at > now()
                        AND b.status NOT IN ('cancelled', 'released'))

  UNION ALL
  -- Organised by somebody who has gone.
  SELECT 'booking', b.id, b.title,
         'Organised by ' || e.name || ', who has left. Somebody else needs to own it.'
    FROM room_bookings b JOIN employees e ON e.id = b.organiser_id
   WHERE b.starts_at > now() AND b.status NOT IN ('cancelled', 'released')
     AND e.status = 'inactive'

  UNION ALL
  -- A room nobody can book.
  SELECT 'room', r.id, r.name,
         'Is in use but has no capacity set, so nothing can be checked against it.'
    FROM meeting_rooms r
   WHERE r.is_active AND r.capacity = 0;
$$;

-- How busy a room actually is, so a business can tell whether it needs
-- another one or just needs people to give back what they do not use.
DROP FUNCTION IF EXISTS public.room_utilisation(date, date);
CREATE OR REPLACE FUNCTION public.room_utilisation(p_from date, p_to date)
 RETURNS TABLE (
   out_room      text,
   out_bookings  bigint,
   out_hours     numeric,
   out_no_shows  bigint,
   out_cancelled bigint
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT r.name,
         count(*) FILTER (WHERE b.status NOT IN ('cancelled', 'released')),
         round(coalesce(sum(extract(epoch FROM (b.ends_at - b.starts_at)) / 3600.0)
                 FILTER (WHERE b.status IN ('in_use', 'completed')), 0), 2),
         count(*) FILTER (WHERE b.status = 'released'),
         count(*) FILTER (WHERE b.status = 'cancelled')
    FROM meeting_rooms r
    LEFT JOIN room_bookings b ON b.room_id = r.id
                             AND b.starts_at::date BETWEEN p_from AND p_to
   GROUP BY r.id, r.name
   ORDER BY r.name;
$$;

GRANT EXECUTE ON FUNCTION public.check_room_rules(uuid, timestamp with time zone, timestamp with time zone, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.book_room(uuid, text, timestamp with time zone, timestamp with time zone, uuid[], integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_room_booking(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_room_booking(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_room(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_unclaimed_rooms() TO authenticated;
GRANT EXECUTE ON FUNCTION public.close_past_meetings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.attendee_clashes(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.free_rooms(timestamp with time zone, timestamp with time zone, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_meetings(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_to_meeting(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_meeting_series(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.stop_meeting_series(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.meeting_room_reconciliation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.room_utilisation(date, date) TO authenticated;

-- ---------------------------------------------------------------------
-- 10. ROW LEVEL SECURITY
-- Everybody in the office books rooms and everybody needs to see what is
-- free, so reading is open to any signed-in member of staff. Setting the
-- rooms up is a management job.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['room_bookings', 'room_booking_attendees', 'meeting_series']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (true) WITH CHECK (true)$p$,
                   t || '_write', t);
  END LOOP;
END $$;

ALTER TABLE public.meeting_rooms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS meeting_rooms_read ON public.meeting_rooms;
CREATE POLICY meeting_rooms_read ON public.meeting_rooms FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS meeting_rooms_write ON public.meeting_rooms;
CREATE POLICY meeting_rooms_write ON public.meeting_rooms FOR ALL TO authenticated
  USING (public.has_any_role(ARRAY['Manager','Admin']))
  WITH CHECK (public.has_any_role(ARRAY['Manager','Admin']));
