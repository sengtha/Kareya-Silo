-- =====================================================================
-- KAREYA SILO — CIRCULATION INTEGRITY (library_integrity)
-- ---------------------------------------------------------------------
-- The original vertical got the hardest thing right: a partial unique
-- index (uq_library_loans_active_copy) means one physical copy cannot be
-- on two loans at once, however many librarians are at how many desks.
-- That constraint stands and this file does not touch it.
--
-- What was still wrong sits around it.
--
--  1. TWO SOURCES OF TRUTH FOR WHETHER A COPY IS OUT. library_copies.status
--     said 'on_loan' and library_loans said 'on_loan', and nothing kept the
--     two in step. Issuing was three separate round-trips — insert the loan,
--     update the copy, update the hold — so a dropped connection between
--     the first and the second left a copy that is on loan and reads as
--     available. The unique index still refuses a second loan, so the copy
--     becomes unissuable and the catalogue says it is on the shelf.
--
--  2. THE BORROWING LIMIT WAS COUNTED IN THE BROWSER. The copy is protected
--     by an index; the MEMBER is not. Two librarians both looking at a
--     member with 2 of 3 items out both issue, and the member walks out
--     with 4. The overdue block had the same hole.
--
--  3. THE FINE WAS ARITHMETIC DONE IN THE BROWSER, from a policy rate held
--     in React state. That is money owed by a named person, calculated from
--     a figure that may have been changed by somebody else since the page
--     loaded.
--
--  4. COLLECTING A FINE RECORDED NOTHING. fine_paid was a boolean: no
--     amount, no date, no who took the money. Waiving one needed no reason
--     and no authority beyond the role that issues books — so a fine could
--     be forgiven silently by whoever it embarrassed.
--
--  5. DELETING A COPY DELETED ITS LOAN HISTORY. library_loans.copy_id was
--     ON DELETE CASCADE. One click on a copy erased every record of who had
--     borrowed it. That is not a tidy-up, it is how a loss gets covered up.
--
--  6. A HOLD SHELF THAT NEVER CLEARED. A ready hold was given an expires_at
--     and nothing ever looked at it again. A member who reserved a book and
--     did not come back kept that copy off the shelf permanently — unusable
--     by them, by the next person waiting, and by everybody else.
--
-- Idempotent. Depends on the tables created by library.sql: library_items,
-- library_copies, library_members, library_loans, library_holds,
-- library_policy.
--
-- The underscore in the filename is not a typo. Verticals are applied in
-- alphabetical order, and 'library-integrity.sql' sorts BEFORE
-- 'library.sql' because a hyphen sorts before a dot — so the hyphenated
-- name ran before the tables it alters existed. Every other *-integrity
-- file in this directory works on tables from the core schema and has no
-- such neighbour. Renaming is a smaller change than restating a hundred
-- lines of table definitions in a second place they could drift from.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A LOAN IS THE TRUTH; THE COPY'S STATUS FOLLOWS IT
-- ---------------------------------------------------------------------

