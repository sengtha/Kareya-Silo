-- =====================================================================
-- KAREYA SILO — VERTICAL: KTV / KARAOKE VENUE (ktv)
-- ---------------------------------------------------------------------
-- Rooms are hired by the hour. A host opens a session against an
-- 'available' room, which snapshots the room's hourly_rate onto the
-- session and flips the room to 'occupied'. While the session is open
-- the floor bills live:
--     room_charge = hourly_rate * ceil(minutes_elapsed / 15) / 4
-- i.e. time is billed in quarter-hour blocks, always rounded UP.
-- Minibar / F&B lines land in ktv_session_items:
--     line_total  = quantity * unit_price
--     items_total = sum(line_total)
--     total       = room_charge + items_total
-- Closing a session freezes room_charge with the same quarter-hour rule,
-- writes the totals, and sends the room to 'cleaning' — a housekeeping
-- step returns it to 'available'.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.employees, public.has_any_role(text[]).
-- =====================================================================

-- ---- tables -------------------------------------------------------------

-- A karaoke room. hourly_rate is the list price; each session snapshots it
-- so historical bills survive a price change.
CREATE TABLE IF NOT EXISTS public.ktv_rooms (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  room_type text DEFAULT 'small'::text,          -- small | medium | vip
  hourly_rate numeric DEFAULT 0,
  capacity integer DEFAULT 0,                    -- seats
  status text DEFAULT 'available'::text,         -- available | occupied | cleaning | maintenance
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ktv_rooms_pkey PRIMARY KEY (id),
  CONSTRAINT ktv_rooms_hourly_rate_check CHECK (hourly_rate >= 0),
  CONSTRAINT ktv_rooms_capacity_check CHECK (capacity >= 0),
  CONSTRAINT ktv_rooms_status_check CHECK (status = ANY (ARRAY['available','occupied','cleaning','maintenance']))
);

-- A room hire. Open while the guests are in; closed once settled.
CREATE TABLE IF NOT EXISTS public.ktv_sessions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  session_no text,
  room_id uuid,
  customer_name text,
  customer_phone text,
  guests integer DEFAULT 1,
  start_time timestamp with time zone DEFAULT now(),
  end_time timestamp with time zone,
  hourly_rate numeric DEFAULT 0,                 -- snapshot of the room rate
  room_charge numeric DEFAULT 0,                 -- frozen at close
  items_total numeric DEFAULT 0,                 -- sum of ktv_session_items
  total numeric DEFAULT 0,                       -- room_charge + items_total
  status text DEFAULT 'open'::text,              -- open | closed | cancelled
  paid boolean DEFAULT false,
  host_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ktv_sessions_pkey PRIMARY KEY (id),
  CONSTRAINT ktv_sessions_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.ktv_rooms(id) ON DELETE SET NULL,
  CONSTRAINT ktv_sessions_host_id_fkey FOREIGN KEY (host_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT ktv_sessions_guests_check CHECK (guests >= 0),
  CONSTRAINT ktv_sessions_hourly_rate_check CHECK (hourly_rate >= 0),
  CONSTRAINT ktv_sessions_amounts_check CHECK (room_charge >= 0 AND items_total >= 0 AND total >= 0),
  CONSTRAINT ktv_sessions_period_check CHECK (end_time IS NULL OR end_time >= start_time),
  CONSTRAINT ktv_sessions_status_check CHECK (status = ANY (ARRAY['open','closed','cancelled']))
);

-- A minibar / F&B line on an open session's tab.
CREATE TABLE IF NOT EXISTS public.ktv_session_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  session_id uuid NOT NULL,
  description text NOT NULL,
  quantity numeric DEFAULT 1,
  unit_price numeric DEFAULT 0,
  line_total numeric DEFAULT 0,                  -- quantity * unit_price
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT ktv_session_items_pkey PRIMARY KEY (id),
  CONSTRAINT ktv_session_items_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.ktv_sessions(id) ON DELETE CASCADE,
  CONSTRAINT ktv_session_items_quantity_check CHECK (quantity > 0),
  CONSTRAINT ktv_session_items_unit_price_check CHECK (unit_price >= 0),
  CONSTRAINT ktv_session_items_line_total_check CHECK (line_total >= 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_ktv_rooms_status ON public.ktv_rooms (status);
CREATE INDEX IF NOT EXISTS idx_ktv_sessions_room_id ON public.ktv_sessions (room_id);
CREATE INDEX IF NOT EXISTS idx_ktv_sessions_status ON public.ktv_sessions (status);
CREATE INDEX IF NOT EXISTS idx_ktv_sessions_start_time ON public.ktv_sessions (start_time);
CREATE INDEX IF NOT EXISTS idx_ktv_sessions_host_id ON public.ktv_sessions (host_id);
CREATE INDEX IF NOT EXISTS idx_ktv_session_items_session_id ON public.ktv_session_items (session_id);

-- ---- row level security -------------------------------------------------
ALTER TABLE public.ktv_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ktv_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ktv_session_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View ktv rooms" ON public.ktv_rooms;
DROP POLICY IF EXISTS "Manage ktv rooms" ON public.ktv_rooms;
CREATE POLICY "View ktv rooms" ON public.ktv_rooms FOR SELECT TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Accountant','Manager']));
CREATE POLICY "Manage ktv rooms" ON public.ktv_rooms FOR ALL TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Host','Cashier','Manager']));

DROP POLICY IF EXISTS "View ktv sessions" ON public.ktv_sessions;
DROP POLICY IF EXISTS "Manage ktv sessions" ON public.ktv_sessions;
CREATE POLICY "View ktv sessions" ON public.ktv_sessions FOR SELECT TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Accountant','Manager']));
CREATE POLICY "Manage ktv sessions" ON public.ktv_sessions FOR ALL TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Host','Cashier','Manager']));

DROP POLICY IF EXISTS "View ktv session items" ON public.ktv_session_items;
DROP POLICY IF EXISTS "Manage ktv session items" ON public.ktv_session_items;
CREATE POLICY "View ktv session items" ON public.ktv_session_items FOR SELECT TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Accountant','Manager']));
CREATE POLICY "Manage ktv session items" ON public.ktv_session_items FOR ALL TO authenticated USING (has_any_role(ARRAY['Host','Cashier','Manager'])) WITH CHECK (has_any_role(ARRAY['Host','Cashier','Manager']));
