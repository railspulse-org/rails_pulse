# Migrations

Read before any schema change. The short checklist is in `CLAUDE.md`; this file is the how and the why. Decision 0011 records the choice.

## The three paths

| Path | Used by | Rule |
|---|---|---|
| `db/rails_pulse_schema.rb` | fresh installs | source of truth; `table_exists?` guard on every table; never alters an existing table |
| `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb` | `rails generate rails_pulse:install` | byte-identical copy of the above; the install generator copies it into the host and writes one migration that executes it |
| `db/rails_pulse_migrate/TIMESTAMP_name.rb` | `rails generate rails_pulse:upgrade` | one guarded migration per change; copied into the host's `db/migrate` (single DB) or `db/rails_pulse_migrate` (separate DB) |

## Adding a column or table

1. Add it to `db/rails_pulse_schema.rb`.
2. Copy the schema file over the generator template. `rake sync_test_schema` also copies it to `test/dummy/db/rails_pulse_schema.rb` and runs before tests.
3. Write the incremental migration in `db/rails_pulse_migrate/` with `column_exists?` / `table_exists?` guards. Filenames use full words only: `add_actual_query_to_operations`, never `add_actual_sql_to_operations`, because a host with `inflect.acronym "SQL"` camelizes the class name differently and raises `NameError`.
4. New table: add its name to `RAILS_PULSE_TABLES` in `lib/generators/rails_pulse/base_methods.rb`, the fallback list when the host's schema file cannot be parsed.
5. New column on an existing table: add it to `SENTINEL_COLUMNS` in `lib/rails_pulse/schema_check.rb`, or the schema check will not protect hosts that run the new gem before migrating. `test/lib/rails_pulse/schema_check_test.rb` checks every listed column exists in the schema file.
6. Add the migration class to `MIGRATION_CLASSES` in `test/migrations/upgrade_migration_test.rb` (filename sort order) and an assertion that the column or table exists after upgrading from the v0.2.7 baseline. Run `rake test_migrations`.
7. Add a dummy-app copy under `test/dummy/db/migrate/`. `rake verify_dummy_migrations` fails when the two sets differ.

## Rules inside a migration

- **Never use model classes in `up` for data changes.** `Model.where(…).update_all` checks out a connection from the model's pool; on a separate-database SQLite host that pool cannot see DDL from the migration's own transaction and the migration rolls back. Use `execute(<<~SQL)`.
- Guards on every DDL statement. Hosts run migrations twice more often than you expect (branch switches, restored databases, a retried release phase).
- Irreversible data migrations say so in `down` and in the changelog, and the changelog tells users to back up first.
- A migration that needs a post-migrate task (like `rails_pulse:migrate_routes`) must be safe to run without it, and the dashboard must tell the user the task is outstanding. `Route` action backfill is the existing example: the migration adds columns, the task fills them, `rails_pulse:status` and a dashboard banner report until it is done.
- Adapter-specific DDL lives in `lib/rails_pulse/route_indexes.rb`, not inline. MariaDB is refused there because it lacks functional indexes.

## What the upgrade generator does

`lib/generators/rails_pulse/upgrade_generator.rb`, run by users after `bundle update`:

1. Detects single vs separate database (`--database=` overrides).
2. Copies migrations from `db/rails_pulse_migrate/` that the host does not have.
3. If none are missing, compares the host's tables to its schema file (`detect_missing_columns`) and writes a migration for any gap. This is the safety net for hosts whose migration history is inconsistent.
4. Reports migration files present but not run, and an outstanding route backfill.
5. Syncs new settings into `config/initializers/rails_pulse.rb` (`ConfigUpdater` parses the generator template, so a new option must appear in the template, commented or not, to reach upgraders).
6. Prints next steps, ending with "restart all processes together".

`rails rails_pulse:status` (`lib/rails_pulse/tasks/status_reporter.rb`) reports the same state read-only and exits 1 when something needs action.

## Separate database hosts

`config.connects_to` reroutes every model; without it the separate database is created and stays empty. `schema_dump: false` on the `rails_pulse` entry is required or Rails dumps `db/rails_pulse_structure.sql` and `db:migrate` fails on reload. `database_tasks` must stay enabled for `db:migrate:rails_pulse`. `lib/tasks/rails_pulse.rake` hooks `db:prepare` to load the schema file on that connection. `SummaryService` opens its transaction on the Rails Pulse connection, not the primary; anything else that writes in a transaction must do the same.

## Testing migrations

- `rake test` excludes `test/migrations/` and runs it afterwards in its own process, because the upgrade test rebuilds the database from a v0.2.7 snapshot and destroys fixtures for anything that follows. Never run a bare `rails test` across the repo.
- Baselines live in `test/support/schemas/` (`v0_2_7`, `v0_3_1`, `v0_3_2`, `v0_3_3`). Add one when a release has a schema no existing baseline covers.
- `bin/test_separate_database_upgrade` boots the dummy app with `config.connects_to`, loads a baseline into the separate database and runs upgrade generator, `db:migrate:rails_pulse`, `rails_pulse:migrate_routes` and `rails_pulse:status` end to end. CI runs it on SQLite and PostgreSQL; run it locally before any release that adds a migration.