-- Money that changed hands, and who handled it.
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_paid_amount numeric DEFAULT 0;
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_paid_at timestamp with time zone;
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_collected_by uuid;
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_waived_reason text;
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_waived_by uuid;
ALTER TABLE public.library_loans ADD COLUMN IF NOT EXISTS fine_waived_at timestamp with time zone;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_fine_collected_by_fkey') THEN
    ALTER TABLE public.library_loans ADD CONSTRAINT library_loans_fine_collected_by_fkey
      FOREIGN KEY (fine_collected_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_fine_waived_by_fkey') THEN
    ALTER TABLE public.library_loans ADD CONSTRAINT library_loans_fine_waived_by_fkey
      FOREIGN KEY (fine_waived_by) REFERENCES public.employees(id) ON DELETE SET NULL;
  END IF;
END $$;

-- The loan record is what says a copy is out. library_copies.status is a
-- convenience for the shelf, and this trigger is what stops it drifting
-- away from the loan it is supposed to describe.
CREATE OR REPLACE FUNCTION public.library_copy_follows_loan()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_next text;
BEGIN
  PERFORM set_config('kareya.library_apply', 'on', true);

  IF TG_OP = 'INSERT' OR NEW.status = 'on_loan' THEN
    IF NEW.status = 'on_loan' THEN
      UPDATE library_copies SET status = 'on_loan' WHERE id = NEW.copy_id;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'on_loan' AND NEW.status <> 'on_loan' THEN
    IF NEW.status = 'lost' THEN
      UPDATE library_copies SET status = 'lost' WHERE id = NEW.copy_id;
    ELSE
      -- Coming back: it goes to the hold shelf if somebody is waiting for
      -- the title, otherwise back into circulation. Deciding that here
      -- rather than in the caller is what stops a returned copy being both
      -- set aside and available.
      SELECT h.id::text INTO v_next
        FROM library_holds h
        JOIN library_copies c ON c.id = NEW.copy_id
       WHERE h.item_id = c.item_id AND h.status = 'waiting'
       ORDER BY h.placed_at
       LIMIT 1;

      IF v_next IS NOT NULL THEN
        UPDATE library_holds
           SET status = 'ready', ready_at = now(), copy_id = NEW.copy_id,
               expires_at = coalesce(NEW.returned_at, CURRENT_DATE)
                            + coalesce((SELECT hold_shelf_days FROM library_policy WHERE id), 3)
         WHERE id = v_next::uuid;
        UPDATE library_copies SET status = 'on_hold_shelf' WHERE id = NEW.copy_id;
      ELSE
        UPDATE library_copies SET status = 'available' WHERE id = NEW.copy_id;
      END IF;
    END IF;
  END IF;

  PERFORM set_config('kareya.library_apply', '', true);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_library_copy_follows_loan ON public.library_loans;
CREATE TRIGGER trg_library_copy_follows_loan
  AFTER INSERT OR UPDATE OF status ON public.library_loans
  FOR EACH ROW EXECUTE FUNCTION public.library_copy_follows_loan();

-- The other half: nobody may set a copy on loan, or take it off loan, by
-- editing the copy. Repair, lost and withdrawn stay ordinary edits, but
-- not while somebody is holding the book.
CREATE OR REPLACE FUNCTION public.library_copy_status_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF coalesce(current_setting('kareya.library_apply', true), '') = 'on' THEN RETURN NEW; END IF;

  IF NEW.status = 'on_loan' OR OLD.status = 'on_loan' THEN
    RAISE EXCEPTION 'Whether a copy is on loan is decided by its loan record. Issue it or take it back.';
  END IF;
  IF NEW.status = 'on_hold_shelf' OR OLD.status = 'on_hold_shelf' THEN
    RAISE EXCEPTION 'The hold shelf is managed by the reservation queue, not by editing the copy.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_library_copy_status_guard ON public.library_copies;
CREATE TRIGGER trg_library_copy_status_guard
  BEFORE UPDATE ON public.library_copies
  FOR EACH ROW EXECUTE FUNCTION public.library_copy_status_guard();

-- ---------------------------------------------------------------------
-- 2. CIRCULATION HISTORY IS NOT DISPOSABLE
-- library_loans.copy_id was ON DELETE CASCADE, so removing a copy removed
-- every record of who had borrowed it. Withdraw a copy instead: it leaves
-- circulation and its history stays.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_copy_id_fkey' AND confdeltype = 'c') THEN
    ALTER TABLE public.library_loans DROP CONSTRAINT library_loans_copy_id_fkey;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_copy_id_fkey') THEN
    ALTER TABLE public.library_loans ADD CONSTRAINT library_loans_copy_id_fkey
      FOREIGN KEY (copy_id) REFERENCES public.library_copies(id) ON DELETE RESTRICT;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_member_id_fkey' AND confdeltype = 'c') THEN
    ALTER TABLE public.library_loans DROP CONSTRAINT library_loans_member_id_fkey;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'library_loans_member_id_fkey') THEN
    ALTER TABLE public.library_loans ADD CONSTRAINT library_loans_member_id_fkey
      FOREIGN KEY (member_id) REFERENCES public.library_members(id) ON DELETE RESTRICT;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.library_loan_is_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'A loan record cannot be deleted. It is the record of who had the book.';
  END IF;
  IF coalesce(current_setting('kareya.library_loan_apply', true), '') = 'on' THEN RETURN NEW; END IF;

  -- Outside the circulation functions, a note is the only thing on a loan
  -- that a librarian writes by hand. Due dates, fines and who had the book
  -- move by issuing, returning, renewing or settling — each of which
  -- records why it moved.
  IF NEW.copy_id IS DISTINCT FROM OLD.copy_id
     OR NEW.member_id IS DISTINCT FROM OLD.member_id
     OR NEW.loaned_at IS DISTINCT FROM OLD.loaned_at
     OR NEW.due_date IS DISTINCT FROM OLD.due_date
     OR NEW.returned_at IS DISTINCT FROM OLD.returned_at
     OR NEW.renew_count IS DISTINCT FROM OLD.renew_count
     OR NEW.status IS DISTINCT FROM OLD.status
     OR NEW.fine_amount IS DISTINCT FROM OLD.fine_amount
     OR NEW.fine_paid IS DISTINCT FROM OLD.fine_paid
     OR NEW.fine_waived IS DISTINCT FROM OLD.fine_waived THEN
    RAISE EXCEPTION 'A loan changes by being issued, renewed, returned or settled — not by being edited. Only the notes are yours to write.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_library_loan_is_record ON public.library_loans;
