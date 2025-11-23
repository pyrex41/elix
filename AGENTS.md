# Repository Guidelines

## Project Structure & Module Organization
The active Phoenix project lives entirely under `backend/`. Core business logic for Replicate/XAI workflows, database contexts, and scheduled jobs is in `lib/backend`, while HTTP interfaces and JSON schemas sit in `lib/backend_web` (notably `controllers/api/v3` and `schemas/`). Database migrations, seeds, and static assets reside in `priv/`, and mirrored ExUnit specs live in `test/` following the same directory shape. Reference docs such as `API_ENDPOINTS.md`, `MIGRATION_REPORT.md`, and workflow primers in `log_docs/` provide additional context—update them whenever your change alters external behavior.

## Build, Test, and Development Commands
Run everything from `backend/` unless noted. `mix setup` installs deps and prepares SQLite databases (`backend_dev.db` / `backend_test.db`). `mix phx.server` (or `iex -S mix phx.server`) starts the API with code reloading. Use `mix ecto.migrate` after schema changes and `MIX_ENV=test mix ecto.reset` when you need a clean slate. `mix test` runs the full ExUnit suite; `mix precommit` enforces warnings-as-errors, removes unused deps, formats, and runs tests—match CI by running it locally before opening a PR.

## Coding Style & Naming Conventions
Stick to the default `mix format` output (2-space indentation, 100-column soft limit). Modules follow `Backend.*` namespaces (e.g., `BackendWeb.API.V3.JobController`), functions and files use `snake_case`, and request/response structs live in dedicated schema modules for clarity. Keep controller actions small by delegating to context modules and pattern-matching on the result tuples.

## Testing Guidelines
We rely on ExUnit with async tests where possible. Mirror controller, schema, and service files with `*_test.exs` counterparts under `test/backend_web` or `test/backend`. Seed data goes through factory helpers in `test/support`. When touching API contracts, add JSON fixture assertions and note breaking changes in `SCENE_API_DOCUMENTATION.md`. Aim to cover new branches or failure paths you introduce; use `mix test test/backend_web/controllers/api/v3/job_controller_test.exs` to iterate on a single module.

## Commit & Pull Request Guidelines
Recent history follows Conventional Commits (`feat:`, `fix:`, `chore:`). Write imperative subject lines under 72 characters and include scope when touching a narrow area (e.g., `feat(job): add campaign client lookup`). PRs should describe motivation, list key validation commands, link related issues, and include screenshots or sample payloads for endpoint changes. Call out any required environment updates or migration impacts.

## Environment & Security Notes
Copy `.env.example` to `.env` and supply `REPLICATE_API_KEY`, `XAI_API_KEY`, and `DATABASE_PATH` (for non-default stores) before running servers or tests. Never commit `.env`, SQLite WAL files, or API keys; gitignore already covers them, so keep secrets confined to local environment variables or secure vaults when deploying.
