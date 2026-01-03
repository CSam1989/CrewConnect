---
description: 'Blazor component and application patterns'
applyTo: '**/*.razor, **/*.razor.cs, **/*.razor.css'
---

## Blazor Code Style and Structure

- Write idiomatic and efficient Blazor and C# code.
- Follow .NET and Blazor conventions.
- Use Razor Components appropriately for component-based UI development.
- Prefer inline functions for smaller components but separate complex logic into code-behind or service classes.
- Async/await should be used where applicable to ensure non-blocking UI operations.

## Naming Conventions

- Follow PascalCase for component names, method names, and public members.
- Use camelCase for private fields and local variables.
- Prefix interface names with "I" (e.g., IUserService).

## Blazor and .NET Specific Guidelines

- Utilize Blazor's built-in features for component lifecycle (e.g., OnInitializedAsync, OnParametersSetAsync).
- Use data binding effectively with @bind.
- Leverage Dependency Injection for services in Blazor.
- Structure Blazor components and services following Separation of Concerns.
- Always use the latest version C#, currently C# 13 features like record types, pattern matching, and global usings.

## Error Handling and Validation

- Implement proper error handling for Blazor pages and API calls.
- Use logging for error tracking in the backend and consider capturing UI-level errors in Blazor with tools like ErrorBoundary.
- Implement validation using FluentValidation or DataAnnotations in forms.

## Blazor API and Performance Optimization

- Utilize Blazor server-side or WebAssembly optimally based on the project requirements.
- Use asynchronous methods (async/await) for API calls or UI actions that could block the main thread.
- Optimize Razor components by reducing unnecessary renders and using StateHasChanged() efficiently.
- Minimize the component render tree by avoiding re-renders unless necessary, using ShouldRender() where appropriate.
- Use EventCallbacks for handling user interactions efficiently, passing only minimal data when triggering events.

## Caching Strategies

- Implement in-memory caching for frequently used data, especially for Blazor Server apps. Use IMemoryCache for lightweight caching solutions.
- For Blazor WebAssembly, utilize localStorage or sessionStorage to cache application state between user sessions.
- Consider Distributed Cache strategies (like Redis or SQL Server Cache) for larger applications that need shared state across multiple users or clients.
- Cache API calls by storing responses to avoid redundant calls when data is unlikely to change, thus improving the user experience.

## State Management Libraries

- Use Blazor's built-in Cascading Parameters and EventCallbacks for basic state sharing across components.
- Implement advanced state management solutions using libraries like Fluxor or BlazorState when the application grows in complexity.
- For client-side state persistence in Blazor WebAssembly, consider using Blazored.LocalStorage or Blazored.SessionStorage to maintain state between page reloads.
- For server-side Blazor, use Scoped Services and the StateContainer pattern to manage state within user sessions while minimizing re-renders.

## API Design and Integration

- Use HttpClient or other appropriate services to communicate with external APIs or your own backend.
- Implement error handling for API calls using try-catch and provide proper user feedback in the UI.

## Testing and Debugging in Visual Studio

- All unit testing and integration testing should be done in Visual Studio Enterprise.
- Test Blazor components and services using xUnit, NUnit, or MSTest.
- Use Moq or NSubstitute for mocking dependencies during tests.
- Debug Blazor UI issues using browser developer tools and Visual Studio's debugging tools for backend and server-side issues.
- For performance profiling and optimization, rely on Visual Studio's diagnostics tools.

## Security and Authentication

- Implement Authentication and Authorization in the Blazor app where necessary using ASP.NET Identity or JWT tokens for API authentication.
- Use HTTPS for all web communication and ensure proper CORS policies are implemented.

## API Documentation and Swagger

- Use Swagger/OpenAPI for API documentation for your backend API services.
- Ensure XML documentation for models and API methods for enhancing Swagger documentation.

## Project Context: CrewConnect

- App-level settlement: All expense allocation and settlement computations run in the application layer and must be unit tested. Do not implement settlement math in database functions. The legacy SQL in [CrewConnect/src/Database/KC2_computation_legacy.sql](CrewConnect/src/Database/KC2_computation_legacy.sql) is documentation only.
- DB guardrails: Keep and respect constraint triggers (e.g., `validate_expense_targets()` with `expense_targets_check`) to enforce target scope consistency.
- Person factors: `person_factor` holds a single factor per person, referenced from `valid_factor`. No effective-date ranges are used. Use the helper `person_factor_at(personId, anyDate)` which returns the current factor or `1.0` if unset.
- Schema references: Primary schema lives in [CrewConnect/src/Database/KC2.sql](CrewConnect/src/Database/KC2.sql). See [CrewConnect/src/Database/README.md](CrewConnect/src/Database/README.md) for an overview.

## Application Architecture Guidance

- Services-first: Implement settlement and payment recomputation in DI-backed services. Favor pure functions for core math to simplify unit tests.
- Rounding strategy: Compute allocations in cents, distribute remainder fairly by fractional parts to ensure sums match the expense amount.
- Async by default: Use async/await for DB/API I/O to keep the UI responsive.
- Separation of concerns: Components handle UI/input; services handle business rules; repositories/data clients handle persistence.
- Error feedback: Bubble up user-friendly messages for failed settlements or payment updates; log exceptions centrally.

## Clean Architecture

- Layers: Separate `Domain`, `Application`, `Infrastructure`, and `Presentation (UI)`.
- Dependencies: Depend inward only; `Domain` has no outward dependencies.
- Interfaces + DI: Define abstractions in `Application`; implement them in `Infrastructure` and inject via DI.
- Data boundaries: Keep persistence models (e.g., EF entities) in `Infrastructure`; expose DTOs/records from `Application` to `Presentation`.
- UI rules: Razor components/pages call `Application` services; avoid business logic in UI or controllers.
- Testing focus: Unit test `Domain` and `Application`; use integration tests for `Infrastructure`.
- Mapping: Use mappers to convert between domain entities and DTOs to keep layers decoupled.
- Configuration: Centralize settings in `Application`/`Infrastructure`; avoid hardcoding in UI.

## Testing Guidance (Critical)

- Unit test settlement services: cover target resolution (GROUP/FAMILIES/PERSONS), weights, cents rounding, and remainder distribution.
- Test payment recomputation: verify `amount_paid` and status transitions (`unpaid` → `partial` → `paid`) under various scenarios.
- Mock persistence: Use Moq/NSubstitute to isolate business logic; verify writes to `settlement_run`, `settlement_expense_allocation`, `settlement_line`, and expense locks.
- Avoid DB-side execution in tests: rely on app-layer implementations; database functions that compute allocations are deprecated.

## Coding Conventions (Project-specific)

- Domain naming: Prefer explicit names like `SettlementService`, `ExpenseAllocator`, `PaymentRecalculator`.
- Config & constants: Centralize factor lists and settlement parameters; do not hardcode in components.
- DTOs and records: Use C# record types for immutable data passed between layers.
- Validation: Enforce target scope rules in the app in addition to DB triggers for better UX.

## File Map (Helpful References)

- Schema and triggers: [CrewConnect/src/Database/KC2.sql](CrewConnect/src/Database/KC2.sql)
- Legacy computation (reference only): [CrewConnect/src/Database/KC2_computation_legacy.sql](CrewConnect/src/Database/KC2_computation_legacy.sql)
- Database overview: [CrewConnect/src/Database/README.md](CrewConnect/src/Database/README.md)