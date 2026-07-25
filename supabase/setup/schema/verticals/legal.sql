-- =====================================================================
-- KAREYA SILO — VERTICAL: LAW FIRM & PUBLIC NOTARY
-- ---------------------------------------------------------------------
-- A firm runs MATTERS (files). A matter carries DEADLINES (hearings,
-- filings, limitation periods), TIME ENTRIES booked by fee earners, and —
-- for a notary — NOTARIAL ACTS drawn from a single sequential register.
--
-- Two things here are legally load-bearing, not conveniences:
--
--   1. notarial_acts.register_no — civil-law practice requires a
--      sequential, numbered register of every act. The number is issued by
--      a dedicated Postgres SEQUENCE (notarial_register_seq) as the column
--      DEFAULT and is UNIQUE, so a number is NEVER reused, not even after
--      a row is removed. Never assign it from the client.
--
--   2. trust_ledger — money held FOR a client is the CLIENT'S money, not
--      the firm's. It is tracked per client (and optionally per matter)
--      and must never be commingled with firm revenue. `amount` is always
--      positive; `type` sets the direction: a deposit INCREASES what the
--      firm owes the client, while disbursement / transfer_to_fees /
--      refund DECREASE it. A client's running balance must never go
--      negative — that would mean spending another client's money. The
--      application enforces this before every write; the CHECK below
--      guarantees at least that no row can carry a zero or negative
--      amount, which would hide the direction.
--
-- One Silo == one business, so there is NO company_id here — the Silo IS
-- the tenant. Fully idempotent: safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Matters — one client file
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.legal_matters (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  matter_no text,                                -- human-facing file number
  title text NOT NULL,
  client_name text NOT NULL,
  client_phone text,
  client_id_no text,                             -- national ID / passport
  matter_type text,                              -- litigation | conveyancing | corporate | notarial | family | other
  opposing_party text,                           -- drives the conflict-of-interest check
  court text,
  jurisdiction text,
  fee_model text DEFAULT 'hourly'::text,         -- hourly | fixed | contingency | retainer
  hourly_rate numeric DEFAULT 0,
  fixed_fee numeric DEFAULT 0,
  contingency_pct numeric DEFAULT 0,             -- % of recovery
  status text DEFAULT 'prospect'::text,          -- prospect | open | on_hold | closed
  opened_date date DEFAULT CURRENT_DATE,
  closed_date date,
  lead_lawyer_id uuid,
  currency text DEFAULT 'USD'::text,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT legal_matters_pkey PRIMARY KEY (id),
  CONSTRAINT legal_matters_lead_lawyer_id_fkey FOREIGN KEY (lead_lawyer_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT legal_matters_status_check CHECK (status = ANY (ARRAY['prospect','open','on_hold','closed'])),
  CONSTRAINT legal_matters_fee_model_check CHECK (fee_model = ANY (ARRAY['hourly','fixed','contingency','retainer'])),
  CONSTRAINT legal_matters_rates_check CHECK (hourly_rate >= 0 AND fixed_fee >= 0 AND contingency_pct >= 0 AND contingency_pct <= 100)
);

-- ---------------------------------------------------------------------
-- Deadlines — hearings, filings, limitation periods. Missing one is
-- malpractice, so these cascade with their matter and are indexed by date.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.legal_deadlines (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  matter_id uuid NOT NULL,
  title text NOT NULL,
  due_date date NOT NULL,
  type text DEFAULT 'other'::text,               -- court | filing | limitation | meeting | other
  status text DEFAULT 'pending'::text,           -- pending | done | missed
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT legal_deadlines_pkey PRIMARY KEY (id),
  CONSTRAINT legal_deadlines_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES public.legal_matters(id) ON DELETE CASCADE,
  CONSTRAINT legal_deadlines_type_check CHECK (type = ANY (ARRAY['court','filing','limitation','meeting','other'])),
  CONSTRAINT legal_deadlines_status_check CHECK (status = ANY (ARRAY['pending','done','missed']))
);

-- ---------------------------------------------------------------------
-- Time entries — kept separate from project time because a matter's rate
-- varies per fee earner and per matter. `invoiced` is the billing latch:
-- once true the entry has been raised on an invoice and cannot be billed
-- again.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.legal_time_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  matter_id uuid NOT NULL,
  employee_id uuid,                              -- the fee earner
  date date DEFAULT CURRENT_DATE,
  hours numeric DEFAULT 0,
  rate numeric DEFAULT 0,                        -- snapshot of the rate at the time booked
  description text,
  billable boolean DEFAULT true,
  invoiced boolean DEFAULT false,
  invoice_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT legal_time_entries_pkey PRIMARY KEY (id),
  CONSTRAINT legal_time_entries_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES public.legal_matters(id) ON DELETE CASCADE,
  CONSTRAINT legal_time_entries_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT legal_time_entries_hours_check CHECK (hours >= 0),
  CONSTRAINT legal_time_entries_rate_check CHECK (rate >= 0)
);

