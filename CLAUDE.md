# Rails Pulse — Claude Context

## Database Migrations

Rails Pulse has a three-path migration architecture. Always keep all three paths in mind when making schema changes.

### How it works

- **`db/rails_pulse_schema.rb`** is the single source of truth for the complete schema. It is used only for fresh installations — it checks `table_exists?` before creating each table and will never modify existing tables.
- **`lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb`** is the generator template that gets copied into users' apps when they run `rails generate rails_pulse:install`. It must always be kept identical to `db/rails_pulse_schema.rb`.
- **`db/rails_pulse_migrate/`** contains incremental migrations for new features. These are copied into users' apps by the upgrade generator (`rails generate rails_pulse:upgrade`).
- The install generator (`rails generate rails_pulse:install`) copies the template schema into the user's app, then creates a migration that loads and executes it.

### When adding a new column or table

You must update **all three** (plus the table list for new tables):

1. **`db/rails_pulse_schema.rb`** — add the column/table for fresh installs (source of truth)
2. **`lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb`** — keep in sync with the source of truth so the install generator produces correct output
3. **`db/rails_pulse_migrate/TIMESTAMP_description.rb`** — add an incremental migration with `column_exists?`/`table_exists?` guards for existing installs
4. **`lib/generators/rails_pulse/base_methods.rb` `RAILS_PULSE_TABLES`** — add the table name (new tables only); this is the fallback list used when the host app's schema file can't be parsed
5. **`lib/rails_pulse/schema_check.rb` `SENTINEL_COLUMNS`** — add the column (existing tables only) so a host running the new gem against un-migrated tables pauses tracking instead of erroring; `schema_check_test.rb` verifies every entry exists in the schema file
6. **`test/migrations/upgrade_migration_test.rb`** — update the migration regression tests:
   - Add the new class name to `MIGRATION_CLASSES` (in filename sort order)
   - Add an assertion that the new column/table exists after upgrading from v0.2.7
   - Run `rake test_migrations` to verify

Example incremental migration pattern:
```ruby
class AddPriorityToJobs < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:rails_pulse_jobs, :priority)
      add_column :rails_pulse_jobs, :priority, :integer, default: 0
    end
  end
end
```

### Test/dummy app

The test dummy app needs its schema kept in sync:
- `test/dummy/db/rails_pulse_schema.rb` must mirror `db/rails_pulse_schema.rb`
- Run `rake sync_test_schema` to sync them (also runs automatically before test setup)

### What NOT to do

- Do not modify existing table structure in `db/rails_pulse_schema.rb` — it only creates tables, never alters them
- Do not add columns directly to the schema file without also adding an incremental migration in `db/rails_pulse_migrate/`
- Do not use acronyms in migration filenames (e.g. `sql`, `url`, `id`). Rails camelizes `add_actual_sql_to_operations` to `AddActualSqlToOperations`, but some host apps use inflection rules that produce `AddActualSQLToOperations`, causing a `NameError` at runtime. Use full words instead: `add_actual_query_to_operations`, `add_endpoint_to_routes`, etc.
- **Never use model classes inside `up` migrations for data backfills.** `Model.where(...).update_all(...)` checks out a connection from the model's pool. On separate-database setups with SQLite, the column added earlier in the same migration transaction is invisible to that second pool, causing the migration to roll back. Always use `execute(<<~SQL ... SQL)` for data changes within migrations — `execute` runs on the migration's own connection and sees all DDL performed in the same transaction.

Full architecture details: `docs/database_setup.md`

## Running Tests

```bash
DB=sqlite3 rake test           # Default (SQLite3); use rake, NOT `rails test`
DB=postgresql rake test        # PostgreSQL
rake test_matrix               # All DBs × Rails versions (pre-release validation)
BROWSER=true rake test_matrix  # Include system tests
```

Tests are parallelized by default. System tests (`BROWSER=true`) disable parallelization automatically.

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

## Architecture Gotchas

**Services are NOT autoloaded by Zeitwerk.** The engine explicitly tells Zeitwerk to ignore `app/services/` and manually autoloads them. If you add a new service, register it in `lib/rails_pulse/engine.rb`.

**RequestStore is thread-local.** Operations are deep-copied before async tracking to prevent race conditions. The `skip_recording_rails_pulse_activity` flag prevents recursive tracking on Rails Pulse's own requests.

**Engine initializer ordering matters.** The initializers in `lib/rails_pulse/engine.rb` use `before:`/`after:` constraints — don't add new initializers without checking order dependencies.

**Ransack requires explicit opt-in.** Every model must define `ransackable_attributes` and `ransackable_associations`. Use `Arel.sql()` for computed fields to ensure cross-database compatibility.

**Configuration validation is strict.** All thresholds, patterns, and database settings are validated at startup — invalid config fails fast.

**Requests index shows individual records, not aggregates.** Routes and Queries controllers use `Tables::Index` classes to query aggregated summary data, but RequestsController queries individual `RailsPulse::Request` records directly. This is intentional — the requests page displays per-request details (occurred_at, status, tags, route links) that would be lost in aggregation.

## Adding a New Feature

1. Add config option to `RailsPulse::Configuration` (`lib/rails_pulse/configuration.rb`)
2. Add model + migration (both paths — see Database Migrations above)
3. Add `ransackable_attributes` to any new model
4. Add fixtures to `test/fixtures/rails_pulse_*.yml`
5. Write tests following conventions in `docs/testing.md`
6. If adding a service, register it manually in the engine

## Frontend / Assets

CSS is plain CSS (not Sass). JS uses Stimulus controllers. Pre-built files live in `/public/rails-pulse-assets/`.

They are **not** registered with Sprockets (`config.assets.precompile`) — re-minifying the ~2 MB bundle OOMs small hosts. After `assets:precompile`, `rails_pulse:install_assets` copies them into the host's `public/assets` with a SHA256 digest so `config.asset_host` and CDN-only CSP work. Development and hosts with no pipeline fall back to `RailsPulse::Middleware::AssetServer` at `/rails-pulse-assets/<gem-version>/...`. Layouts must use `tag.link` / `tag.script` (not `stylesheet_link_tag`) so middleware paths are not rewritten onto the CDN.

To rebuild assets: `npm run build` (or `npm run build:dev` for source maps).

## Releases

Run `rake test_release` before any release — it validates git status, RuboCop, Brakeman, asset build, gem build, generator tests, and the full test matrix. See `docs/releasing.md` for the full process.

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

Single-context repo — `CONTEXT.md` + `docs/adr/` at root. See `docs/agents/domain.md`.
