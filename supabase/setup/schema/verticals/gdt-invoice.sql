-- =====================================================================
-- KAREYA SILO — CAMBODIA GDT TAX INVOICE (gdt-invoice)
-- ---------------------------------------------------------------------
-- What the General Department of Taxation requires of a tax invoice
-- (វិក្កយបត្រពន្ធ), per the Prakas on Tax Invoices / Instruction 1127.
-- Three requirements, and each one forces a design decision that is easy
-- to get wrong in a way that only surfaces during an audit.
--
-- 1. BILINGUAL IDENTITY. Supplier name, address, VATTIN and patent number
--    in Khmer AND English, plus the customer's VATTIN and officially
--    registered name — without which a B2B customer cannot claim input
--    VAT, so an invoice missing it is worthless to them.
--
--    Those customer details are SNAPSHOTTED onto the invoice. A customer
--    who later changes their registered name must not retroactively
--    change what a document issued last year says.
--
-- 2. DUAL CURRENCY AT THE OFFICIAL NBC RATE. Lines may be priced in USD,
--    but subtotal, VAT and total must also appear in riel, converted at
--    the National Bank of Cambodia's official rate.
--
--    The rate is FROZEN onto the invoice. Recomputing riel figures from
--    today's rate would silently restate every historical invoice — the
--    single most audit-visible mistake a system can make here. This is
--    also why the NBC rate lives in its own table and is NOT the
--    fx_rates board, which is a money changer's own buy/sell prices.
--
-- 3. AN UNBROKEN SEQUENTIAL SERIES PER FISCAL YEAR. Numbers are allocated
--    atomically so two users cannot take the same one, and an issued
--    invoice CANNOT BE DELETED — it is voided, keeping its number in the
--    series with a reason and an author. That is enforced by a trigger,
--    because a check in the user interface is not an audit trail.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.invoices, public.clients, public.business_profiles,
--             public.employees, public.has_any_role(text[]), public.is_employee().
-- =====================================================================

-- ---- 1. bilingual identity ---------------------------------------------
ALTER TABLE public.business_profiles ADD COLUMN IF NOT EXISTS name_kh text;
ALTER TABLE public.business_profiles ADD COLUMN IF NOT EXISTS address_kh text;
ALTER TABLE public.business_profiles ADD COLUMN IF NOT EXISTS vattin text;          -- លេខអត្តសញ្ញាណកម្ម អតប
ALTER TABLE public.business_profiles ADD COLUMN IF NOT EXISTS patent_no text;       -- patent tax certificate
ALTER TABLE public.business_profiles ADD COLUMN IF NOT EXISTS patent_year integer;

ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS vattin text;
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS registered_name text;           -- the name on their VAT certificate
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS name_kh text;
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS address_kh text;
ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS address text;

-- ---- 2. the official NBC rate ------------------------------------------
-- One row per date. Deliberately separate from fx_rates: that table is a
-- money changer's own buy/sell board, this is the published official rate
-- and the only one a tax invoice may use.
CREATE TABLE IF NOT EXISTS public.nbc_exchange_rates (
  rate_date date NOT NULL,
  usd_to_khr numeric NOT NULL,
  source text DEFAULT 'manual'::text,            -- manual | nbc | imported
  note text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT nbc_exchange_rates_pkey PRIMARY KEY (rate_date),
  CONSTRAINT nbc_exchange_rates_rate_check CHECK (usd_to_khr > 0),
  CONSTRAINT nbc_exchange_rates_source_check CHECK (source = ANY (ARRAY['manual','nbc','imported']))
);