-- ---------------------------------------------------------------------
-- The notarial register number generator. Sequential, never reused.
-- Created idempotently so re-running this file never resets the register.
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.notarial_register_seq
  AS integer
  START WITH 1
  INCREMENT BY 1
  MINVALUE 1
  NO MAXVALUE
  CACHE 1;

-- ---------------------------------------------------------------------
-- Notarial acts — the register itself. Append-only in practice.
-- register_no is assigned by the sequence above and is UNIQUE, so a number
-- can never be issued twice. matter_id is nullable and ON DELETE SET NULL:
-- an act is a public record in its own right and must survive the deletion
-- of the matter it happened to be filed under.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.notarial_acts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  register_no integer DEFAULT nextval('public.notarial_register_seq'::regclass) NOT NULL,
  act_date date DEFAULT CURRENT_DATE,
  act_type text NOT NULL,                        -- sale deed | power of attorney | affidavit | company formation | certification
  parties text NOT NULL,
  description text,
  fee_charged numeric DEFAULT 0,
  matter_id uuid,
  notary_id uuid,
  document_ref text,                             -- archive / deed reference
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT notarial_acts_pkey PRIMARY KEY (id),
  CONSTRAINT notarial_acts_register_no_key UNIQUE (register_no),
  CONSTRAINT notarial_acts_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES public.legal_matters(id) ON DELETE SET NULL,
  CONSTRAINT notarial_acts_notary_id_fkey FOREIGN KEY (notary_id) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT notarial_acts_register_no_check CHECK (register_no > 0),
  CONSTRAINT notarial_acts_fee_check CHECK (fee_charged >= 0)
);

-- Keep the sequence owned by the column so it is dropped with the table and
-- so \d shows the link. Harmless to re-run.
ALTER SEQUENCE public.notarial_register_seq OWNED BY public.notarial_acts.register_no;

-- ---------------------------------------------------------------------
-- Client trust / escrow ledger — CLIENT money, never firm income.
-- `amount` is always positive and > 0; `type` sets the direction.
-- matter_id is optional (a client may hold funds across several matters)
-- and ON DELETE SET NULL: closing a matter must never erase the audit
-- trail of money held for a client.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trust_ledger (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  matter_id uuid,
  client_name text NOT NULL,
  date date DEFAULT CURRENT_DATE,
  type text NOT NULL,                            -- deposit | disbursement | transfer_to_fees | refund
  amount numeric NOT NULL,                       -- always positive; direction comes from `type`
  reference text,                                -- cheque / transfer reference
  note text,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT trust_ledger_pkey PRIMARY KEY (id),
  CONSTRAINT trust_ledger_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES public.legal_matters(id) ON DELETE SET NULL,
  CONSTRAINT trust_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT trust_ledger_type_check CHECK (type = ANY (ARRAY['deposit','disbursement','transfer_to_fees','refund'])),
  CONSTRAINT trust_ledger_amount_check CHECK (amount > 0)
);

-- ---- indexes ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_legal_matters_status ON public.legal_matters (status);
CREATE INDEX IF NOT EXISTS idx_legal_matters_client_name ON public.legal_matters (client_name);
CREATE INDEX IF NOT EXISTS idx_legal_matters_opposing_party ON public.legal_matters (opposing_party);
CREATE INDEX IF NOT EXISTS idx_legal_matters_lead_lawyer_id ON public.legal_matters (lead_lawyer_id);

