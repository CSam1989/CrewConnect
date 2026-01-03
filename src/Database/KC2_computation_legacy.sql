-- Legacy computation logic extracted from KC2.sql
-- This file is kept for documentation/reference only and should NOT be executed in production.
-- The application layer now performs settlements and payment recomputations.

-- Maintain settlement_line.amount_paid and status from payments
CREATE OR REPLACE FUNCTION recompute_line_payments(p_run uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE settlement_line sl
  SET amount_paid = COALESCE(paid.total_in - paid.total_out, 0),
      status = CASE
        WHEN sl.net_amount = 0 THEN 'paid'::payment_status
        WHEN (sl.net_amount <= 0 AND COALESCE(paid.total_in - paid.total_out,0) >= 0) THEN 'paid'::payment_status
        WHEN (sl.net_amount > 0 AND COALESCE(paid.total_out - paid.total_in,0) >= sl.net_amount) THEN 'paid'::payment_status
        WHEN COALESCE(paid.total_in,0) <> COALESCE(paid.total_out,0) THEN 'partial'::payment_status
        ELSE 'unpaid'::payment_status
      END
  FROM (
    SELECT
      x.person_id,
      SUM(CASE WHEN x.dir = 'in'  THEN x.amount ELSE 0 END) AS total_in,
      SUM(CASE WHEN x.dir = 'out' THEN x.amount ELSE 0 END) AS total_out
    FROM (
      SELECT payee_person_id AS person_id, amount, 'in' AS dir
      FROM payment WHERE run_id = p_run
      UNION ALL
      SELECT payer_person_id AS person_id, amount, 'out' AS dir
      FROM payment WHERE run_id = p_run
    ) x
    GROUP BY x.person_id
  ) paid
  WHERE sl.run_id = p_run AND sl.person_id = paid.person_id;
END$$;

CREATE OR REPLACE FUNCTION payment_after_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM recompute_line_payments(COALESCE(NEW.run_id, OLD.run_id));
  RETURN COALESCE(NEW, OLD);
END$$;

CREATE TRIGGER payment_aiud AFTER INSERT OR UPDATE OR DELETE ON payment
FOR EACH ROW EXECUTE FUNCTION payment_after_change();

-- Settlement: compute allocations and lock expenses
CREATE OR REPLACE FUNCTION run_activity_settlement(p_activity_id uuid, p_executed_by uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_group_id uuid;
  v_currency char(3);
  v_run_id uuid;
  v_run_no int;
  v_lock_ok boolean;
BEGIN
  SELECT a.group_id, g.currency INTO v_group_id, v_currency
  FROM activity a JOIN app_group g ON g.id = a.group_id
  WHERE a.id = p_activity_id AND a.is_active = true
  FOR UPDATE;

  IF v_group_id IS NULL THEN
    RAISE EXCEPTION 'Activity % not found or inactive', p_activity_id;
  END IF;

  -- Prevent parallel runs on same activity
  v_lock_ok := pg_try_advisory_xact_lock(('settlement'::text || p_activity_id::text)::regclass::oid::bigint);
  IF NOT v_lock_ok THEN
    RAISE EXCEPTION 'Another settlement is running for activity %', p_activity_id;
  END IF;

  SELECT COALESCE(MAX(run_no), 0) + 1 INTO v_run_no FROM settlement_run WHERE activity_id = p_activity_id;
  INSERT INTO settlement_run (activity_id, run_no, status, executed_by)
  VALUES (p_activity_id, v_run_no, 'pending', p_executed_by)
  RETURNING id INTO v_run_id;

  -- Gather eligible expenses for this activity
  CREATE TEMP TABLE t_expense AS
  SELECT e.*
  FROM expense e
  WHERE e.activity_id = p_activity_id
    AND e.status = 'active'
    AND e.locked_in_run_id IS NULL
  FOR UPDATE;

  -- If none, finalize empty run
  IF NOT EXISTS (SELECT 1 FROM t_expense) THEN
    UPDATE settlement_run
    SET status = 'finalized', finalized_at = now(),
        expenses_count = 0, total_expenses = 0, total_allocated = 0
    WHERE id = v_run_id;
    RETURN v_run_id;
  END IF;

  -- Enumerate target persons per expense
  CREATE TEMP TABLE t_targets (
    expense_id uuid,
    person_id uuid,
    payer_person_id uuid,
    amount numeric(12,2),
    currency char(3),
    include_payer boolean,
    activity_date date
  ) ON COMMIT DROP;

  -- GROUP scope: all active persons in group
  INSERT INTO t_targets
  SELECT te.id, p.id, te.payer_person_id, te.amount, te.currency, te.include_payer, a.activity_date
  FROM t_expense te
  JOIN activity a ON a.id = te.activity_id
  JOIN family f ON f.group_id = v_group_id AND f.is_active
  JOIN person p ON p.family_id = f.id AND p.is_active
  WHERE te.target_scope = 'GROUP';

  -- FAMILIES scope
  INSERT INTO t_targets
  SELECT te.id, p.id, te.payer_person_id, te.amount, te.currency, te.include_payer, a.activity_date
  FROM t_expense te
  JOIN activity a ON a.id = te.activity_id
  JOIN expense_family_target eft ON eft.expense_id = te.id
  JOIN person p ON p.family_id = eft.family_id AND p.is_active
  WHERE te.target_scope = 'FAMILIES';

  -- PERSONS scope
  INSERT INTO t_targets
  SELECT te.id, ept.person_id, te.payer_person_id, te.amount, te.currency, te.include_payer, a.activity_date
  FROM t_expense te
  JOIN activity a ON a.id = te.activity_id
  JOIN expense_person_target ept ON ept.expense_id = te.id
  WHERE te.target_scope = 'PERSONS';

  -- Optionally exclude payer
  DELETE FROM t_targets t
  USING t_expense e
  WHERE t.expense_id = e.id AND e.include_payer = false AND t.person_id = e.payer_person_id;

  -- Attach factors and compute unrounded shares in cents
  CREATE TEMP TABLE t_calc AS
  WITH weights AS (
    SELECT
      t.expense_id,
      t.person_id,
      t.payer_person_id,
      t.amount,
      t.currency,
      person_factor_at(t.person_id, t.activity_date) AS weight
    FROM t_targets t
  ),
  totals AS (
    SELECT expense_id, SUM(weight) AS total_weight
    FROM weights GROUP BY expense_id
  ),
  prepared AS (
    SELECT
      w.expense_id, w.person_id, w.payer_person_id, w.amount, w.currency,
      w.weight, t.total_weight,
      (w.amount * 100.0) AS total_cents,
      ((w.amount * 100.0) * (w.weight / NULLIF(t.total_weight, 0))) AS alloc_cents_unrounded
    FROM weights w
    JOIN totals t ON t.expense_id = w.expense_id
  ),
  floors AS (
    SELECT
      expense_id, person_id, payer_person_id, amount, currency,
      weight, total_weight, total_cents,
      floor(alloc_cents_unrounded) AS alloc_cents_floor,
      (alloc_cents_unrounded - floor(alloc_cents_unrounded)) AS frac
    FROM prepared
  ),
  rank_frac AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY expense_id ORDER BY frac DESC, person_id) AS frac_rank,
           SUM(alloc_cents_floor) OVER (PARTITION BY expense_id) AS sum_floor
    FROM floors
  ),
  with_remainder AS (
    SELECT
      expense_id, person_id, payer_person_id, amount, currency,
      (alloc_cents_floor
        + CASE WHEN frac_rank <= GREATEST(0, (total_cents - sum_floor)::int) THEN 1 ELSE 0 END
      )::int AS alloc_cents_rounded
    FROM rank_frac
  )
  SELECT expense_id, person_id, payer_person_id, currency,
         (alloc_cents_rounded::numeric / 100.0) AS alloc_amount
  FROM with_remainder;

  -- Write allocations
  INSERT INTO settlement_expense_allocation (run_id, expense_id, person_id, weight_used, amount, currency)
  SELECT v_run_id, e.id, c.person_id,
         person_factor_at(c.person_id, a.activity_date) AS weight_used,
         c.alloc_amount, c.currency
  FROM t_calc c
  JOIN t_expense e ON e.id = c.expense_id
  JOIN activity a ON a.id = e.activity_id;

  -- Lock included expenses
  UPDATE expense e
  SET status = 'locked', locked_in_run_id = v_run_id, updated_at = now()
  FROM t_expense te
  WHERE e.id = te.id;

  -- Build settlement lines
  -- owed_total: allocations assigned to the person
  -- credit_total: allocations charged to others for expenses they paid
  CREATE TEMP TABLE t_owed AS
  SELECT person_id, SUM(amount) AS owed_total
  FROM settlement_expense_allocation
  WHERE run_id = v_run_id
  GROUP BY person_id;

  CREATE TEMP TABLE t_credit AS
  SELECT e.payer_person_id AS person_id, SUM(sea.amount) AS credit_total
  FROM settlement_expense_allocation sea
  JOIN expense e ON e.id = sea.expense_id
  WHERE sea.run_id = v_run_id
    AND sea.person_id <> e.payer_person_id
  GROUP BY e.payer_person_id;

  INSERT INTO settlement_line (run_id, person_id, owed_total, credit_total, net_amount, status, amount_paid, currency)
  SELECT v_run_id,
         p.person_id,
         COALESCE(o.owed_total, 0),
         COALESCE(c.credit_total, 0),
         COALESCE(o.owed_total, 0) - COALESCE(c.credit_total, 0) AS net_amount,
         'unpaid', 0, v_currency
  FROM (
    SELECT person_id FROM t_owed
    UNION
    SELECT person_id FROM t_credit
  ) p
  LEFT JOIN t_owed o ON o.person_id = p.person_id
  LEFT JOIN t_credit c ON c.person_id = p.person_id;

  -- Finalize run summary
  UPDATE settlement_run sr
  SET status = 'finalized',
      finalized_at = now(),
      expenses_count = (SELECT COUNT(*) FROM t_expense),
      total_expenses = (SELECT COALESCE(SUM(amount),0) FROM t_expense),
      total_allocated = (SELECT COALESCE(SUM(amount),0) FROM settlement_expense_allocation WHERE run_id = v_run_id)
  WHERE sr.id = v_run_id;

  RETURN v_run_id;
END
$$;