-- The rate in force on a date: that day's published rate, or the most
-- recent one before it. NBC does not publish at weekends, so an invoice
-- dated Sunday legitimately uses Friday's rate.
CREATE OR REPLACE FUNCTION public.nbc_rate_on(p_date date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT usd_to_khr FROM nbc_exchange_rates
  WHERE rate_date <= p_date
  ORDER BY rate_date DESC
  LIMIT 1;
$function$;

-- ---- 3. the series ------------------------------------------------------
-- One counter per fiscal year per document type, so each year starts at 1
-- and the series within a year is unbroken.
CREATE TABLE IF NOT EXISTS public.invoice_series (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  fiscal_year integer NOT NULL,
  doc_type text DEFAULT 'tax_invoice'::text,     -- tax_invoice | commercial | credit_note | debit_note
  prefix text DEFAULT ''::text,
  next_number integer DEFAULT 1,
  is_active boolean DEFAULT true,
  notes text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT invoice_series_pkey PRIMARY KEY (id),
  CONSTRAINT invoice_series_year_check CHECK (fiscal_year BETWEEN 2000 AND 2200),
  CONSTRAINT invoice_series_next_check CHECK (next_number >= 1),
  CONSTRAINT invoice_series_type_check CHECK (doc_type = ANY (ARRAY['tax_invoice','commercial','credit_note','debit_note']))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_invoice_series ON public.invoice_series (fiscal_year, doc_type);

-- ---- invoice columns ----------------------------------------------------
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS doc_type text DEFAULT 'tax_invoice';
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS fiscal_year integer;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS series_no integer;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS issued boolean DEFAULT false;   -- false = still a draft
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS issued_at timestamp with time zone;
-- Frozen NBC conversion. Never recompute these from a current rate.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS nbc_rate numeric;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS khr_subtotal numeric;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS khr_tax numeric;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS khr_total numeric;
-- Customer identity as it stood when the document was issued.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS customer_name_snapshot text;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS customer_vattin_snapshot text;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS customer_address_snapshot text;
-- Void, which replaces deletion.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS voided boolean DEFAULT false;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS void_reason text;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS voided_at timestamp with time zone;
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS voided_by uuid;

DO $c$ BEGIN
  ALTER TABLE public.invoices ADD CONSTRAINT invoices_doc_type_check
    CHECK (doc_type = ANY (ARRAY['tax_invoice','commercial','credit_note','debit_note']));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

DO $c$ BEGIN
  ALTER TABLE public.invoices ADD CONSTRAINT invoices_khr_check
    CHECK ((nbc_rate IS NULL OR nbc_rate > 0)
       AND (khr_subtotal IS NULL OR khr_subtotal >= 0)
       AND (khr_tax IS NULL OR khr_tax >= 0)
       AND (khr_total IS NULL OR khr_total >= 0));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- A void must say why. "Voided, reason unknown" is not an audit trail.
DO $c$ BEGIN
  ALTER TABLE public.invoices ADD CONSTRAINT invoices_void_reason_check
    CHECK (voided = false OR (void_reason IS NOT NULL AND btrim(void_reason) <> ''));
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

-- Within a fiscal year and document type, a series number is used once.
CREATE UNIQUE INDEX IF NOT EXISTS uq_invoices_series_no
  ON public.invoices (fiscal_year, doc_type, series_no)
  WHERE series_no IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_fiscal_year ON public.invoices (fiscal_year);
CREATE INDEX IF NOT EXISTS idx_invoices_issued ON public.invoices (issued);

-- ---- issuing ------------------------------------------------------------
-- Allocates the next number atomically. UPDATE ... RETURNING takes a row
-- lock, so two cashiers pressing Issue at the same instant get different
-- numbers instead of a duplicate or a gap.
-- Dropped first: CREATE OR REPLACE cannot change a function's return type,
-- so a signature change would otherwise make this file fail on re-run.
DROP FUNCTION IF EXISTS public.issue_invoice(uuid, text, numeric);
CREATE OR REPLACE FUNCTION public.issue_invoice(
  p_invoice_id uuid,
  p_doc_type text DEFAULT 'tax_invoice',
  p_nbc_rate numeric DEFAULT NULL
)
 -- OUT names are prefixed: inside PL/pgSQL an output column shadows a table
 -- column of the same name, and "fiscal_year" would be ambiguous everywhere.
 RETURNS TABLE (out_invoice_number text, out_fiscal_year integer, out_series_no integer, out_nbc_rate numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_inv        invoices%ROWTYPE;
  v_year       integer;
  v_next       integer;
  v_prefix     text;
  v_rate       numeric;
  v_client     clients%ROWTYPE;
  v_net        numeric;
  v_tax        numeric;
  v_number     text;
BEGIN
  SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found'; END IF;
  IF v_inv.issued THEN RAISE EXCEPTION 'Invoice % has already been issued', v_inv.invoice_number; END IF;

  v_year := EXTRACT(YEAR FROM COALESCE(v_inv.date, CURRENT_DATE))::integer;

  -- The rate must exist. Issuing without one would produce a document that
  -- cannot show riel, which is not a valid tax invoice.
  v_rate := COALESCE(p_nbc_rate, nbc_rate_on(COALESCE(v_inv.date, CURRENT_DATE)));
  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION 'No official NBC rate is on record for % — add one before issuing', COALESCE(v_inv.date, CURRENT_DATE);
  END IF;

  INSERT INTO invoice_series (fiscal_year, doc_type)
  VALUES (v_year, p_doc_type)
  ON CONFLICT (fiscal_year, doc_type) DO NOTHING;

  UPDATE invoice_series
     SET next_number = next_number + 1
   WHERE fiscal_year = v_year AND doc_type = p_doc_type
  RETURNING next_number - 1, prefix INTO v_next, v_prefix;

  -- amount is the net of lines less discount; tax_rate is a percentage.
  v_net := COALESCE(v_inv.amount, 0);
  v_tax := ROUND(v_net * COALESCE(v_inv.tax_rate, 0) / 100.0, 2);

  SELECT * INTO v_client FROM clients WHERE id = v_inv.client_id;

  v_number := COALESCE(NULLIF(v_prefix, ''), '') || v_year::text || '-' || LPAD(v_next::text, 5, '0');

  UPDATE invoices SET
    doc_type      = p_doc_type,
    fiscal_year   = v_year,
    series_no     = v_next,
    invoice_number= v_number,
    issued        = true,
    issued_at     = now(),
    nbc_rate      = v_rate,
    khr_subtotal  = ROUND(v_net * v_rate, 0),
    khr_tax       = ROUND(v_tax * v_rate, 0),
    khr_total     = ROUND((v_net + v_tax) * v_rate, 0),
    customer_name_snapshot    = COALESCE(v_client.registered_name, v_client.company_name, v_client.name),
    customer_vattin_snapshot  = v_client.vattin,
    customer_address_snapshot = COALESCE(v_client.address, v_client.address_kh)
  WHERE id = p_invoice_id;

  RETURN QUERY SELECT v_number, v_year, v_next, v_rate;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.nbc_rate_on(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.issue_invoice(uuid, text, numeric) TO authenticated;

-- ---- deletion is not allowed ------------------------------------------
-- The compliance guarantee. A UI that hides the delete button is not an
-- audit trail; a trigger is. Drafts may still be discarded — they never
-- consumed a number.
CREATE OR REPLACE FUNCTION public.prevent_issued_invoice_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.issued THEN
    RAISE EXCEPTION
      'Invoice % has been issued and cannot be deleted. Void it instead, so its number stays in the series.',
      OLD.invoice_number
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_prevent_issued_invoice_delete ON public.invoices;
CREATE TRIGGER trg_prevent_issued_invoice_delete
  BEFORE DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.prevent_issued_invoice_delete();

-- Nor may an issued invoice be quietly rewritten. The figures that make it a
-- tax document are frozen; a mistake is corrected by voiding and reissuing,
-- or by a credit note.
CREATE OR REPLACE FUNCTION public.protect_issued_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.issued AND NOT OLD.voided THEN
    IF NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
       OR NEW.series_no   IS DISTINCT FROM OLD.series_no
       OR NEW.fiscal_year IS DISTINCT FROM OLD.fiscal_year
       OR NEW.amount      IS DISTINCT FROM OLD.amount
       OR NEW.tax_rate    IS DISTINCT FROM OLD.tax_rate
       OR NEW.date        IS DISTINCT FROM OLD.date
       OR NEW.nbc_rate    IS DISTINCT FROM OLD.nbc_rate THEN
      RAISE EXCEPTION
        'Invoice % is issued. Its number, date, amounts and NBC rate cannot change — void it and reissue, or raise a credit note.',
        OLD.invoice_number
        USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_protect_issued_invoice ON public.invoices;
CREATE TRIGGER trg_protect_issued_invoice
  BEFORE UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.protect_issued_invoice();

-- ---- row level security -------------------------------------------------
ALTER TABLE public.nbc_exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_series ENABLE ROW LEVEL SECURITY;

-- Any employee may read the rate — it appears on documents they handle.
-- Only accounting may set it, since it decides what every invoice says.
DROP POLICY IF EXISTS "View nbc rates" ON public.nbc_exchange_rates;
DROP POLICY IF EXISTS "Manage nbc rates" ON public.nbc_exchange_rates;
CREATE POLICY "View nbc rates" ON public.nbc_exchange_rates FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage nbc rates" ON public.nbc_exchange_rates FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View invoice series" ON public.invoice_series;
DROP POLICY IF EXISTS "Manage invoice series" ON public.invoice_series;
CREATE POLICY "View invoice series" ON public.invoice_series FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage invoice series" ON public.invoice_series FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