CREATE TRIGGER trg_library_loan_is_record
  BEFORE UPDATE OR DELETE ON public.library_loans
  FOR EACH ROW EXECUTE FUNCTION public.library_loan_is_record();

-- A copy that has ever been lent out is part of the record too.
CREATE OR REPLACE FUNCTION public.library_copy_no_delete_with_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM library_loans WHERE copy_id = OLD.id) THEN
    RAISE EXCEPTION 'This copy has been borrowed. Withdraw it instead — it leaves circulation and the history stays.';
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_library_copy_no_delete ON public.library_copies;
CREATE TRIGGER trg_library_copy_no_delete
  BEFORE DELETE ON public.library_copies
  FOR EACH ROW EXECUTE FUNCTION public.library_copy_no_delete_with_history();

CREATE OR REPLACE FUNCTION public.library_member_no_delete_with_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM library_loans WHERE member_id = OLD.id) THEN
    RAISE EXCEPTION 'This member has borrowed from the library. Set them expired instead — the borrowing record stays.';
  END IF;
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_library_member_no_delete ON public.library_members;
CREATE TRIGGER trg_library_member_no_delete
  BEFORE DELETE ON public.library_members
  FOR EACH ROW EXECUTE FUNCTION public.library_member_no_delete_with_history();

-- ---------------------------------------------------------------------
-- 3. WHAT A LOAN COSTS
-- The rate is read from the policy at the moment of settlement, not from
-- whatever the browser last saw.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.library_days_overdue(p_loan_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT greatest(0,
           (coalesce(l.returned_at, coalesce(p_as_of, CURRENT_DATE)) - l.due_date)
           - coalesce((SELECT grace_days FROM library_policy WHERE id), 0))::integer
    FROM library_loans l WHERE l.id = p_loan_id;
$function$;

GRANT EXECUTE ON FUNCTION public.library_days_overdue(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.library_fine_for(p_loan_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT round(library_days_overdue(p_loan_id, p_as_of)
               * coalesce((SELECT fine_per_day FROM library_policy WHERE id), 0), 2);
$function$;

GRANT EXECUTE ON FUNCTION public.library_fine_for(uuid, date) TO authenticated;

-- How many items a member may hold: their own allowance if set, otherwise
-- the library's.
CREATE OR REPLACE FUNCTION public.library_member_limit(p_member_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT coalesce(m.max_items, (SELECT max_items_per_member FROM library_policy WHERE id), 3)
    FROM library_members m WHERE m.id = p_member_id;
$function$;

GRANT EXECUTE ON FUNCTION public.library_member_limit(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 4. ISSUING
-- One transaction. The copy is locked, the member's live loans are counted
-- in the database, and the due date is snapshotted from the policy now so
-- a later policy change never makes this loan retrospectively late.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.library_staff_id()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('librarian', 'manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only a librarian or a manager may work the circulation desk';
  END IF;
  RETURN v_emp.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.checkout_library_copy(p_copy_id uuid, p_member_id uuid)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff  uuid := library_staff_id();
  v_copy   library_copies;
  v_member library_members;
  v_held   integer;
  v_limit  integer;
  v_ready  library_holds;
  v_loan   library_loans;
  v_days   integer;
BEGIN
  SELECT * INTO v_copy FROM library_copies WHERE id = p_copy_id FOR UPDATE;
  IF v_copy.id IS NULL THEN RAISE EXCEPTION 'That copy is not in the catalogue'; END IF;

  SELECT * INTO v_member FROM library_members WHERE id = p_member_id FOR UPDATE;
  IF v_member.id IS NULL THEN RAISE EXCEPTION 'That member is not registered'; END IF;

  IF v_member.status = 'suspended' THEN RAISE EXCEPTION '% is suspended', v_member.name; END IF;
  IF v_member.status = 'expired' OR (v_member.expires_date IS NOT NULL AND v_member.expires_date < CURRENT_DATE) THEN
    RAISE EXCEPTION 'Membership for % has expired', v_member.name;
  END IF;

  IF EXISTS (SELECT 1 FROM library_loans WHERE copy_id = p_copy_id AND status = 'on_loan') THEN
    RAISE EXCEPTION 'That copy is already on loan';
  END IF;
  IF v_copy.status IN ('repair', 'lost', 'withdrawn') THEN
    RAISE EXCEPTION 'That copy is %, so it cannot be issued', replace(v_copy.status, '_', ' ');
  END IF;

  -- A copy set aside on the hold shelf belongs to whoever reserved it.
  IF v_copy.status = 'on_hold_shelf' THEN
    SELECT * INTO v_ready FROM library_holds
      WHERE copy_id = p_copy_id AND status = 'ready' LIMIT 1;
    IF v_ready.id IS NOT NULL AND v_ready.member_id <> p_member_id THEN
      RAISE EXCEPTION 'That copy is on the hold shelf for somebody else';
    END IF;
  END IF;

  -- Counted here, not in the browser. Two librarians at two desks looking
  -- at the same member both saw 2 of 3 and both issued.
  SELECT count(*) INTO v_held FROM library_loans WHERE member_id = p_member_id AND status = 'on_loan';
  v_limit := library_member_limit(p_member_id);
  IF v_held >= v_limit THEN
    RAISE EXCEPTION '% already has % of % items out', v_member.name, v_held, v_limit;
  END IF;

  IF EXISTS (
    SELECT 1 FROM library_loans l
     WHERE l.member_id = p_member_id AND l.status = 'on_loan'
       AND library_days_overdue(l.id) > 0
  ) THEN
    RAISE EXCEPTION '% has an item that is overdue', v_member.name;
  END IF;

  v_days := coalesce((SELECT loan_days FROM library_policy WHERE id), 14);

  INSERT INTO library_loans (copy_id, member_id, loaned_at, due_date, status, issued_by)
  VALUES (p_copy_id, p_member_id, CURRENT_DATE, CURRENT_DATE + v_days, 'on_loan', v_staff)
  RETURNING * INTO v_loan;

  -- If this member was the one waiting for it, the reservation is met.
  UPDATE library_holds SET status = 'fulfilled'
   WHERE copy_id = p_copy_id AND member_id = p_member_id AND status = 'ready';

  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.checkout_library_copy(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.renew_library_loan(p_loan_id uuid)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff uuid := library_staff_id();
  v_loan  library_loans;
  v_max   integer;
  v_days  integer;
  v_base  date;
BEGIN
  SELECT * INTO v_loan FROM library_loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status <> 'on_loan' THEN RAISE EXCEPTION 'That loan is already closed'; END IF;

  v_max := coalesce((SELECT max_renewals FROM library_policy WHERE id), 2);
  IF coalesce(v_loan.renew_count, 0) >= v_max THEN
    RAISE EXCEPTION 'This loan has already been renewed % times, which is the limit', v_max;
  END IF;

  IF EXISTS (
    SELECT 1 FROM library_holds h
      JOIN library_copies c ON c.id = v_loan.copy_id
     WHERE h.item_id = c.item_id AND h.status IN ('waiting', 'ready')
  ) THEN
    RAISE EXCEPTION 'Somebody else is waiting for this title';
  END IF;

  v_days := coalesce((SELECT loan_days FROM library_policy WHERE id), 14);
  -- Extend from today when it is already late, otherwise from the current
  -- due date, so renewing early does not quietly shorten the loan.
  v_base := greatest(v_loan.due_date, CURRENT_DATE);

  PERFORM set_config('kareya.library_loan_apply', 'on', true);
  UPDATE library_loans
     SET due_date = v_base + v_days, renew_count = coalesce(renew_count, 0) + 1
   WHERE id = p_loan_id
  RETURNING * INTO v_loan;
  PERFORM set_config('kareya.library_loan_apply', '', true);
  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.renew_library_loan(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5. TAKING IT BACK
-- The fine is worked out from the policy as it stands now and frozen onto
-- the loan. Where the copy goes next is decided by the trigger in §1, so a
-- returned copy cannot be both set aside and on the shelf.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.return_library_loan(p_loan_id uuid)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff uuid := library_staff_id();
  v_loan  library_loans;
  v_fine  numeric;
BEGIN
  SELECT * INTO v_loan FROM library_loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status <> 'on_loan' THEN
    RAISE EXCEPTION 'That loan was already closed on %', coalesce(v_loan.returned_at::text, 'an earlier date');
  END IF;

  v_fine := library_fine_for(p_loan_id, CURRENT_DATE);

  PERFORM set_config('kareya.library_loan_apply', 'on', true);
  UPDATE library_loans
     SET status = 'returned', returned_at = CURRENT_DATE,
         fine_amount = v_fine, returned_by = v_staff
   WHERE id = p_loan_id
  RETURNING * INTO v_loan;
  PERFORM set_config('kareya.library_loan_apply', '', true);
  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.return_library_loan(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_library_loan_lost(p_loan_id uuid)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff uuid := library_staff_id();
  v_loan  library_loans;
  v_cost  numeric;
BEGIN
  SELECT * INTO v_loan FROM library_loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF v_loan.status <> 'on_loan' THEN RAISE EXCEPTION 'That loan is already closed'; END IF;

  SELECT coalesce(cost, 0) INTO v_cost FROM library_copies WHERE id = v_loan.copy_id;

  PERFORM set_config('kareya.library_loan_apply', 'on', true);
  UPDATE library_loans
     SET status = 'lost', returned_at = CURRENT_DATE, returned_by = v_staff,
         fine_amount = round(library_fine_for(p_loan_id, CURRENT_DATE) + v_cost, 2)
   WHERE id = p_loan_id
  RETURNING * INTO v_loan;
  PERFORM set_config('kareya.library_loan_apply', '', true);
  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_library_loan_lost(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 6. FINES ARE MONEY
-- fine_paid was a boolean. Now: how much was taken, when, and by whom —
-- and forgiving one needs a reason and more than the role that lends books.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.collect_library_fine(p_loan_id uuid, p_amount numeric DEFAULT NULL)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_staff uuid := library_staff_id();
  v_loan  library_loans;
  v_take  numeric;
BEGIN
  SELECT * INTO v_loan FROM library_loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF coalesce(v_loan.fine_amount, 0) <= 0 THEN RAISE EXCEPTION 'There is nothing owed on this loan'; END IF;
  IF v_loan.fine_paid THEN RAISE EXCEPTION 'This fine was already collected'; END IF;
  IF v_loan.fine_waived THEN RAISE EXCEPTION 'This fine was waived'; END IF;

  v_take := coalesce(p_amount, v_loan.fine_amount);
  IF v_take <= 0 THEN RAISE EXCEPTION 'A collection has to be for an amount'; END IF;
  IF v_take > v_loan.fine_amount THEN
    RAISE EXCEPTION 'That is more than is owed: % is due', v_loan.fine_amount;
  END IF;
  IF v_take < v_loan.fine_amount THEN
    RAISE EXCEPTION 'Part payment is not recorded here. Collect % or waive the difference with a reason.', v_loan.fine_amount;
  END IF;

  PERFORM set_config('kareya.library_loan_apply', 'on', true);
  UPDATE library_loans
     SET fine_paid = true, fine_paid_amount = v_take,
         fine_paid_at = now(), fine_collected_by = v_staff
   WHERE id = p_loan_id
  RETURNING * INTO v_loan;
  PERFORM set_config('kareya.library_loan_apply', '', true);
  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.collect_library_fine(uuid, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.waive_library_fine(p_loan_id uuid, p_reason text)
 RETURNS public.library_loans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_emp employees; v_loan library_loans;
BEGIN
  SELECT * INTO v_emp FROM employees
    WHERE user_id = auth.uid() OR email = (auth.jwt() ->> 'email')
    ORDER BY (user_id = auth.uid()) DESC NULLS LAST LIMIT 1;
  IF v_emp.id IS NULL THEN RAISE EXCEPTION 'Not an employee of this workspace'; END IF;
  -- Deliberately narrower than issuing: forgiving money owed is not the
  -- same authority as handing over a book.
  IF NOT EXISTS (SELECT 1 FROM unnest(v_emp.roles) r
                  WHERE lower(r) IN ('manager', 'admin', 'founder')) THEN
    RAISE EXCEPTION 'Only a manager may write off a fine';
  END IF;
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'Writing off a fine requires a reason';
  END IF;

  SELECT * INTO v_loan FROM library_loans WHERE id = p_loan_id FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF coalesce(v_loan.fine_amount, 0) <= 0 THEN RAISE EXCEPTION 'There is nothing owed on this loan'; END IF;
  IF v_loan.fine_paid THEN RAISE EXCEPTION 'This fine was already collected'; END IF;
  IF v_loan.fine_waived THEN RAISE EXCEPTION 'This fine was already waived'; END IF;

  PERFORM set_config('kareya.library_loan_apply', 'on', true);
  UPDATE library_loans
     SET fine_waived = true, fine_waived_reason = p_reason,
         fine_waived_by = v_emp.id, fine_waived_at = now()
   WHERE id = p_loan_id
  RETURNING * INTO v_loan;
  PERFORM set_config('kareya.library_loan_apply', '', true);
  RETURN v_loan;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.waive_library_fine(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------
-- 7. THE HOLD SHELF CLEARS
-- A ready hold was given an expires_at and nothing ever looked at it. A
-- member who reserved a book and never came back kept that copy off the
-- shelf for good.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.place_library_hold(p_item_id uuid, p_member_id uuid)
 RETURNS public.library_holds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := library_staff_id(); v_member library_members; v_hold library_holds;
BEGIN
  SELECT * INTO v_member FROM library_members WHERE id = p_member_id;
  IF v_member.id IS NULL THEN RAISE EXCEPTION 'That member is not registered'; END IF;
  IF v_member.status <> 'active' THEN RAISE EXCEPTION '% cannot reserve while %', v_member.name, v_member.status; END IF;
  IF NOT EXISTS (SELECT 1 FROM library_items WHERE id = p_item_id) THEN
    RAISE EXCEPTION 'That title is not in the catalogue';
  END IF;

  IF EXISTS (SELECT 1 FROM library_copies WHERE item_id = p_item_id AND status = 'available') THEN
    RAISE EXCEPTION 'A copy is on the shelf. Issue it rather than reserving it.';
  END IF;
  IF EXISTS (SELECT 1 FROM library_holds
              WHERE item_id = p_item_id AND member_id = p_member_id AND status IN ('waiting', 'ready')) THEN
    RAISE EXCEPTION '% is already in the queue for this title', v_member.name;
  END IF;
  IF EXISTS (SELECT 1 FROM library_loans l
               JOIN library_copies c ON c.id = l.copy_id
              WHERE c.item_id = p_item_id AND l.member_id = p_member_id AND l.status = 'on_loan') THEN
    RAISE EXCEPTION '% already has a copy of this title out', v_member.name;
  END IF;

  INSERT INTO library_holds (item_id, member_id, status)
  VALUES (p_item_id, p_member_id, 'waiting')
  RETURNING * INTO v_hold;
  RETURN v_hold;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.place_library_hold(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_library_hold(p_hold_id uuid)
 RETURNS public.library_holds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_staff uuid := library_staff_id(); v_hold library_holds;
BEGIN
  SELECT * INTO v_hold FROM library_holds WHERE id = p_hold_id FOR UPDATE;
  IF v_hold.id IS NULL THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF v_hold.status NOT IN ('waiting', 'ready') THEN
    RAISE EXCEPTION 'That reservation is already %', v_hold.status;
  END IF;

  UPDATE library_holds SET status = 'cancelled' WHERE id = p_hold_id RETURNING * INTO v_hold;
  IF v_hold.copy_id IS NOT NULL THEN PERFORM library_release_hold_copy(v_hold.copy_id); END IF;
  RETURN v_hold;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cancel_library_hold(uuid) TO authenticated;

-- A copy leaving the hold shelf goes to the next member in the queue if
-- there is one, and back into circulation if there is not. Both paths in
-- one place so a copy is never left set aside for nobody.
CREATE OR REPLACE FUNCTION public.library_release_hold_copy(p_copy_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_next uuid; v_item uuid;
BEGIN
  SELECT item_id INTO v_item FROM library_copies WHERE id = p_copy_id;
  SELECT id INTO v_next FROM library_holds
   WHERE item_id = v_item AND status = 'waiting' ORDER BY placed_at LIMIT 1;

  PERFORM set_config('kareya.library_apply', 'on', true);
  IF v_next IS NOT NULL THEN
    UPDATE library_holds
       SET status = 'ready', ready_at = now(), copy_id = p_copy_id,
           expires_at = CURRENT_DATE + coalesce((SELECT hold_shelf_days FROM library_policy WHERE id), 3)
     WHERE id = v_next;
    UPDATE library_copies SET status = 'on_hold_shelf' WHERE id = p_copy_id;
  ELSE
    UPDATE library_copies SET status = 'available' WHERE id = p_copy_id;
  END IF;
  PERFORM set_config('kareya.library_apply', '', true);
END;
$function$;

-- Sweep the hold shelf. Returns what it cleared, so the desk can be told
-- rather than the shelf silently rearranging itself.
DROP FUNCTION IF EXISTS public.expire_library_holds(date);
CREATE OR REPLACE FUNCTION public.expire_library_holds(p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (out_hold_id uuid, out_title text, out_member text, out_passed_to text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_next_member text;
BEGIN
  FOR r IN
    SELECT h.id, h.copy_id, i.title, m.name AS member_name
      FROM library_holds h
      JOIN library_items i ON i.id = h.item_id
      JOIN library_members m ON m.id = h.member_id
     WHERE h.status = 'ready'
       AND h.expires_at IS NOT NULL
       AND h.expires_at < coalesce(p_on, CURRENT_DATE)
     ORDER BY h.expires_at
  LOOP
    UPDATE library_holds SET status = 'expired' WHERE id = r.id;
    IF r.copy_id IS NOT NULL THEN
      PERFORM library_release_hold_copy(r.copy_id);
      SELECT m.name INTO v_next_member
        FROM library_holds h JOIN library_members m ON m.id = h.member_id
       WHERE h.copy_id = r.copy_id AND h.status = 'ready' LIMIT 1;
    ELSE
      v_next_member := NULL;
    END IF;

    out_hold_id := r.id; out_title := r.title;
    out_member := r.member_name; out_passed_to := v_next_member;
    RETURN NEXT;
  END LOOP;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.expire_library_holds(date) TO authenticated;

-- ---------------------------------------------------------------------
-- 8. WHAT THE SHELF SAYS VERSUS WHAT THE LOANS SAY
-- Names drift; does not correct it. A copy that the catalogue and the loan
-- record disagree about is a physical question — where is the book — and
-- a migration cannot answer it.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.library_reconciliation(date);
CREATE OR REPLACE FUNCTION public.library_reconciliation(p_on date DEFAULT CURRENT_DATE)
 RETURNS TABLE (
   out_kind    text,
   out_ref     uuid,
   out_title   text,
   out_detail  text,
   out_issue   text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- On loan by the record, but the catalogue says otherwise.
  SELECT 'copy', c.id, i.title,
         coalesce(c.accession_no, c.barcode, '—'),
         'The loan record says this copy is out, but the catalogue says ' || c.status || '.'
    FROM library_copies c
    JOIN library_items i ON i.id = c.item_id
   WHERE EXISTS (SELECT 1 FROM library_loans l WHERE l.copy_id = c.id AND l.status = 'on_loan')
     AND c.status <> 'on_loan'

  UNION ALL
  -- Catalogue says out, no open loan says so.
  SELECT 'copy', c.id, i.title,
         coalesce(c.accession_no, c.barcode, '—'),
         'The catalogue says this copy is on loan, but no open loan records it.'
    FROM library_copies c
    JOIN library_items i ON i.id = c.item_id
   WHERE c.status = 'on_loan'
     AND NOT EXISTS (SELECT 1 FROM library_loans l WHERE l.copy_id = c.id AND l.status = 'on_loan')

  UNION ALL
  -- Set aside for nobody.
  SELECT 'copy', c.id, i.title,
         coalesce(c.accession_no, c.barcode, '—'),
         'This copy is on the hold shelf but no reservation is waiting on it.'
    FROM library_copies c
    JOIN library_items i ON i.id = c.item_id
   WHERE c.status = 'on_hold_shelf'
     AND NOT EXISTS (SELECT 1 FROM library_holds h WHERE h.copy_id = c.id AND h.status = 'ready')

  UNION ALL
  -- Hold shelf past its date.
  SELECT 'hold', h.id, i.title, m.name,
         'This reservation has been ready since ' || h.expires_at
         || ' and the copy is still set aside. Sweep the hold shelf.'
    FROM library_holds h
    JOIN library_items i ON i.id = h.item_id
    JOIN library_members m ON m.id = h.member_id
   WHERE h.status = 'ready' AND h.expires_at IS NOT NULL
     AND h.expires_at < coalesce(p_on, CURRENT_DATE)

  UNION ALL
  -- Members over their allowance, however they got there.
  SELECT 'member', m.id, m.name,
         count(l.id)::text || ' of ' || library_member_limit(m.id)::text,
         'This member has more items out than their allowance.'
    FROM library_members m
    JOIN library_loans l ON l.member_id = m.id AND l.status = 'on_loan'
   GROUP BY m.id, m.name
  HAVING count(l.id) > library_member_limit(m.id)

  UNION ALL
  -- Money owed and never settled either way.
  SELECT 'fine', l.id, i.title,
         m.name || ' · ' || l.fine_amount::text,
         'This fine has been outstanding since ' || l.returned_at || '.'
    FROM library_loans l
    JOIN library_copies c ON c.id = l.copy_id
    JOIN library_items i ON i.id = c.item_id
    JOIN library_members m ON m.id = l.member_id
   WHERE coalesce(l.fine_amount, 0) > 0
     AND NOT l.fine_paid AND NOT l.fine_waived
     AND l.returned_at IS NOT NULL;
$function$;

GRANT EXECUTE ON FUNCTION public.library_reconciliation(date) TO authenticated;

-- ---------------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- Circulation moves through the functions above. Reading stays as it was.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Manage library loans" ON public.library_loans;
DROP POLICY IF EXISTS "Manage library holds" ON public.library_holds;

-- Notes are the one thing a librarian writes on a loan directly.
DROP POLICY IF EXISTS library_loans_annotate ON public.library_loans;
CREATE POLICY library_loans_annotate ON public.library_loans
  FOR UPDATE TO authenticated
  USING (public.has_any_role(ARRAY['Librarian', 'Manager']))
  WITH CHECK (public.has_any_role(ARRAY['Librarian', 'Manager']));
