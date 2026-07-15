# Database setup & migrations

How Rails Pulse’s schema architecture works for **people building the gem**. End-user install walkthroughs also live on [railspulse.com](https://railspulse.com); keep the three-path rules here and in `AGENTS.md` in sync.

## Three paths (must stay aligned)

| Path | Role |
|------|------|
| `db/rails_pulse_schema.rb` | Source of truth for the **complete** schema. Fresh installs only: `table_exists?` guards; never alter existing tables. |
| `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb` | Must match the source of truth. Copied into host apps by `rails generate rails_pulse:install`. |
| `db/rails_pulse_migrate/` | Incremental migrations for upgrades. Copied by `rails generate rails_pulse:upgrade`. |

Install creates a host migration that loads and executes `db/rails_pulse_schema.rb`. Upgrade copies new gem migrations (and can detect missing columns as a safety net).

### When adding a column or table

1. Update `db/rails_pulse_schema.rb` (fresh installs).
2. Update `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb` identically.
3. Add `db/rails_pulse_migrate/TIMESTAMP_description.rb` with `column_exists?` / `table_exists?` guards.
4. For **new tables only**, add the name to `RAILS_PULSE_TABLES` in `lib/generators/rails_pulse/base_methods.rb`.
5. Update `test/migrations/upgrade_migration_test.rb` (`MIGRATION_CLASSES` in filename sort order + post-upgrade assertion).
6. Run `rake test_migrations` and `rake sync_test_schema` (dummy app must mirror the schema).

Example incremental migration:

```ruby
class AddPriorityToJobs < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:rails_pulse_jobs, :priority)
      add_column :rails_pulse_jobs, :priority, :integer, default: 0
    end
  end
end
```

### Migration naming

Avoid acronyms in filenames (`sql`, `url`, `id`). Host apps with custom inflections can camelize them differently and raise `NameError`. Prefer full words (`add_actual_query_to_operations`).

### Data changes in migrations

Never use model classes inside `up` for backfills (`Model.where.update_all`). That checks out a second pool and can miss DDL from the same migration on separate-database SQLite setups. Use `execute(<<~SQL ... SQL)` on the migration connection.

## Host install / upgrade (overview)

Generators accept `--database=single` (default) or `--database=separate`.

```bash
rails generate rails_pulse:install
# or: rails generate rails_pulse:install --database=separate
rails db:migrate          # single DB
# separate DB typically: configure database.yml, then rails db:prepare
```

```bash
rails generate rails_pulse:upgrade
# or: rails generate rails_pulse:upgrade --database=separate
rails db:migrate
# separate: rails db:migrate:rails_pulse
```

For separate DB, host `database.yml` should set `migrations_paths: db/rails_pulse_migrate` on the rails_pulse connection (as shown by the install generator message).

## `convert_to_migrations`

`rails generate rails_pulse:convert_to_migrations` turns the host’s `db/rails_pulse_schema.rb` into an install migration under `db/migrate/` when:

- the schema file exists, and
- Rails Pulse tables are **not** already present.

If tables already exist, the generator exits and points you at `rails generate rails_pulse:upgrade`. The upgrade generator also prints this convert flow when it detects a schema file but no tables (intended path toward a single-database migration workflow).

There is **no** gem-provided `db:dump:rails_pulse` / `db:restore` task. Moving data between separate and single databases is a DBA concern outside this generator.

## Schema file behavior

Safe to re-run for creates: skips tables that already exist. Does **not** add/modify/remove columns or indexes on existing tables. Existing installs must use incremental migrations.

## Test / dummy app

- `test/dummy/db/rails_pulse_schema.rb` must mirror `db/rails_pulse_schema.rb`.
- `rake sync_test_schema` copies them (also runs during test setup / `test_release`).
- `.githooks/post-checkout` warns when dummy `schema.rb` came from another branch (Rails 8.1 can load `schema.rb` instead of migrating on a fresh DB).

## Troubleshooting (host apps)

**“Rails Pulse not detected”** — run install + migrate first.

**Missing columns after gem update** — `rails generate rails_pulse:upgrade` then migrate.

**Tables already exist / branch switches** — install and schema paths are idempotent for existing tables; `db:migrate` / `db:prepare` are safe to retry. For a clean local DB: drop/create then migrate or prepare.

**Schema file** — keep `db/rails_pulse_schema.rb` in the host app; upgrade detection relies on it.
