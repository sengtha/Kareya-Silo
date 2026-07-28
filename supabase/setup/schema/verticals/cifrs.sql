-- =====================================================================
-- KAREYA SILO — CIFRS FOR SMEs CHART MAPPING (cifrs)
-- ---------------------------------------------------------------------
-- The Cambodian National Accounting Council / Accounting and Auditing
-- Regulator publishes a 6-digit chart organised into seven classes.
-- Kareya's working chart is 4-digit and every posting, report and demo
-- depends on it.
--
-- So this is a MAPPING, not a replacement. Each existing account gains a
-- CIFRS code and class; reporting and export can group by class; and the
-- books, the postings and every Silo already running keep working
-- untouched. Nothing here migrates data, which means nothing here can
-- corrupt it, and the whole thing is reversible by clearing a column.
--
-- HONEST LIMIT, worth reading before you rely on it: the seven CLASSES
-- below are the official structure. The individual 6-digit CODES shipped
-- here are a reasonable starting set, NOT a transcription of the official
-- NAC/AAR chart — that document was not available to check against while
-- this was written. Treat the mapping as a first draft for your
-- accountant to correct in Accounting -> Chart of Accounts, not as
-- authority. Everything is editable and every account can be remapped.
--
-- Idempotent: safe to re-run against an existing Silo.
-- Depends on: public.chart_of_accounts, public.has_any_role(text[]),
--             public.is_employee().
-- =====================================================================

-- ---- the seven classes --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cifrs_classes (
  class_no integer NOT NULL,
  name text NOT NULL,
  name_kh text,
  account_type text,                             -- the type most of the class carries
  description text,
  CONSTRAINT cifrs_classes_pkey PRIMARY KEY (class_no),
  CONSTRAINT cifrs_classes_no_check CHECK (class_no BETWEEN 1 AND 7)
);

INSERT INTO public.cifrs_classes (class_no, name, name_kh, account_type, description)
SELECT v.* FROM (VALUES
  (1,'Non-current Assets','ទ្រព្យសកម្មអចិន្ត្រៃយ៍','asset','Land, buildings, plant, vehicles, intangibles and their accumulated depreciation'),
  (2,'Current Assets & Inventory','ទ្រព្យសកម្មចរន្ត និងស្តុក','asset','Inventory, receivables, prepayments, cash and bank'),
  (3,'Equity & Capital','ដើមទុន និងមូលនិធិ','equity','Share capital, reserves and retained earnings'),
  (4,'Liabilities','បំណុល','liability','Payables, taxes, accruals, deposits held and borrowings'),
  (5,'Revenues & Sales','ចំណូល','income','Sales of goods, services rendered and other operating income'),
  (6,'Operating Expenses & Purchases','ចំណាយប្រតិបត្តិការ','expense','Purchases, payroll, occupancy, depreciation and other operating costs'),
  (7,'Financial & Exceptional Items','ចំណេញ/ខាតហិរញ្ញវត្ថុ','expense','Interest, exchange differences and exceptional gains or losses')
) AS v(class_no, name, name_kh, account_type, description)
WHERE NOT EXISTS (SELECT 1 FROM public.cifrs_classes x WHERE x.class_no = v.class_no);

-- ---- reference accounts -------------------------------------------------
-- A starting set within each class. Editable, and extendable: add your own
-- 6-digit codes here and they become available to map against.
CREATE TABLE IF NOT EXISTS public.cifrs_accounts (
  code text NOT NULL,                            -- 6 digits
  class_no integer NOT NULL,
  name text NOT NULL,
  name_kh text,
  account_type text,
  is_standard boolean DEFAULT true,              -- false = added by this business
  CONSTRAINT cifrs_accounts_pkey PRIMARY KEY (code),
  CONSTRAINT cifrs_accounts_class_fkey FOREIGN KEY (class_no) REFERENCES public.cifrs_classes(class_no) ON DELETE RESTRICT,
  CONSTRAINT cifrs_accounts_code_check CHECK (code ~ '^[1-7][0-9]{5}$'),
  -- The first digit must agree with the class, or the code lies about where
  -- it belongs and every class total is wrong.
  CONSTRAINT cifrs_accounts_class_prefix_check CHECK (left(code, 1)::integer = class_no)
);

