# Rails Pulse — Claude Context

## Database Migrations

Three paths, all kept in sync: `db/rails_pulse_schema.rb` (source of truth, fresh installs, never alters existing tables), its byte-identical copy at `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb`, and guarded incremental migrations in `db/rails_pulse_migrate/` for upgrades. Full procedure and reasons: `docs/migrations.md`, decision 0011.

Checklist for a new column or table:

1. `db/rails_pulse_schema.rb`
2. `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb` (identical copy)
3. `db/rails_pulse_migrate/TIMESTAMP_description.rb` with `column_exists?` / `table_exists?` guards; full words in the filename, no acronyms (`add_actual_query_to_operations`, not `..._sql_...`)
4. New table: `RAILS_PULSE_TABLES` in `lib/generators/rails_pulse/base_methods.rb`
5. New column: `SENTINEL_COLUMNS` in `lib/rails_pulse/schema_check.rb`
6. `test/migrations/upgrade_migration_test.rb`: add to `MIGRATION_CLASSES`, assert the column exists after upgrading from v0.2.7, run `rake test_migrations`
7. `test/dummy/db/migrate/` copy; `rake sync_test_schema` syncs the dummy schema

Never use model classes for data changes inside `up`; use `execute(<<~SQL)`. On separate-database SQLite hosts the model's pool cannot see DDL from the migration transaction and the migration rolls back.

## Running Tests

```bash
DB=sqlite3 rake test           # Default (SQLite3); use rake, NOT `rails test`
DB=postgresql rake test        # PostgreSQL
rake test_matrix               # All DBs × Rails versions (pre-release validation)
BROWSER=true rake test_matrix  # Include system tests
```

Tests are parallelized by default. System tests (`BROWSER=true`) disable parallelization automatically.

`rake test_setup` records which adapter it prepared the dummy database for (`tmp/test_setup_adapter`), and `rake test` refuses to run for a different `DB` until `test_setup` is run again: the dummy `schema.rb` is dumped from whichever adapter migrated last, and Rails loads that file, not the migrations, into the parallel-worker databases.

Never run a bare `rails test` over the whole repo: it picks up `test/migrations/`, whose non-transactional upgrade test rebuilds the DB from a v0.2.7 snapshot mid-suite and destroys fixtures for every test after it, causing hundreds of seed-dependent `RecordNotFound` errors. `rake test` runs the main suite with `test/migrations` excluded, then runs `rake test_migrations` in a separate process.

## Testing Conventions

Follow the principles in `docs/testing.md`. Key rules:

- Use **fixtures** as the default for test data (declared at class top with `fixtures :table_names`)
- Test only **public methods** — private methods are tested indirectly
- Never use bare `rescue` in tests; use `assert_raises` instead
- Use `travel_to`/`travel_back` for time-based tests; always clean up in teardown
- Use specific assertions: `assert_operator`, `assert_includes`, `assert_in_delta`, `assert_difference`
- Organize tests with comment headers: `# Structure Tests`, `# Calculation Tests`, `# Edge Cases`
- Always test edge cases: nil, empty, zero, boundary values, 100% scenarios

## Code Style

RuboCop with `rubocop-rails-omakase` enforces style. Run `bundle exec rubocop` before committing.

Naming conventions:
- Classes: `RailsPulse::FeatureName` (always namespaced)
- Models: singular (`Route`, `Request`, `Job`)
- Tables: `rails_pulse_<plural>` (e.g., `rails_pulse_jobs`)
- All models inherit from `RailsPulse::ApplicationRecord`

Code comments describe the current code, not its history. Explain a non-obvious constraint or the reason behind a decision — never what the code used to do or what it replaced (`# thread-local, like the RequestStore it replaces` is meaningless once RequestStore is gone from the codebase). That context belongs in the commit message or PR description, which are historical records; a comment lives in the file and should read correctly to someone with no git history.

## Architecture Gotchas

**`app/` is Zeitwerk-managed; `lib/` is not.** Services, models, controllers and jobs under `app/` autoload and reload by file path like any Rails app. Code under `lib/rails_pulse/` (installers, stats, task runners, middleware, subscribers) is loaded with explicit `require` / `autoload` entries in `lib/rails_pulse/engine.rb`; a new file there needs an entry.

**Zeitwerk uses the host's inflections.** A host with `inflect.acronym "SQL"` expects `sql_query_normalizer.rb` to define `SQLQueryNormalizer`. Any file under `app/` whose basename contains a common acronym (sql, csp, http, api, json, …) must be pinned in `ACRONYM_SAFE_INFLECTIONS` in `lib/rails_pulse/engine.rb`; `test/lib/rails_pulse/zeitwerk_test.rb` eager-loads with `SQL` and `CSP` declared to catch omissions.

**RequestStore is thread-local.** Operations are deep-copied before async tracking to prevent race conditions. The `skip_recording_rails_pulse_activity` flag prevents recursive tracking on Rails Pulse's own requests.

**Engine initializer ordering matters.** The initializers in `lib/rails_pulse/engine.rb` use `before:`/`after:` constraints — don't add new initializers without checking order dependencies.

