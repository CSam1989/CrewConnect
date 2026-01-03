# CrewConnect Database Documentation

This document describes the PostgreSQL schema, types, functions, triggers, and the settlement flow. DB constraint triggers remain active; computational logic has moved to the application layer for testability.

## Overview
- **Extensions:** `pgcrypto` (UUID generation), `btree_gist` (range exclusion support).
- **Tenancy:** Groups (`app_group`) contain Families (`family`), which contain Persons (`person`). Activities (`activity`) and Expenses (`expense`) are scoped to a Group.
- **Auth & Roles:** `login_user`, `role_definition`, `user_role_assignment`, `user_person_link`.

## Types (Enums)
- `expense_target_scope`: `GROUP`, `FAMILIES`, `PERSONS`
- `expense_status`: `draft`, `active`, `locked`, `void`
- `settlement_run_status`: `pending`, `finalized`, `canceled`
- `role_key`: `admin`, `group_admin`, `family_admin`, `member`, `viewer`
- `role_scope`: `GROUP`, `FAMILY`
- `payment_status`: `unpaid`, `partial`, `paid`

Types are created conditionally via a `DO $$` block to avoid duplicate creation.

## Core Tables
- **Groups:** `app_group`
  - Fields: `id`, `name` (unique case-insensitive), `currency` (default `USD`), `is_active`, timestamps
  - Trigger: `app_group_set_updated_at`

- **Users:** `login_user`
  - Fields: `id`, `email` (`citext` unique), `display_name`, `is_active`, timestamps
  - Trigger: `login_user_set_updated_at`

- **Roles:** `role_definition`
  - Canonical roles with descriptions

- **Role Assignments:** `user_role_assignment`
  - Fields: `user_id`, `role_key`, `scope`, optional `group_id`/`family_id`
  - Check constraint enforces scope correctness; FK for `group_id` cascades

- **Families:** `family`
  - Fields: `group_id`, `name` (unique per group), `is_active`, timestamps
  - Trigger: `family_set_updated_at`; Index: `ix_family_group`

- **Persons:** `person`
  - Fields: `family_id`, `full_name`, optional `date_of_birth`, `is_active`, timestamps
  - Trigger: `person_set_updated_at`; Index: `ix_person_family`

- **User ↔ Person Link:** `user_person_link`
  - Many-to-many bridge `user_id` ↔ `person_id`

## Weighting Factors
- **Valid Catalog:** `valid_factor`
  - Primary key: `value numeric(6,4)`
  - Defines the allowed set of weighting factors.

- **Person Factor:** `person_factor`
  - One row per person; `factor` must exist in `valid_factor`
  - Unique on `person_id`; timestamps

- **Helper Function:** `person_factor_at(p_person uuid, p_on date)`
  - Returns the person’s current factor or `1.0` if missing; date is ignored.

### Seed Examples
```sql
INSERT INTO valid_factor (value) VALUES
  (1.0000),
  (0.7500),
  (1.2500);
```

## Activities & Expenses
- **Activities:** `activity`
  - Fields: `group_id`, `name`, `activity_date`, optional `notes`, `is_active`, `created_by`, timestamps
  - Triggers/Indexes: `activity_set_updated_at`, `ix_activity_group`, `ix_activity_date`

- **Expenses:** `expense`
  - Fields: `activity_id`, `payer_person_id`, `amount`, `currency`, `status`, `target_scope`, `include_payer`, `note`, `locked_in_run_id`, `created_by`, timestamps
  - Constraint: `status='locked'` implies `locked_in_run_id IS NOT NULL`
  - Default currency via `ALTER TABLE` (`USD`)
  - Indexes: `ix_expense_activity`, `ix_expense_payer`, `ix_expense_status`, `ix_expense_locked_run`
  - Trigger: `expense_set_updated_at`

- **Expense Targets:**
  - `expense_family_target (expense_id, family_id)` when `target_scope=FAMILIES`
  - `expense_person_target (expense_id, person_id)` when `target_scope=PERSONS`

## Settlement Snapshot Tables
- **Settlement Run:** `settlement_run`
  - Tracks per-activity runs: `run_no`, `status`, executor, timing, counts and totals
  - Unique per activity per run; a partial unique index enforces only one `finalized` run per activity

- **Per-Expense Allocation:** `settlement_expense_allocation`
  - Snapshot: `run_id`, `expense_id`, `person_id`, `weight_used`, `amount`, `currency`
  - Unique per run/expense/person; Indexes on `run_id`, `person_id`

- **Per-Person Net Line:** `settlement_line`
  - For each person in a run: `owed_total`, `credit_total`, `net_amount`, `status`, `amount_paid`, `currency`
  - Unique per run/person; Index on `status`

- **Payments:** `payment`
  - Records transfers inside a run: payer/payee/persons, `amount`, `currency`, `paid_at`, `reference`
  - Indexes on `run_id` and payer/payee direction

## Triggers & Guardrails
- **Expense Targets Validation:** `validate_expense_targets()` + `expense_targets_check` constraint trigger
  - Enforces consistency:
    - `GROUP`: no family/person targets allowed
    - `FAMILIES`: at least one family target required
    - `PERSONS`: at least one person target required

- **Updated-at Triggers:** Standard `set_updated_at()` on mutable tables

## Computation: Application-Layer
All settlement math and payment recomputation have moved to the application layer for unit testing and maintainability.

- **Deprecated DB Function:** `run_activity_settlement(...)` in KC2 now raises an exception to avoid DB-side execution.
- **Legacy Reference:** Full original computation is preserved in [src/Database/KC2_computation_legacy.sql](KC2_computation_legacy.sql) for documentation.

### Recommended App Flow
1. **Create run header:** Insert `settlement_run` (`status='pending'`).
2. **Gather expenses:** Active and not locked for the activity:
   ```sql
   SELECT * FROM expense e
   WHERE e.activity_id = $1
     AND e.status = 'active'
     AND e.locked_in_run_id IS NULL;
   ```
3. **Build targets:**
   - GROUP: all active persons in the activity’s group
   - FAMILIES: persons in selected families
   - PERSONS: selected persons
   - Optionally exclude payer when `include_payer=false`.
4. **Attach weights:** Use `person_factor` current `factor`.
5. **Compute allocations:** Convert to cents, proportion by weight, apply fair remainder distribution.
6. **Persist allocations:** Insert into `settlement_expense_allocation`.
7. **Build settlement lines:** Aggregate owed vs credit per person; insert into `settlement_line`.
8. **Lock expenses:** Update each included `expense` with `status='locked'` and `locked_in_run_id`.
9. **Finalize run:** Update `settlement_run` totals and set `status='finalized'`.
10. **Payments:** On payment changes, recompute `settlement_line.amount_paid` and `status` in the app.

### Concurrency
- Previously managed with advisory locks in the DB. In the app, ensure only one settlement runs per activity concurrently (e.g., app-level mutex or transactional guard).

## Notes
- Keep constraint triggers (`expense_targets_check`) to guard data integrity.
- If you need DB-side payment recomputation again, the trigger/functions exist in the legacy file and can be re-enabled by executing that file, but the recommended approach is app-side recompute with tests.

## File Map
- Primary schema: [src/Database/KC2.sql](KC2.sql)
- Legacy computations (documentation): [src/Database/KC2_computation_legacy.sql](KC2_computation_legacy.sql)
