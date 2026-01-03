-- Bootstrap
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- for exclusion constraints on ranges (kept for compatibility)
CREATE EXTENSION IF NOT EXISTS citext;

-- Types (Enums)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'expense_target_scope') THEN
    CREATE TYPE expense_target_scope AS ENUM ('GROUP', 'FAMILIES', 'PERSONS');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'expense_status') THEN
    CREATE TYPE expense_status AS ENUM ('draft', 'active', 'locked', 'void');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'settlement_run_status') THEN
    CREATE TYPE settlement_run_status AS ENUM ('pending', 'finalized', 'canceled');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'role_key') THEN
    CREATE TYPE role_key AS ENUM ('admin', 'group_admin', 'family_admin', 'member', 'viewer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'role_scope') THEN
    CREATE TYPE role_scope AS ENUM ('GROUP', 'FAMILY');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payment_status') THEN
    CREATE TYPE payment_status AS ENUM ('unpaid','partial','paid');
  END IF;
END$$;

-- Common helper
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END$$;

-- Tenancy: group
-- app_group:
CREATE TABLE IF NOT EXISTS app_group (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  currency    char(3) NOT NULL DEFAULT 'USD',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
  -- unique lower(name) enforced via expression index
);
CREATE TRIGGER app_group_set_updated_at BEFORE UPDATE ON app_group
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE UNIQUE INDEX IF NOT EXISTS uq_app_group_lower_name
  ON app_group (lower(name));

-- Auth users
-- login_user:
CREATE TABLE IF NOT EXISTS login_user (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        citext NOT NULL UNIQUE,
  display_name text NOT NULL,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER login_user_set_updated_at BEFORE UPDATE ON login_user
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Roles and scoped assignments
-- role_definition:
CREATE TABLE IF NOT EXISTS role_definition (
  key          role_key PRIMARY KEY,
  description  text NOT NULL
);
INSERT INTO role_definition (key, description) VALUES
  ('admin','Platform super admin'),
  ('group_admin','Admin for a group'),
  ('family_admin','Admin for a family'),
  ('member','Regular member'),
  ('viewer','Read-only')
ON CONFLICT DO NOTHING;

-- user_role_assignment:
CREATE TABLE IF NOT EXISTS user_role_assignment (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES login_user(id) ON DELETE CASCADE,
  role_key    role_key NOT NULL REFERENCES role_definition(key),
  scope       role_scope NOT NULL,
  group_id    uuid NULL REFERENCES app_group(id) ON DELETE CASCADE,
  family_id   uuid NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (scope = 'GROUP'  AND group_id IS NOT NULL AND family_id IS NULL)
 OR (scope = 'FAMILY' AND family_id IS NOT NULL)
  )
);

-- Families
-- family:
CREATE TABLE IF NOT EXISTS family (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    uuid NOT NULL REFERENCES app_group(id) ON DELETE CASCADE,
  name        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
  -- unique (group_id, lower(name)) enforced via expression index
);
CREATE INDEX IF NOT EXISTS ix_family_group ON family(group_id);
CREATE TRIGGER family_set_updated_at BEFORE UPDATE ON family
FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE UNIQUE INDEX IF NOT EXISTS uq_family_group_lower_name
  ON family (group_id, lower(name));

-- Persons
-- person:
CREATE TABLE IF NOT EXISTS person (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id    uuid NOT NULL REFERENCES family(id) ON DELETE CASCADE,
  full_name    text NOT NULL,
  date_of_birth date NULL,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_person_family ON person(family_id);
CREATE TRIGGER person_set_updated_at BEFORE UPDATE ON person
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Link users <-> persons
-- user_person_link:
CREATE TABLE IF NOT EXISTS user_person_link (
  user_id   uuid NOT NULL REFERENCES login_user(id) ON DELETE CASCADE,
  person_id uuid NOT NULL REFERENCES person(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, person_id)
);

-- Ensure family_admin assignments reference a family and implicitly its group
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_class t
    WHERE t.relname = 'user_role_assignment'
  ) THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      WHERE t.relname = 'user_role_assignment' AND c.conname = 'ura_family_fk'
    ) THEN
      ALTER TABLE user_role_assignment
        ADD CONSTRAINT ura_family_fk
        FOREIGN KEY (family_id) REFERENCES family(id) ON DELETE CASCADE;
    END IF;
  END IF;