INSERT INTO public.cifrs_accounts (code, class_no, name, name_kh, account_type)
SELECT v.* FROM (VALUES
  -- 1 non-current assets
  ('110000',1,'Land','ដីធ្លី','asset'),
  ('111000',1,'Buildings and structural improvements','អគារ','asset'),
  ('112000',1,'Plant and machinery','គ្រឿងម៉ាស៊ីន','asset'),
  ('113000',1,'Vehicles','យានយន្ត','asset'),
  ('114000',1,'Office furniture and equipment','សម្ភារៈការិយាល័យ','asset'),
  ('115000',1,'Computer and electronic equipment','កុំព្យូទ័រ','asset'),
  ('116000',1,'Intangible assets and software','ទ្រព្យអរូបី','asset'),
  ('118000',1,'Accumulated depreciation','រំលស់បង្គរ','asset'),
  -- 2 current assets
  ('210000',2,'Inventory','ស្តុក','asset'),
  ('220000',2,'Trade receivables','គណនីត្រូវទទួល','asset'),
  ('230000',2,'Other receivables','ត្រូវទទួលផ្សេងៗ','asset'),
  ('240000',2,'Prepayments and advances','បង់មុន','asset'),
  ('245000',2,'Prepaid tax','ពន្ធបង់មុន','asset'),
  ('250000',2,'Cash on hand','សាច់ប្រាក់','asset'),
  ('251000',2,'Cash at bank','ប្រាក់នៅធនាគារ','asset'),
  -- 3 equity
  ('310000',3,'Share capital','ដើមទុន','equity'),
  ('320000',3,'Retained earnings','ចំណេញរក្សាទុក','equity'),
  ('330000',3,'Reserves','ទុនបំរុង','equity'),
  -- 4 liabilities
  ('410000',4,'Trade payables','គណនីត្រូវបង់','liability'),
  ('420000',4,'Tax payable','ពន្ធត្រូវបង់','liability'),
  ('421000',4,'VAT payable','អតប ត្រូវបង់','liability'),
  ('422000',4,'Withholding tax payable','ពន្ធកាត់ទុកត្រូវបង់','liability'),
  ('423000',4,'NSSF and payroll liabilities','បសស','liability'),
  ('430000',4,'Accrued expenses','ចំណាយបង្គរ','liability'),
  ('440000',4,'Customer deposits held','ប្រាក់កក់អតិថិជន','liability'),
  ('450000',4,'Loans and borrowings','កម្ចី','liability'),
  -- 5 revenue
  ('510000',5,'Sales of goods','លក់ទំនិញ','income'),
  ('520000',5,'Services rendered','សេវាកម្ម','income'),
  ('530000',5,'Other operating income','ចំណូលផ្សេងៗ','income'),
  -- 6 operating expenses
  ('610000',6,'Purchases and cost of goods sold','ថ្លៃដើមទំនិញលក់','expense'),
  ('620000',6,'Salaries, wages and benefits','ប្រាក់បៀវត្ស','expense'),
  ('630000',6,'Rent and occupancy','ថ្លៃជួល','expense'),
  ('640000',6,'Utilities','សាធារណូបភោគ','expense'),
  ('650000',6,'Office and administrative supplies','សម្ភារៈការិយាល័យ','expense'),
  ('660000',6,'Depreciation and amortisation','រំលស់','expense'),
  ('690000',6,'Other operating expenses','ចំណាយប្រតិបត្តិការផ្សេងៗ','expense'),
  -- 7 financial and exceptional
  ('710000',7,'Interest income','ចំណូលការប្រាក់','income'),
  ('720000',7,'Interest expense','ចំណាយការប្រាក់','expense'),
  ('730000',7,'Realized exchange gain/loss','ឈ្នះ/ខាតប្តូរប្រាក់ជាក់ស្តែង','expense'),
  ('740000',7,'Unrealized exchange gain/loss','ឈ្នះ/ខាតប្តូរប្រាក់មិនទាន់កើត','expense'),
  ('790000',7,'Exceptional items','ធាតុពិសេស','expense')
) AS v(code, class_no, name, name_kh, account_type)
WHERE NOT EXISTS (SELECT 1 FROM public.cifrs_accounts x WHERE x.code = v.code);

-- ---- the mapping --------------------------------------------------------
ALTER TABLE public.chart_of_accounts ADD COLUMN IF NOT EXISTS cifrs_code text;
ALTER TABLE public.chart_of_accounts ADD COLUMN IF NOT EXISTS cifrs_class integer;

DO $c$ BEGIN
  ALTER TABLE public.chart_of_accounts ADD CONSTRAINT chart_of_accounts_cifrs_fkey
    FOREIGN KEY (cifrs_code) REFERENCES public.cifrs_accounts(code) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $c$;

CREATE INDEX IF NOT EXISTS idx_chart_of_accounts_cifrs ON public.chart_of_accounts (cifrs_code);
CREATE INDEX IF NOT EXISTS idx_chart_of_accounts_cifrs_class ON public.chart_of_accounts (cifrs_class);

-- Keep the class in step with the code automatically: a mapping whose class
-- disagreed with its code would silently break every class subtotal.
CREATE OR REPLACE FUNCTION public.sync_cifrs_class()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.cifrs_class := CASE WHEN NEW.cifrs_code IS NULL THEN NULL
                          ELSE left(NEW.cifrs_code, 1)::integer END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_cifrs_class ON public.chart_of_accounts;
CREATE TRIGGER trg_sync_cifrs_class
  BEFORE INSERT OR UPDATE OF cifrs_code ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.sync_cifrs_class();

/** Apply the default mapping to any account that has none yet. Never
 *  overwrites a mapping somebody has already set — an accountant's
 *  correction outranks a shipped default. */
