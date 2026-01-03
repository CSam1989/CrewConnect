# CrewConnect

CrewConnect is a Blazor-based application for organizing shared activities and expenses across groups, families, and persons. It streamlines expense capture, weighted allocations, settlement runs, and payment tracking, with strong data guardrails and an app-layer calculation model that is easy to unit test.

## Overview
- Manage tenants as Groups, with Families and Persons nested within.
- Record Activities and attach Expenses paid by a Person.
- Target allocations to the entire Group, selected Families, or specific Persons.
- Apply per-person weighting factors from a predefined valid list.
- Run settlements to snapshot allocations and compute each person’s net position.
- Track payments against settlement lines and monitor status.

## Key Features
- Group-centric structure for multi-family and person-level expense sharing.
- Flexible targeting: `GROUP`, `FAMILIES`, `PERSONS` scopes.
- Validated data via DB constraint triggers (e.g., target scope enforcement).
- App-layer settlement computations for accuracy and testability.
- Clear audit trails: settlement runs, per-expense allocations, net lines, payments.

## Tech Stack
- Frontend: Blazor (Server or WebAssembly depending on deployment).
- Backend: .NET (C#), REST/Minimal API or controllers (project-dependent).
- Database: PostgreSQL.
- Testing: xUnit/MSTest/NUnit for services and settlement logic.

## Architecture
- Blazor UI components for capture and review.
- Application services perform settlement and payment recomputation.
- Database stores canonical state and enforces structural constraints.
- Separation of concerns: DB guardrails remain; computations live in the app.

## Database Schema (Summary)
- Tenancy: `app_group` → `family` → `person`.
- Auth & Roles: `login_user`, `role_definition`, `user_role_assignment`, `user_person_link`.
- Factors: `valid_factor` (allowed values), `person_factor` (selected value per person), `person_factor_at()` helper.
- Activities & Expenses: `activity`, `expense`, `expense_family_target`, `expense_person_target`.
- Settlement Snapshot: `settlement_run`, `settlement_expense_allocation`, `settlement_line`, `payment`.
- Guardrails: `validate_expense_targets()` + `expense_targets_check`.
- See database docs in [src/Database/README.md](src/Database/README.md) and legacy computation reference in [src/Database/KC2_computation_legacy.sql](src/Database/KC2_computation_legacy.sql).

## App-Level Settlement Flow
1. Create a `settlement_run` header (status `pending`).
2. Gather eligible expenses: active and not yet locked for the activity.
3. Build target persons per scope; optionally exclude payer.
4. Attach per-person weight from `person_factor`.
5. Compute proportional allocations (use cents and fair remainder distribution).
6. Persist rows to `settlement_expense_allocation`.
7. Build `settlement_line` totals (owed vs credit) and net amounts.
8. Lock included expenses by setting `locked_in_run_id` and `status='locked'`.
9. Finalize the run with summary totals and `status='finalized'`.
10. Recompute `amount_paid` and `status` on payment changes in the app.

## Getting Started
- Configure PostgreSQL and apply schema from [src/Database/KC2.sql](src/Database/KC2.sql).
- Seed valid factors (example): `1.0000`, `0.7500`, `1.2500`.
- Run the Blazor app and connect it to the database.
- Implement or use the provided services to run settlements at the application layer.

## Development & Testing
- Unit test settlement services and payment recomputation logic.
- Keep DB triggers for target scope validation to protect data integrity.
- Prefer async APIs and DI-driven services for Blazor.

## Security
- Use HTTPS for all app traffic.
- Implement authentication (e.g., ASP.NET Identity or JWT) and authorization for role-based access.
- Store secrets securely and avoid committing credentials.