END$$;

-- Valid factors catalog
-- valid_factor:
CREATE TABLE IF NOT EXISTS valid_factor (
  value numeric(6,4) PRIMARY KEY
);

-- Person factor (single, from valid list)
-- person_factor:
CREATE TABLE IF NOT EXISTS person_factor (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id     uuid NOT NULL REFERENCES person(id) ON DELETE CASCADE,
  factor        numeric(6,4) NOT NULL REFERENCES valid_factor(value),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (person_id)
);

-- Helper to get factor (date ignored, defaults to 1.0)
CREATE OR REPLACE FUNCTION person_factor_at(p_person uuid, p_on date)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE((
    SELECT pf.factor
    FROM person_factor pf
    WHERE pf.person_id = p_person
    LIMIT 1
  ), 1.0)
$$;

-- Activities
-- activity:
CREATE TABLE IF NOT EXISTS activity (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id     uuid NOT NULL REFERENCES app_group(id) ON DELETE CASCADE,
  name         text NOT NULL,
  activity_date date NOT NULL,
  notes        text,
  is_active    boolean NOT NULL DEFAULT true,
  created_by   uuid NULL REFERENCES login_user(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_activity_group ON activity(group_id);
CREATE INDEX IF NOT EXISTS ix_activity_date ON activity(activity_date);
CREATE TRIGGER activity_set_updated_at BEFORE UPDATE ON activity
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Expenses
-- expense:
CREATE TABLE IF NOT EXISTS expense (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id   uuid NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
  payer_person_id uuid NOT NULL REFERENCES person(id),
  amount        numeric(12,2) NOT NULL CHECK (amount > 0),
  currency      char(3) NOT NULL,
  status        expense_status NOT NULL DEFAULT 'active',
  target_scope  expense_target_scope NOT NULL,
  include_payer boolean NOT NULL DEFAULT true,
  note          text,
  locked_in_run_id uuid NULL, -- set when settled
  created_by    uuid NULL REFERENCES login_user(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((status <> 'locked') OR (locked_in_run_id IS NOT NULL))
);
ALTER TABLE expense
  ALTER COLUMN currency SET DEFAULT 'USD'::char(3);
CREATE INDEX IF NOT EXISTS ix_expense_activity ON expense(activity_id);
CREATE INDEX IF NOT EXISTS ix_expense_payer ON expense(payer_person_id);
CREATE INDEX IF NOT EXISTS ix_expense_status ON expense(status);
CREATE INDEX IF NOT EXISTS ix_expense_locked_run ON expense(locked_in_run_id);
CREATE TRIGGER expense_set_updated_at BEFORE UPDATE ON expense
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Expense targets
-- expense_family_target:
CREATE TABLE IF NOT EXISTS expense_family_target (
  expense_id uuid NOT NULL REFERENCES expense(id) ON DELETE CASCADE,
  family_id  uuid NOT NULL REFERENCES family(id),
  PRIMARY KEY (expense_id, family_id)
);
-- expense_person_target:
CREATE TABLE IF NOT EXISTS expense_person_target (
  expense_id uuid NOT NULL REFERENCES expense(id) ON DELETE CASCADE,
  person_id  uuid NOT NULL REFERENCES person(id),
  PRIMARY KEY (expense_id, person_id)
);

-- Settlement run
-- settlement_run:
CREATE TABLE IF NOT EXISTS settlement_run (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id     uuid NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
  run_no          integer NOT NULL,
  status          settlement_run_status NOT NULL DEFAULT 'pending',
  executed_by     uuid NULL REFERENCES login_user(id),
  executed_at     timestamptz NOT NULL DEFAULT now(),
  finalized_at    timestamptz NULL,
  expenses_count  integer NOT NULL DEFAULT 0,
  total_expenses  numeric(14,2) NOT NULL DEFAULT 0,
  total_allocated numeric(14,2) NOT NULL DEFAULT 0,
  notes           text,
  CONSTRAINT uq_run_per_activity UNIQUE (activity_id, run_no)
);
-- Only one finalized run per activity
CREATE UNIQUE INDEX IF NOT EXISTS uq_finalized_run_per_activity
  ON settlement_run(activity_id)
  WHERE status = 'finalized';

-- Detailed per-expense allocations (snapshot)
-- settlement_expense_allocation:
CREATE TABLE IF NOT EXISTS settlement_expense_allocation (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id      uuid NOT NULL REFERENCES settlement_run(id) ON DELETE CASCADE,
  expense_id  uuid NOT NULL REFERENCES expense(id),
  person_id   uuid NOT NULL REFERENCES person(id),
  weight_used numeric(6,4) NOT NULL,
  amount      numeric(12,2) NOT NULL,
  currency    char(3) NOT NULL,
  UNIQUE (run_id, expense_id, person_id)
);
CREATE INDEX IF NOT EXISTS ix_sea_run ON settlement_expense_allocation(run_id);
CREATE INDEX IF NOT EXISTS ix_sea_person ON settlement_expense_allocation(person_id);

-- Per-person net result within a run
-- settlement_line:
CREATE TABLE IF NOT EXISTS settlement_line (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id        uuid NOT NULL REFERENCES settlement_run(id) ON DELETE CASCADE,
  person_id     uuid NOT NULL REFERENCES person(id),
  owed_total    numeric(12,2) NOT NULL DEFAULT 0,
  credit_total  numeric(12,2) NOT NULL DEFAULT 0,
  net_amount    numeric(12,2) NOT NULL,
  status        payment_status NOT NULL DEFAULT 'unpaid',
  amount_paid   numeric(12,2) NOT NULL DEFAULT 0,
  currency      char(3) NOT NULL,
  UNIQUE (run_id, person_id)
);
CREATE INDEX IF NOT EXISTS ix_sl_run ON settlement_line(run_id);
CREATE INDEX IF NOT EXISTS ix_sl_status ON settlement_line(status);

-- Payments (no recompute trigger; app handles recomputation)
-- payment:
CREATE TABLE IF NOT EXISTS payment (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id         uuid NOT NULL REFERENCES settlement_run(id) ON DELETE CASCADE,
  payer_person_id uuid NOT NULL REFERENCES person(id),
  payee_person_id uuid NOT NULL REFERENCES person(id),
  amount         numeric(12,2) NOT NULL CHECK (amount > 0),
  currency       char(3) NOT NULL,
  paid_at        timestamptz NOT NULL DEFAULT now(),
  reference      text
);
CREATE INDEX IF NOT EXISTS ix_payment_run ON payment(run_id);
CREATE INDEX IF NOT EXISTS ix_payment_dir ON payment(payer_person_id, payee_person_id);

-- Validate expense targets against scope (constraint trigger)
CREATE OR REPLACE FUNCTION validate_expense_targets()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  fam_count int; per_count int;
BEGIN
  SELECT COUNT(*) INTO fam_count FROM expense_family_target WHERE expense_id = NEW.id;
  SELECT COUNT(*) INTO per_count FROM expense_person_target WHERE expense_id = NEW.id;

  IF NEW.target_scope = 'GROUP' THEN
    IF fam_count > 0 OR per_count > 0 THEN
      RAISE EXCEPTION 'GROUP-targeted expense % cannot have family/person targets', NEW.id;
    END IF;
  ELSIF NEW.target_scope = 'FAMILIES' THEN
    IF fam_count = 0 THEN
      RAISE EXCEPTION 'FAMILIES-targeted expense % must have at least one family target', NEW.id;
    END IF;
  ELSIF NEW.target_scope = 'PERSONS' THEN
    IF per_count = 0 THEN
      RAISE EXCEPTION 'PERSONS-targeted expense % must have at least one person target', NEW.id;
    END IF;
  END IF;
  RETURN NEW;
END$$;

CREATE CONSTRAINT TRIGGER expense_targets_check
AFTER INSERT OR UPDATE OF target_scope ON expense
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_expense_targets();

-- Settlement computations moved to application; DB function stub
CREATE OR REPLACE FUNCTION run_activity_settlement(p_activity_id uuid, p_executed_by uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'run_activity_settlement is deprecated; perform settlement in the application layer';
END
$$;