**Ransack requires explicit opt-in.** Every model must define `ransackable_attributes` and `ransackable_associations`. Use `Arel.sql()` for computed fields to ensure cross-database compatibility.

**Configuration validation is strict.** All thresholds, patterns, and database settings are validated at startup — invalid config fails fast. The generator template at `lib/generators/rails_pulse/templates/rails_pulse.rb` is what upgraders' initializers are synced from, so a new option must appear there.

**One writer thread per process.** With `config.async = true` (the default) the middleware pushes each request onto a bounded queue and `RailsPulse::Tracker` drains it on a single connection; a full queue drops the newest request rather than blocking. SQL normalisation and N+1 detection run on the writer, not the request thread. Anything that must happen before the response is sent cannot live on this path. See decision 0005 and `docs/architecture.md`.

**Schema drift guard.** `RailsPulse::SchemaCheck` runs once per process and pauses tracking (dashboard answers 503) when a table or sentinel column is missing. A new column that older installs will lack must go in `SENTINEL_COLUMNS` or the guard will not protect it. `rails rails_pulse:status` reports schema, migrations, route backfill and initializer state and exits 1 when something needs action.

**Standalone dashboard.** `exe/rails_pulse_server` boots the host's `config/environment.rb` and serves the engine at `/` with its own session middleware. It ignores `authentication_method` and `authorize` and uses `standalone_authentication_method` or HTTP Basic. `RailsPulse.standalone?` is true there, and links are generated root-relative. See `docs/architecture.md` and decision 0010.

**Nothing under `app/` branches on `Rails.env`.** A `Rails.env.test?` guard in app code is a path the suite cannot see; a screenshot fixture hid behind one for four pre-releases. Environment-dependent behaviour goes in `lib/rails_pulse/configuration.rb` defaults or the install template, which are legitimately environment-aware. `rake check_app_env_branching` enforces it in `rake test_release` and the CI lint job; recording the environment name (`Rails.env.to_s`) is allowed.

**Requests index shows individual records, not aggregates.** Routes and Queries controllers use `Tables::Index` classes to query aggregated summary data, but RequestsController queries individual `RailsPulse::Request` records directly. This is intentional — the requests page displays per-request details (occurred_at, status, tags, route links) that would be lost in aggregation.

## Adding a New Feature

1. Add config option to `RailsPulse::Configuration` (`lib/rails_pulse/configuration.rb`)
2. Add model + migration (both paths — see Database Migrations above)
3. Add `ransackable_attributes` to any new model
4. Add fixtures to `test/fixtures/rails_pulse_*.yml`
5. Write tests following conventions in `docs/testing.md`
6. Services under `app/services/` autoload; only new `lib/` files need an engine entry

## Frontend / Assets

CSS is plain CSS (not Sass). JS uses Stimulus controllers. Pre-built files live in `/public/rails-pulse-assets/`.

They are **not** registered with Sprockets (`config.assets.precompile`) — re-minifying the ~2 MB bundle OOMs small hosts. After `assets:precompile`, `rails_pulse:install_assets` copies them into the host's `public/assets` with a SHA256 digest so `config.asset_host` and CDN-only CSP work. Development and hosts with no pipeline fall back to `RailsPulse::Middleware::AssetServer` at `/rails-pulse-assets/<gem-version>/...`. Layouts must use `tag.link` / `tag.script` (not `stylesheet_link_tag`) so middleware paths are not rewritten onto the CDN.

To rebuild assets: `npm run build` (or `npm run build:dev` for source maps).

## Pull Requests

Use `.github/pull_request_template.md`'s structure when opening a PR (`gh pr create --body`). The `## Summary` section is plain English for a reader with no context on the code — what problem it solves, what changed conceptually, why it's worth doing, what stays the same, how it was verified — no class/method names or jargon. Technical detail (what files changed, specific design decisions, edge cases handled) belongs in the sections after it, not the Summary.

## Changelog Entries

`CHANGELOG.md` entries are 1-2 sentences: what changed and its impact. No implementation narrative — root cause, code paths touched, specific error messages, or before/after numbers belong in the commit or PR description, not here.

## Releases

Run `rake test_release` before any release — it validates git status, RuboCop, Brakeman, asset build, gem build, generator tests, and the full test matrix. See `docs/releasing.md` for the full process.

## Docs

`docs/README.md` lists each file and when to read it. `docs/architecture.md` is the map of the runtime; `docs/decisions/` holds one record per design decision. Rewrite a decision when it changes; do not add historical notes.

## Git Hooks

Shared hooks live in `.githooks/`. Run once after cloning to activate them:

```bash
git config core.hooksPath .githooks
```

The `post-checkout` hook warns when `test/dummy/db/schema.rb` is from a different branch (Rails 8.1 silently loads schema.rb instead of running migrations on a fresh DB, applying the wrong table structure).

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`railspulse/rails_pulse`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo — `CONTEXT.md` at root, `docs/decisions/` for decision records. See `docs/agents/domain.md`.