CREATE INDEX IF NOT EXISTS idx_legal_deadlines_matter_id ON public.legal_deadlines (matter_id);
CREATE INDEX IF NOT EXISTS idx_legal_deadlines_due_date ON public.legal_deadlines (due_date);
CREATE INDEX IF NOT EXISTS idx_legal_deadlines_status ON public.legal_deadlines (status);

CREATE INDEX IF NOT EXISTS idx_legal_time_entries_matter_id ON public.legal_time_entries (matter_id);
CREATE INDEX IF NOT EXISTS idx_legal_time_entries_employee_id ON public.legal_time_entries (employee_id);
CREATE INDEX IF NOT EXISTS idx_legal_time_entries_date ON public.legal_time_entries (date);
CREATE INDEX IF NOT EXISTS idx_legal_time_entries_invoiced ON public.legal_time_entries (invoiced);

CREATE INDEX IF NOT EXISTS idx_notarial_acts_act_date ON public.notarial_acts (act_date);
CREATE INDEX IF NOT EXISTS idx_notarial_acts_matter_id ON public.notarial_acts (matter_id);
CREATE INDEX IF NOT EXISTS idx_notarial_acts_notary_id ON public.notarial_acts (notary_id);

CREATE INDEX IF NOT EXISTS idx_trust_ledger_client_name ON public.trust_ledger (client_name);
CREATE INDEX IF NOT EXISTS idx_trust_ledger_matter_id ON public.trust_ledger (matter_id);
CREATE INDEX IF NOT EXISTS idx_trust_ledger_date ON public.trust_ledger (date);

-- =====================================================================
-- ROW LEVEL SECURITY
-- Lawyers, Notaries and Paralegals run the files; Managers see and do
-- everything. Accountants can READ (they reconcile the trust account and
-- raise the fee invoices) but must not rewrite the register or the files.
-- =====================================================================
ALTER TABLE public.legal_matters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_deadlines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_time_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notarial_acts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View legal matters" ON public.legal_matters;
CREATE POLICY "View legal matters" ON public.legal_matters FOR SELECT TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager','Accountant']));
DROP POLICY IF EXISTS "Manage legal matters" ON public.legal_matters;
CREATE POLICY "Manage legal matters" ON public.legal_matters FOR ALL TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager'])) WITH CHECK (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager']));

DROP POLICY IF EXISTS "View legal deadlines" ON public.legal_deadlines;
CREATE POLICY "View legal deadlines" ON public.legal_deadlines FOR SELECT TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager','Accountant']));
DROP POLICY IF EXISTS "Manage legal deadlines" ON public.legal_deadlines;
CREATE POLICY "Manage legal deadlines" ON public.legal_deadlines FOR ALL TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager'])) WITH CHECK (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager']));

DROP POLICY IF EXISTS "View legal time entries" ON public.legal_time_entries;
CREATE POLICY "View legal time entries" ON public.legal_time_entries FOR SELECT TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager','Accountant']));
DROP POLICY IF EXISTS "Manage legal time entries" ON public.legal_time_entries;
CREATE POLICY "Manage legal time entries" ON public.legal_time_entries FOR ALL TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager'])) WITH CHECK (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager']));

DROP POLICY IF EXISTS "View notarial acts" ON public.notarial_acts;
CREATE POLICY "View notarial acts" ON public.notarial_acts FOR SELECT TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager','Accountant']));
DROP POLICY IF EXISTS "Manage notarial acts" ON public.notarial_acts;
CREATE POLICY "Manage notarial acts" ON public.notarial_acts FOR ALL TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager'])) WITH CHECK (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager']));

DROP POLICY IF EXISTS "View trust ledger" ON public.trust_ledger;
CREATE POLICY "View trust ledger" ON public.trust_ledger FOR SELECT TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager','Accountant']));
DROP POLICY IF EXISTS "Manage trust ledger" ON public.trust_ledger;
CREATE POLICY "Manage trust ledger" ON public.trust_ledger FOR ALL TO authenticated USING (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager'])) WITH CHECK (has_any_role(ARRAY['Lawyer','Notary','Paralegal','Manager']));
