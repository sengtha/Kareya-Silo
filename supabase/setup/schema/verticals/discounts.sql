-- =====================================================================
-- KAREYA SILO — DISCOUNTS, ONCE, FOR EVERY MODULE
-- ---------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- There were five `discount numeric DEFAULT 0` columns — on invoices, on
-- quotes, on recurring invoices, on pharmacy sales, on retail sales — and
-- each one held a lump somebody had typed into a browser. Nothing else.
--
-- No rule said what the discount was FOR. A 20% off a bill and a 20% off
-- one line and a staff price and a Khmer New Year promotion were the same
-- untyped number, so none of them could be reported, reused, limited or
-- withdrawn. Nothing recorded who gave it or why. Nothing stopped two
-- discounts from stacking to more than the margin. And a cashier could
-- give away the shop one keystroke at a time with no trace.
--
-- WHAT THIS ADDS
--
-- One rule table, one evaluator and one append-only ledger, usable by any
-- module. A module asks what discounts apply to a set of facts, and gets
-- back the rules that qualify with the money each is worth. It then
-- records what it actually gave.
--
-- THE PARTS THAT ARE EASY TO GET WRONG, AND HOW THEY ARE DECIDED HERE
--
-- STACKING. Two 20% discounts are either 36% (each applied to what is
-- left) or 40% (each applied to the original). Both are defensible and
-- they are not the same money, so the choice is a setting rather than an
-- accident: `combine_mode` is 'sequential' or 'additive', set once and
-- overridable per rule.
--
-- EXCLUSIVITY. A rule marked exclusive cannot be combined. It does NOT
-- automatically win: the evaluator works out the best exclusive rule and
-- the best stack of non-exclusive ones, and takes whichever is larger.
-- Anything else quietly charges a customer more because of how a
-- promotion happened to be flagged.
--
-- A CEILING. `max_total_percent` caps everything, however the rules
-- combine. A promotion nobody capped is how a business discovers in
-- February what it gave away in January.
--
-- PASS-THROUGH MONEY IS NOT YOURS TO DISCOUNT. A freight disbursement is
-- a duty fronted for the client and recharged at cost; discounting it
-- means paying somebody's customs bill out of your own margin. Rules
-- default to `applies_to_disbursements = false`.
--
-- TAX. This works on the net amount only. VAT is computed on what is left
-- AFTER the discount, never before, so the caller applies its tax to the
-- figure this returns. Doing it the other way round overstates the tax
-- and is wrong on a GDT invoice.
--
-- HISTORY. A rule edited in June must not rewrite a discount given in
-- March, so every application stores its own copy of the code, name,
-- method and value.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--
-- It ships no discounts. Not one percentage, threshold, happy hour or
-- season. What a business gives away is a commercial decision, and a
-- default here would quietly become somebody's pricing policy.
--
-- Idempotent. Apply after the base schema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. HOUSE RULES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discount_settings (
  id                  boolean DEFAULT true NOT NULL,
  -- 'sequential' — each discount applies to what the one before it left.
  -- 'additive'   — each applies to the original amount.
  combine_mode        text DEFAULT 'sequential' NOT NULL,
  max_total_percent   numeric DEFAULT 100 NOT NULL,
  -- Happy hour is a wall-clock idea, so it needs a wall clock.
  timezone            text DEFAULT 'Asia/Phnom_Penh' NOT NULL,
  -- Above this, somebody has to say why in writing.
  reason_required_over_percent numeric DEFAULT 100 NOT NULL,
  CONSTRAINT discount_settings_pkey PRIMARY KEY (id),
  CONSTRAINT discount_settings_singleton CHECK (id = true),
  CONSTRAINT discount_settings_mode_check CHECK (combine_mode = ANY (ARRAY['sequential','additive'])),
  CONSTRAINT discount_settings_max_check CHECK (max_total_percent >= 0 AND max_total_percent <= 100)
);
INSERT INTO public.discount_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. THE RULES
-- Every condition is optional and they are ALL AND-ed. A rule with no
-- conditions applies to everything, which is what an across-the-board
-- sale is.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discount_rules (
  id            uuid DEFAULT gen_random_uuid() NOT NULL,
  code          text NOT NULL,
  name          text NOT NULL,
  description   text,

  -- Which modules may use it. NULL or empty = anywhere.
  modules       text[],
  applies_to    text DEFAULT 'document' NOT NULL,   -- line | document
  trigger       text DEFAULT 'automatic' NOT NULL,  -- automatic | code
  method        text DEFAULT 'percent' NOT NULL,    -- percent | amount | fixed_price | free_items
  value         numeric DEFAULT 0 NOT NULL,

  -- ---- conditions ----
  min_quantity  numeric,                 -- quantity break; also the "buy N" of free_items
  max_quantity  numeric,
  min_amount    numeric,                 -- spend threshold
  category      text,                    -- item category or service type
  valid_from    date,                    -- season
  valid_to      date,
  days_of_week  integer[],               -- 0 = Sunday … 6 = Saturday
  start_time    time,                    -- time sale / happy hour
  end_time      time,
  customer_tier text,                    -- member tier
  min_prior_purchases integer,           -- the repeat customer
  first_purchase_only boolean DEFAULT false,
  payment_method text,                   -- e.g. a cash price

  -- ---- governance ----
  priority      integer DEFAULT 100 NOT NULL,   -- lower applies first
  exclusive     boolean DEFAULT false,          -- cannot be combined with anything
  combine_mode  text,                           -- overrides the house setting
  max_discount_amount numeric,                  -- this rule's own ceiling
  requires_approval boolean DEFAULT false,
  approval_role text,
  max_redemptions integer,                      -- across the whole business
  max_per_customer integer,
  redemption_count integer DEFAULT 0 NOT NULL,
  applies_to_disbursements boolean DEFAULT false,

  is_active     boolean DEFAULT true,
  notes         text,
  created_at    timestamp with time zone DEFAULT now(),
  CONSTRAINT discount_rules_pkey PRIMARY KEY (id),
  CONSTRAINT discount_rules_code_key UNIQUE (code),
  CONSTRAINT discount_rules_applies_check CHECK (applies_to = ANY (ARRAY['line','document'])),
  CONSTRAINT discount_rules_trigger_check CHECK (trigger = ANY (ARRAY['automatic','code'])),
  CONSTRAINT discount_rules_method_check
    CHECK (method = ANY (ARRAY['percent','amount','fixed_price','free_items'])),
  CONSTRAINT discount_rules_mode_check
    CHECK (combine_mode IS NULL OR combine_mode = ANY (ARRAY['sequential','additive'])),
  CONSTRAINT discount_rules_value_check CHECK (value >= 0),
  -- A percentage over a hundred is not a discount, it is a gift with change.
  CONSTRAINT discount_rules_percent_check
    CHECK (method <> 'percent' OR value <= 100),
  CONSTRAINT discount_rules_validity_check CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
  CONSTRAINT discount_rules_window_check CHECK (end_time IS NULL OR start_time IS NULL OR end_time > start_time),
  -- Free goods need to know how many buy how many.
  CONSTRAINT discount_rules_free_check
    CHECK (method <> 'free_items' OR (coalesce(min_quantity, 0) > 0 AND value > 0))
);