DROP FUNCTION IF EXISTS public.map_chart_to_cifrs();
CREATE OR REPLACE FUNCTION public.map_chart_to_cifrs()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mapped integer := 0;
BEGIN
  WITH defaults(code, cifrs) AS (VALUES
    ('1000','250000'), ('1010','251000'), ('1100','220000'), ('1200','210000'),
    ('1210','210000'), ('1300','230000'), ('1310','230000'), ('1500','118000'),
    ('2000','410000'), ('2100','420000'), ('2110','423000'), ('2120','430000'),
    ('2130','410000'), ('2140','440000'), ('2150','430000'),
    ('3000','310000'), ('3100','320000'),
    ('4000','510000'), ('4100','530000'), ('4200','530000'), ('4300','710000'),
    ('5000','610000'), ('5100','620000'), ('5150','620000'), ('5200','630000'),
    ('5250','730000'), ('5260','740000'), ('5300','640000'), ('5400','650000'),
    ('5500','660000'), ('5600','690000'), ('5900','690000')
  )
  UPDATE chart_of_accounts c
     SET cifrs_code = d.cifrs
    FROM defaults d
   WHERE c.code = d.code
     AND c.cifrs_code IS NULL
     AND EXISTS (SELECT 1 FROM cifrs_accounts a WHERE a.code = d.cifrs);
  GET DIAGNOSTICS v_mapped = ROW_COUNT;
  RETURN v_mapped;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.map_chart_to_cifrs() TO authenticated;

/** Trial balance rolled up to CIFRS classes, for the statutory format.
 *  Unmapped accounts are returned under class 0 rather than dropped —
 *  silently omitting them would make the statement balance while hiding
 *  real money. They are listed ONE ROW PER ACCOUNT, not rolled together,
 *  because those rows are the list of work still to do; a single lumped
 *  "Unmapped" line tells you nothing about which account to go and fix. */
DROP FUNCTION IF EXISTS public.cifrs_trial_balance(date, date);
CREATE OR REPLACE FUNCTION public.cifrs_trial_balance(p_from date, p_to date)
 RETURNS TABLE (
   out_class integer, out_class_name text, out_class_name_kh text,
   out_cifrs_code text, out_cifrs_name text,
   out_debit numeric, out_credit numeric, out_balance numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH posted AS (
    SELECT
      COALESCE(c.cifrs_class, 0) AS cls,
      -- Mapped accounts roll up onto their CIFRS code (several Kareya
      -- accounts legitimately share one). Unmapped ones stand alone under
      -- their own account code so you can see which they are.
      CASE WHEN c.cifrs_code IS NULL THEN c.code ELSE c.cifrs_code END AS grp_code,
      CASE WHEN c.cifrs_code IS NULL THEN c.name || ' — not mapped' ELSE ca.name END AS grp_name,
      l.debit, l.credit
    FROM journal_lines l
    JOIN journal_entries e ON e.id = l.entry_id
    JOIN chart_of_accounts c ON c.id = l.account_id
    LEFT JOIN cifrs_accounts ca ON ca.code = c.cifrs_code
    WHERE e.date BETWEEN p_from AND p_to
  )
  SELECT
    p.cls                                     AS out_class,
    COALESCE(cc.name, 'Unmapped')             AS out_class_name,
    cc.name_kh                                AS out_class_name_kh,
    p.grp_code                                AS out_cifrs_code,
    p.grp_name                                AS out_cifrs_name,
    ROUND(SUM(p.debit), 2)                    AS out_debit,
    ROUND(SUM(p.credit), 2)                   AS out_credit,
    ROUND(SUM(p.debit) - SUM(p.credit), 2)    AS out_balance
  FROM posted p
  LEFT JOIN cifrs_classes cc ON cc.class_no = p.cls
  GROUP BY p.cls, cc.name, cc.name_kh, p.grp_code, p.grp_name
  HAVING SUM(p.debit) <> 0 OR SUM(p.credit) <> 0
  ORDER BY p.cls, p.grp_code;
$function$;
GRANT EXECUTE ON FUNCTION public.cifrs_trial_balance(date, date) TO authenticated;

-- ---- row level security -------------------------------------------------
ALTER TABLE public.cifrs_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cifrs_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "View cifrs classes" ON public.cifrs_classes;
DROP POLICY IF EXISTS "Manage cifrs classes" ON public.cifrs_classes;
CREATE POLICY "View cifrs classes" ON public.cifrs_classes FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage cifrs classes" ON public.cifrs_classes FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));

DROP POLICY IF EXISTS "View cifrs accounts" ON public.cifrs_accounts;
DROP POLICY IF EXISTS "Manage cifrs accounts" ON public.cifrs_accounts;
CREATE POLICY "View cifrs accounts" ON public.cifrs_accounts FOR SELECT TO authenticated USING (is_employee());
CREATE POLICY "Manage cifrs accounts" ON public.cifrs_accounts FOR ALL TO authenticated USING (has_any_role(ARRAY['Accountant','Manager'])) WITH CHECK (has_any_role(ARRAY['Accountant','Manager']));