COMMENT ON TABLE public.discount_rules IS
  'Kareya ships no discounts. What a business gives away is a commercial decision.';
COMMENT ON COLUMN public.discount_rules.value IS
  'percent: a percentage. amount: money off. fixed_price: the price each unit is sold at. free_items: how many are free for every min_quantity paid for.';

CREATE INDEX IF NOT EXISTS idx_discount_rules_active ON public.discount_rules (is_active, priority);

-- ---- individually issued codes ---------------------------------------
-- A rule with trigger 'code' can be quoted by anybody who knows the code.
-- A coupon is narrower: one code, optionally for one customer, with its
-- own expiry and its own use count.
CREATE TABLE IF NOT EXISTS public.discount_coupons (
  id           uuid DEFAULT gen_random_uuid() NOT NULL,
  code         text NOT NULL,
  rule_id      uuid NOT NULL,
  customer_ref text,                     -- whoever it was issued to, in the module's own terms
  issued_on    date DEFAULT CURRENT_DATE,
  expires_on   date,
  max_uses     integer DEFAULT 1,
  used_count   integer DEFAULT 0 NOT NULL,
  is_void      boolean DEFAULT false,
  void_reason  text,
  notes        text,
  created_at   timestamp with time zone DEFAULT now(),
  CONSTRAINT discount_coupons_pkey PRIMARY KEY (id),
  CONSTRAINT discount_coupons_code_key UNIQUE (code),
  CONSTRAINT discount_coupons_rule_fkey FOREIGN KEY (rule_id)
    REFERENCES public.discount_rules(id) ON DELETE CASCADE,
  CONSTRAINT discount_coupons_uses_check CHECK (max_uses IS NULL OR max_uses > 0)
);

CREATE INDEX IF NOT EXISTS idx_discount_coupons_rule ON public.discount_coupons (rule_id);

-- ---------------------------------------------------------------------
-- 3. THE LEDGER
-- What was actually given, to what, by whom and why. Append-only, with
-- the rule's terms copied in so editing the rule later cannot rewrite
-- what somebody was charged.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.discount_applications (
  id             uuid DEFAULT gen_random_uuid() NOT NULL,
  module         text NOT NULL,               -- pos | retail | invoice | tour | event | ...
  document_type  text,                        -- invoice | sale | booking | quote | ...
  document_id    uuid,
  line_ref       text,                        -- which line, in the module's own terms

  rule_id        uuid,                        -- NULL for a discount somebody just decided to give
  code           text,                        -- copies, so history survives a rule being edited
  name           text,
  method         text,
  value          numeric,

  base_amount    numeric DEFAULT 0 NOT NULL,  -- what it was worked out on
  discount_amount numeric DEFAULT 0 NOT NULL,
  is_manual      boolean DEFAULT false,
  customer_ref   text,                        -- who it was given to, in the module's own terms
  reason         text,
  applied_by     uuid,
  approved_by    uuid,
  floor_breached boolean DEFAULT false,       -- it went below the caller's stated floor
  applied_at     timestamp with time zone DEFAULT now(),
  voided         boolean DEFAULT false,
  void_reason    text,
  CONSTRAINT discount_applications_pkey PRIMARY KEY (id),
  CONSTRAINT discount_applications_rule_fkey FOREIGN KEY (rule_id)
    REFERENCES public.discount_rules(id) ON DELETE SET NULL,
  CONSTRAINT discount_applications_by_fkey FOREIGN KEY (applied_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT discount_applications_approved_fkey FOREIGN KEY (approved_by)
    REFERENCES public.employees(id) ON DELETE SET NULL,
  CONSTRAINT discount_applications_amount_check CHECK (discount_amount >= 0)
);

CREATE INDEX IF NOT EXISTS idx_discount_applications_doc
  ON public.discount_applications (module, document_id);
CREATE INDEX IF NOT EXISTS idx_discount_applications_rule
  ON public.discount_applications (rule_id);
CREATE INDEX IF NOT EXISTS idx_discount_applications_at
  ON public.discount_applications (applied_at);

CREATE OR REPLACE FUNCTION public.discount_application_is_a_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A discount cannot be deleted. Void it, which leaves the record and the reason.';
  END IF;
  IF OLD.discount_amount IS DISTINCT FROM NEW.discount_amount
     OR OLD.base_amount IS DISTINCT FROM NEW.base_amount
     OR OLD.document_id IS DISTINCT FROM NEW.document_id THEN
    RAISE EXCEPTION 'A discount cannot be rewritten. Void it and give a new one.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_discount_application_is_a_record ON public.discount_applications;
CREATE TRIGGER trg_discount_application_is_a_record
  BEFORE UPDATE OR DELETE ON public.discount_applications
  FOR EACH ROW EXECUTE FUNCTION public.discount_application_is_a_record();

-- ---------------------------------------------------------------------
-- 4. DOES THIS RULE APPLY?
-- Every condition is optional; a NULL condition is not a condition.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discount_rule_qualifies(
  p_rule           discount_rules,
  p_module         text,
  p_gross          numeric,
  p_quantity       numeric,
  p_at             timestamp with time zone,
  p_customer_tier  text,
  p_prior_purchases integer,
  p_payment_method text,
  p_category       text,
  p_coupon_code    text,
  p_is_disbursement boolean,
  p_customer_ref   text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_tz text; v_local timestamp; v_used integer;
BEGIN
  IF NOT coalesce(p_rule.is_active, false) THEN RETURN false; END IF;

  -- Pass-through money is not the business's to give away.
  IF p_is_disbursement AND NOT coalesce(p_rule.applies_to_disbursements, false) THEN
    RETURN false;
  END IF;

  IF p_rule.modules IS NOT NULL AND array_length(p_rule.modules, 1) > 0
     AND NOT (p_module = ANY (p_rule.modules)) THEN
    RETURN false;
  END IF;

  -- A rule that has to be asked for is not given away by accident.
  IF p_rule.trigger = 'code' AND coalesce(upper(p_coupon_code), '') <> upper(p_rule.code) THEN
    RETURN false;
  END IF;

  IF p_rule.min_quantity IS NOT NULL AND coalesce(p_quantity, 0) < p_rule.min_quantity THEN RETURN false; END IF;
  IF p_rule.max_quantity IS NOT NULL AND coalesce(p_quantity, 0) > p_rule.max_quantity THEN RETURN false; END IF;
  IF p_rule.min_amount IS NOT NULL AND coalesce(p_gross, 0) < p_rule.min_amount THEN RETURN false; END IF;
  IF p_rule.category IS NOT NULL AND coalesce(p_category, '') <> p_rule.category THEN RETURN false; END IF;
  IF p_rule.customer_tier IS NOT NULL
     AND lower(coalesce(p_customer_tier, '')) <> lower(p_rule.customer_tier) THEN RETURN false; END IF;
  IF p_rule.payment_method IS NOT NULL
     AND lower(coalesce(p_payment_method, '')) <> lower(p_rule.payment_method) THEN RETURN false; END IF;

  IF p_rule.min_prior_purchases IS NOT NULL
     AND coalesce(p_prior_purchases, 0) < p_rule.min_prior_purchases THEN RETURN false; END IF;
  IF coalesce(p_rule.first_purchase_only, false) AND coalesce(p_prior_purchases, 0) > 0 THEN
    RETURN false;
  END IF;

  -- Dates and clock times are read in the business's own timezone,
  -- because happy hour is a wall-clock idea.
  SELECT timezone INTO v_tz FROM discount_settings WHERE id;
  v_local := p_at AT TIME ZONE coalesce(v_tz, 'UTC');

  IF p_rule.valid_from IS NOT NULL AND v_local::date < p_rule.valid_from THEN RETURN false; END IF;
  IF p_rule.valid_to IS NOT NULL AND v_local::date > p_rule.valid_to THEN RETURN false; END IF;

  IF p_rule.days_of_week IS NOT NULL AND array_length(p_rule.days_of_week, 1) > 0
     AND NOT (extract(dow FROM v_local)::integer = ANY (p_rule.days_of_week)) THEN
    RETURN false;
  END IF;
  IF p_rule.start_time IS NOT NULL AND v_local::time < p_rule.start_time THEN RETURN false; END IF;
  IF p_rule.end_time IS NOT NULL AND v_local::time > p_rule.end_time THEN RETURN false; END IF;

  -- A promotion nobody capped is how a business finds out in February
  -- what it gave away in January.
  IF p_rule.max_redemptions IS NOT NULL
     AND coalesce(p_rule.redemption_count, 0) >= p_rule.max_redemptions THEN
    RETURN false;
  END IF;
  -- Per-customer counting needs the module to pass a customer reference,
  -- and apply_discount stamps that same reference onto the ledger row.
  -- Without one there is nothing to count and the limit cannot bite.
  IF p_rule.max_per_customer IS NOT NULL AND coalesce(p_customer_ref, '') <> '' THEN
    SELECT count(*) INTO v_used FROM discount_applications a
     WHERE a.rule_id = p_rule.id AND NOT a.voided
       AND a.customer_ref = p_customer_ref;
    IF v_used >= p_rule.max_per_customer THEN RETURN false; END IF;
  END IF;

  RETURN true;
END;
$$;

-- What one rule is worth on this amount.
CREATE OR REPLACE FUNCTION public.discount_rule_amount(
  p_rule discount_rules, p_base numeric, p_quantity numeric, p_unit_price numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $$
DECLARE v numeric;
BEGIN
  v := CASE p_rule.method
    WHEN 'percent' THEN coalesce(p_base, 0) * p_rule.value / 100.0
    WHEN 'amount'  THEN p_rule.value
    -- Sold at a fixed price each. Never a surcharge: if the fixed price is
    -- higher than what is being charged, the discount is nothing.
    WHEN 'fixed_price' THEN
      greatest(coalesce(p_base, 0) - p_rule.value * coalesce(p_quantity, 0), 0)
    -- `value` free for every `min_quantity` PAID FOR. Buy three get one
    -- free on ten items is three free, not two.
    WHEN 'free_items' THEN
      floor(coalesce(p_quantity, 0) / p_rule.min_quantity) * p_rule.value
        * coalesce(p_unit_price, 0)
    ELSE 0
  END;

  IF p_rule.max_discount_amount IS NOT NULL THEN
    v := least(v, p_rule.max_discount_amount);
  END IF;
  -- Never more than the thing costs.
  RETURN round(least(greatest(v, 0), greatest(coalesce(p_base, 0), 0)), 4);
END;
$$;

-- ---------------------------------------------------------------------
-- 5. THE EVALUATOR
-- The one call every module makes. Returns the rules that qualify, in the
-- order they apply, with the money each is worth.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.evaluate_discounts(text, numeric, numeric, numeric, timestamp with time zone, text, integer, text, text, text, boolean, text);
CREATE OR REPLACE FUNCTION public.evaluate_discounts(
  p_module          text,
  p_gross           numeric,
  p_quantity        numeric DEFAULT 1,
  p_unit_price      numeric DEFAULT NULL,
  p_at              timestamp with time zone DEFAULT now(),
  p_customer_tier   text DEFAULT NULL,
  p_prior_purchases integer DEFAULT 0,
  p_payment_method  text DEFAULT NULL,
  p_category        text DEFAULT NULL,
  p_coupon_code     text DEFAULT NULL,
  p_is_disbursement boolean DEFAULT false,
  p_customer_ref    text DEFAULT NULL)
 RETURNS TABLE (
   out_rule_id  uuid,
   out_code     text,
   out_name     text,
   out_method   text,
   out_value    numeric,
   out_base     numeric,   -- what this rule was worked out on
   out_amount   numeric,
   out_order    integer,
   out_capped   boolean    -- the house ceiling cut it short
 )
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $$
DECLARE
  v_s discount_settings;
  r discount_rules;
  v_mode text;
  v_running numeric;          -- what is left, for sequential
  v_total numeric := 0;
  v_ceiling numeric;
  v_amt numeric;
  v_base numeric;
  v_i integer := 0;
  v_best_excl discount_rules;
  v_best_excl_amt numeric := 0;
  v_stack_total numeric := 0;
BEGIN
  IF coalesce(p_gross, 0) <= 0 THEN RETURN; END IF;
  SELECT * INTO v_s FROM discount_settings WHERE id;
  v_ceiling := coalesce(p_gross, 0) * coalesce(v_s.max_total_percent, 100) / 100.0;

  -- ---- pass one: the best exclusive rule, and the stack it competes with
  FOR r IN
    SELECT * FROM discount_rules
     WHERE is_active
     ORDER BY priority, code
  LOOP
    IF NOT discount_rule_qualifies(r, p_module, p_gross, p_quantity, p_at,
                                   p_customer_tier, p_prior_purchases, p_payment_method,
                                   p_category, p_coupon_code, p_is_disbursement, p_customer_ref) THEN
      CONTINUE;
    END IF;

    IF r.exclusive THEN
      v_amt := discount_rule_amount(r, p_gross, p_quantity, p_unit_price);
      IF v_amt > v_best_excl_amt THEN v_best_excl := r; v_best_excl_amt := v_amt; END IF;
    ELSE
      v_mode := coalesce(r.combine_mode, v_s.combine_mode, 'sequential');
      v_base := CASE WHEN v_mode = 'additive' THEN p_gross
                     ELSE greatest(p_gross - v_stack_total, 0) END;
      v_stack_total := v_stack_total + discount_rule_amount(r, v_base, p_quantity, p_unit_price);
    END IF;
  END LOOP;

  v_stack_total := least(v_stack_total, v_ceiling);
  v_best_excl_amt := least(v_best_excl_amt, v_ceiling);

  -- An exclusive rule cannot be combined, but it does not automatically
  -- win. Whichever leaves the customer better off is the one that applies.
  IF v_best_excl.id IS NOT NULL AND v_best_excl_amt >= v_stack_total THEN
    out_rule_id := v_best_excl.id; out_code := v_best_excl.code;
    out_name := v_best_excl.name; out_method := v_best_excl.method;
    out_value := v_best_excl.value; out_base := round(p_gross, 4);
    out_amount := round(v_best_excl_amt, 4); out_order := 1;
    out_capped := v_best_excl_amt >= v_ceiling
                  AND discount_rule_amount(v_best_excl, p_gross, p_quantity, p_unit_price) > v_ceiling;
    RETURN NEXT;
    RETURN;
  END IF;

  -- ---- pass two: emit the stack, in the order it applies
  v_running := p_gross;
  FOR r IN
    SELECT * FROM discount_rules
     WHERE is_active AND NOT exclusive
     ORDER BY priority, code
  LOOP
    IF NOT discount_rule_qualifies(r, p_module, p_gross, p_quantity, p_at,
                                   p_customer_tier, p_prior_purchases, p_payment_method,
                                   p_category, p_coupon_code, p_is_disbursement, p_customer_ref) THEN
      CONTINUE;
    END IF;

    v_mode := coalesce(r.combine_mode, v_s.combine_mode, 'sequential');
    v_base := CASE WHEN v_mode = 'additive' THEN p_gross ELSE greatest(v_running, 0) END;
    v_amt  := discount_rule_amount(r, v_base, p_quantity, p_unit_price);

    -- The house ceiling bites here, on whatever is left of it.
    IF v_total + v_amt > v_ceiling THEN
      out_capped := true;
      v_amt := greatest(v_ceiling - v_total, 0);
    ELSE
      out_capped := false;
    END IF;
    IF v_amt <= 0 THEN CONTINUE; END IF;

    v_i := v_i + 1;
    v_total := v_total + v_amt;
    v_running := v_running - v_amt;

    out_rule_id := r.id; out_code := r.code; out_name := r.name;
    out_method := r.method; out_value := r.value;
    out_base := round(v_base, 4); out_amount := round(v_amt, 4); out_order := v_i;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- The single figure most callers actually want.
CREATE OR REPLACE FUNCTION public.total_discount(
  p_module          text,
  p_gross           numeric,
  p_quantity        numeric DEFAULT 1,
  p_unit_price      numeric DEFAULT NULL,
  p_at              timestamp with time zone DEFAULT now(),
  p_customer_tier   text DEFAULT NULL,
  p_prior_purchases integer DEFAULT 0,
  p_payment_method  text DEFAULT NULL,
  p_category        text DEFAULT NULL,
  p_coupon_code     text DEFAULT NULL,
  p_is_disbursement boolean DEFAULT false,
  p_customer_ref    text DEFAULT NULL)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT coalesce(sum(out_amount), 0) FROM evaluate_discounts(
    p_module, p_gross, p_quantity, p_unit_price, p_at, p_customer_tier,
    p_prior_purchases, p_payment_method, p_category, p_coupon_code,
    p_is_disbursement, p_customer_ref);
$$;

-- ---------------------------------------------------------------------
-- 6. GIVING ONE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_discount(
  p_module        text,
  p_document_type text,
  p_document_id   uuid,
  p_base_amount   numeric,
  p_discount_amount numeric,
  p_rule_id       uuid DEFAULT NULL,
  p_reason        text DEFAULT NULL,
  p_line_ref      text DEFAULT NULL,
  p_floor         numeric DEFAULT NULL,   -- the lowest net the caller will accept
  p_customer_ref  text DEFAULT NULL)
 RETURNS discount_applications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_r discount_rules; v_s discount_settings; v_a discount_applications;
  v_me uuid; v_pct numeric; v_manual boolean; v_breach boolean := false;
BEGIN
  IF coalesce(p_discount_amount, 0) < 0 THEN
    RAISE EXCEPTION 'A discount cannot be negative. That is a surcharge, and it needs its own line.';
  END IF;
  IF coalesce(p_discount_amount, 0) > coalesce(p_base_amount, 0) THEN
    RAISE EXCEPTION 'A discount of % is more than the % it is taken off.',
      round(p_discount_amount, 2), round(coalesce(p_base_amount, 0), 2);
  END IF;

  SELECT * INTO v_s FROM discount_settings WHERE id;
  v_manual := p_rule_id IS NULL;
  v_pct := CASE WHEN coalesce(p_base_amount, 0) = 0 THEN 0
                ELSE 100 * p_discount_amount / p_base_amount END;

  IF p_rule_id IS NOT NULL THEN
    SELECT * INTO v_r FROM discount_rules WHERE id = p_rule_id FOR UPDATE;
    IF v_r.id IS NULL THEN RAISE EXCEPTION 'That discount rule does not exist'; END IF;
    IF NOT v_r.is_active THEN RAISE EXCEPTION 'The rule "%" has been withdrawn.', v_r.name; END IF;
    IF v_r.max_redemptions IS NOT NULL AND v_r.redemption_count >= v_r.max_redemptions THEN
      RAISE EXCEPTION 'The rule "%" has been used its full % times.', v_r.name, v_r.max_redemptions;
    END IF;
    IF v_r.requires_approval AND coalesce(v_r.approval_role, '') <> ''
       AND NOT has_any_role(ARRAY[v_r.approval_role]) THEN
      RAISE EXCEPTION 'A % discount needs a %.', v_r.name, v_r.approval_role;
    END IF;
  END IF;

  -- A discount somebody just decided to give is exactly where margin
  -- leaks, so it always says why.
  IF v_manual AND coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A discount given outside the rules needs a reason.';
  END IF;
  IF v_pct > coalesce(v_s.reason_required_over_percent, 100)
     AND coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A discount of % percent needs a reason in writing.', round(v_pct, 1);
  END IF;

  -- The floor is the caller's own: what it costs, or the least it will
  -- take. Discounting through it is the commonest way to sell at a loss.
  IF p_floor IS NOT NULL AND (coalesce(p_base_amount, 0) - p_discount_amount) < p_floor THEN
    IF coalesce(trim(p_reason), '') = '' THEN
      RAISE EXCEPTION 'That leaves %, which is below the floor of %. Say why, or discount less.',
        round(coalesce(p_base_amount, 0) - p_discount_amount, 2), round(p_floor, 2);
    END IF;
    v_breach := true;
  END IF;

  SELECT id INTO v_me FROM employees
   WHERE user_id::text = nullif(current_setting('request.jwt.claim.sub', true), '');

  INSERT INTO discount_applications (
    module, document_type, document_id, line_ref, rule_id,
    code, name, method, value, base_amount, discount_amount,
    is_manual, customer_ref, reason, applied_by, approved_by, floor_breached)
  VALUES (
    p_module, p_document_type, p_document_id, p_line_ref, p_rule_id,
    v_r.code, v_r.name, v_r.method, v_r.value,
    round(coalesce(p_base_amount, 0), 4), round(p_discount_amount, 4),
    v_manual, nullif(p_customer_ref, ''), p_reason,
    v_me,
    -- Whoever applied it held the role the rule demanded, checked above.
    CASE WHEN v_r.requires_approval THEN v_me ELSE NULL END,
    v_breach)
  RETURNING * INTO v_a;

  IF p_rule_id IS NOT NULL THEN
    UPDATE discount_rules SET redemption_count = redemption_count + 1 WHERE id = p_rule_id;
  END IF;

  RETURN v_a;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_discount(p_application_id uuid, p_reason text)
 RETURNS discount_applications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_a discount_applications;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Voiding a discount needs a reason. It stays on the record.';
  END IF;
  SELECT * INTO v_a FROM discount_applications WHERE id = p_application_id FOR UPDATE;
  IF v_a.id IS NULL THEN RAISE EXCEPTION 'That discount does not exist'; END IF;
  IF v_a.voided THEN RAISE EXCEPTION 'That discount was already voided'; END IF;

  UPDATE discount_applications SET voided = true, void_reason = p_reason
   WHERE id = p_application_id RETURNING * INTO v_a;

  -- The redemption comes back, so a voided use does not consume a coupon.
  IF v_a.rule_id IS NOT NULL THEN
    UPDATE discount_rules SET redemption_count = greatest(redemption_count - 1, 0)
     WHERE id = v_a.rule_id;
  END IF;
  RETURN v_a;
END;
$$;

-- What a document has had taken off it.
CREATE OR REPLACE FUNCTION public.document_discount(p_module text, p_document_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT coalesce(sum(discount_amount), 0) FROM discount_applications
   WHERE module = p_module AND document_id = p_document_id AND NOT voided;
$$;

-- ---------------------------------------------------------------------
-- 7. WHAT NEEDS LOOKING AT
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.discount_reconciliation()
 RETURNS TABLE (out_kind text, out_ref uuid, out_label text, out_issue text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  -- Given outside the rules with nothing said about why. This is where
  -- margin leaves a business.
  SELECT 'discount', a.id, coalesce(a.module || ' ' || coalesce(a.document_type, ''), 'discount'),
         'Given outside the rules for ' || round(a.discount_amount, 2)::text || ' with no reason.'
    FROM discount_applications a
   WHERE a.is_manual AND NOT a.voided AND coalesce(trim(a.reason), '') = ''

  UNION ALL
  -- Sold through the floor the caller stated.
  SELECT 'discount', a.id, coalesce(a.code, a.module),
         'Took the document below the floor the module set. Reason: ' || coalesce(a.reason, '—')
    FROM discount_applications a
   WHERE a.floor_breached AND NOT a.voided

  UNION ALL
  -- A rule needing approval that nobody approved.
  SELECT 'rule', r.id, r.name,
         'Needs a ' || coalesce(r.approval_role, 'approver')
         || ' but has been applied without one ' || count(a.id)::text || ' time(s).'
    FROM discount_rules r
    JOIN discount_applications a ON a.rule_id = r.id AND NOT a.voided AND a.approved_by IS NULL
   WHERE r.requires_approval
   GROUP BY r.id, r.name, r.approval_role

  UNION ALL
  -- A promotion nobody switched off.
  SELECT 'rule', r.id, r.name,
         'Still active but its season ended on ' || r.valid_to::text || '.'
    FROM discount_rules r
   WHERE r.is_active AND r.valid_to IS NOT NULL AND r.valid_to < CURRENT_DATE

  UNION ALL
  -- Used past its own limit.
  SELECT 'rule', r.id, r.name,
         'Used ' || r.redemption_count::text || ' times against a limit of '
         || r.max_redemptions::text || '.'
    FROM discount_rules r
   WHERE r.max_redemptions IS NOT NULL AND r.redemption_count > r.max_redemptions

  UNION ALL
  -- A coupon past its expiry that is still redeemable.
  SELECT 'coupon', c.id, c.code,
         'Expired on ' || c.expires_on::text || ' but has not been voided.'
    FROM discount_coupons c
   WHERE NOT c.is_void AND c.expires_on IS NOT NULL AND c.expires_on < CURRENT_DATE
     AND c.used_count < coalesce(c.max_uses, 1)

  UNION ALL
  -- A rule that gives everything away.
  SELECT 'rule', r.id, r.name,
         'Discounts the whole amount. Check that is what was meant.'
    FROM discount_rules r
   WHERE r.is_active AND r.method = 'percent' AND r.value >= 100;
$$;

-- What the discounts cost, over a period, by rule.
DROP FUNCTION IF EXISTS public.discount_report(date, date, text);
CREATE OR REPLACE FUNCTION public.discount_report(
  p_from date, p_to date, p_module text DEFAULT NULL)
 RETURNS TABLE (
   out_code    text,
   out_name    text,
   out_times   bigint,
   out_base    numeric,
   out_given   numeric,
   out_avg_pct numeric
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  SELECT coalesce(a.code, '(outside the rules)'),
         coalesce(a.name, '(given by hand)'),
         count(*),
         round(sum(a.base_amount), 2),
         round(sum(a.discount_amount), 2),
         CASE WHEN sum(a.base_amount) = 0 THEN 0
              ELSE round(100 * sum(a.discount_amount) / sum(a.base_amount), 2) END
    FROM discount_applications a
   WHERE NOT a.voided
     AND a.applied_at::date BETWEEN p_from AND p_to
     AND (p_module IS NULL OR a.module = p_module)
   GROUP BY a.code, a.name
   ORDER BY sum(a.discount_amount) DESC;
$$;

GRANT EXECUTE ON FUNCTION public.discount_rule_qualifies(discount_rules, text, numeric, numeric, timestamp with time zone, text, integer, text, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.discount_rule_amount(discount_rules, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.evaluate_discounts(text, numeric, numeric, numeric, timestamp with time zone, text, integer, text, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.total_discount(text, numeric, numeric, numeric, timestamp with time zone, text, integer, text, text, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_discount(text, text, uuid, numeric, numeric, uuid, text, text, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_discount(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.document_discount(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.discount_reconciliation() TO authenticated;
GRANT EXECUTE ON FUNCTION public.discount_report(date, date, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
-- Anybody who sells needs to READ the rules — a cashier cannot apply a
-- discount they cannot see. Writing them is a management decision.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['discount_settings', 'discount_rules', 'discount_coupons',
                           'discount_applications']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_read', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)$p$,
                   t || '_read', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_write', t);
    EXECUTE format($p$CREATE POLICY %I ON public.%I FOR ALL TO authenticated
                      USING (public.has_any_role(ARRAY['Manager','Accountant']))
                      WITH CHECK (public.has_any_role(ARRAY['Manager','Accountant']))$p$,
                   t || '_write', t);
  END LOOP;
END $$;
