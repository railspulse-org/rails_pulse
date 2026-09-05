# Rails Pulse Database Setup & Migrations

Rails Pulse uses a **schema file as the single source of truth** for database structure. This provides clean installations for new users while supporting incremental migrations for upgrades.

## Overview

- **Master Schema File**: Defines all tables and columns in one place
- **Clean Installation**: New users get the complete schema at once
- **Incremental Upgrades**: Existing users get migrations for new features
- **Two Setup Options**: Single database (recommended) or separate database

## Installation

### Option 1: Single Database (Recommended)

Use your existing Rails database for Rails Pulse tables.

```bash
rails generate rails_pulse:install
rails db:migrate
```

This creates:
- `config/initializers/rails_pulse.rb` - Configuration
- `db/rails_pulse_schema.rb` - Schema definition (single source of truth)
- `db/migrate/TIMESTAMP_install_rails_pulse_tables.rb` - Installation migration
- `db/rails_pulse_migrate/.keep` - Directory for future migrations

### Option 2: Separate Database

Use a dedicated database for Rails Pulse data.

```bash
rails generate rails_pulse:install --database=separate
```

Then configure `config/database.yml`:

```yaml
development:
  rails_pulse:
    <<: *default
    database: storage/development_rails_pulse.sqlite3
    migrations_paths: db/rails_pulse_migrate
    schema_dump: false

production:
  rails_pulse:
    adapter: postgresql
    database: myapp_rails_pulse
    username: <%= ENV['DB_USERNAME'] %>
    password: <%= ENV['DB_PASSWORD'] %>
    host: <%= ENV['DB_HOST'] %>
    migrations_paths: db/rails_pulse_migrate
    schema_dump: false
```

Then uncomment `config.connects_to` in `config/initializers/rails_pulse.rb`:

```ruby
config.connects_to = {
  database: { writing: :rails_pulse, reading: :rails_pulse }
}
```

Without this setting, all Pulse models write to the primary connection
even when the separate database exists.

`schema_dump: false` is required. Rails Pulse loads schema from `db/rails_pulse_schema.rb` during `db:prepare`. Without that key, Rails dumps `db/rails_pulse_structure.sql` (or overwrites `db/rails_pulse_schema.rb`) and `db:migrate` can fail with `relation already exists`. Leave `database_tasks` enabled so `rails db:migrate:rails_pulse` still applies upgrades.

Finally, create the database:

```bash
rails db:prepare
```

## Upgrading Rails Pulse

When you upgrade to a new version of Rails Pulse that includes new features, run the upgrade generator:

### For Single Database

```bash
rails generate rails_pulse:upgrade
rails db:migrate
rails rails_pulse:migrate_routes
```

### For Separate Database

```bash
rails generate rails_pulse:upgrade --database=separate
rails db:migrate:rails_pulse
rails rails_pulse:migrate_routes
```

### What the Upgrade Generator Does

1. **Copies new migrations** from the gem to your app
2. **Detects missing columns** by comparing your database to the schema file (safety net)
3. **Reports what is still outstanding** when every migration file is already present: files that have not been run against this database, and a route backfill that has not been done — rather than calling the install "up to date"
4. **Provides clear instructions** for next steps, including `rails rails_pulse:migrate_routes` when a release needs a data backfill

The generator automatically handles both upgrade paths:
- If new migrations exist in the gem → copies them to your app
- If no new migrations but missing columns → generates a migration for you

### Route identity backfill

Route identity is `[controller_action, path]`. Schema migrations add the new columns and move the HTTP verb onto each request; they do **not** collapse GET `/users` and POST `/users` into one row.

After migrating, run:

```bash
rails rails_pulse:migrate_routes
```

This backfills `controller_action` from the host router, normalizes historical `/posts/42` paths to `/posts/:id`, merges routes that share the same action, and adds a unique index for unrecognized (404) paths.

If you skip this step, the Action column on the routes page stays empty. The dashboard shows a banner with the same command until a live route still has a blank action.

### Deploy order

This release drops `rails_pulse_routes.method`. Do not run mixed 0.3.3 and new processes against the migrated schema. Typical flow:

1. `bundle update` / deploy the new gem
2. `rails generate rails_pulse:upgrade`
3. `rails db:migrate` (or `db:migrate:rails_pulse`)
4. `rails rails_pulse:migrate_routes`
5. Restart **all** processes before serving traffic

Release-phase migrate (Heroku, Kamal) is fine if no old processes remain after the release. A rolling restart that leaves 0.3.3 processes running against the new schema will 500 the routes dashboard and silently drop request tracking.

Exception tracking stays **off** for existing installs. After migrating, set `config.track_exceptions = true` to opt in.

## Troubleshooting

### "Rails Pulse not detected"

Run the install generator first:

```bash
rails generate rails_pulse:install
rails db:migrate
```

### Missing columns after gem update

The upgrade generator detects and fixes this automatically:

```bash
rails generate rails_pulse:upgrade
rails db:migrate
```

### Database already exists error

If you see "database already exists" when running migrations:

**For single database:**
```bash
rails db:migrate:status  # Check if installation migration already ran
```

**For separate database:**
```bash
rails db:migrate:status:rails_pulse
```

### Schema file should not be deleted

The file `db/rails_pulse_schema.rb` is your single source of truth for the database structure. Keep this file even after running migrations - it's used by the upgrade generator to detect missing columns.

### `db:migrate` fails on `rails_pulse_structure.sql`

If `db:migrate` errors with `relation "rails_pulse_deployments" already exists` while loading `db/rails_pulse_structure.sql`, Rails is dump/loading the Pulse database as a second schema.

Add `schema_dump: false` to the `rails_pulse` entry in `config/database.yml` and delete `db/rails_pulse_structure.sql` if that file exists. Do not set `database_tasks: false`; that skips `db:migrate:rails_pulse`.

### Tables already exist error

If you see "table already exists" when running migrations, this usually happens when switching between branches or after a database restore.

**Cause**: The database has tables from a previous installation, but migrations are trying to create them again.

**Solution for single database:**
```bash
# Option 1: Drop and recreate (development only!)
rails db:drop db:create db:migrate

# Option 2: Skip to latest migration (if tables are correct)
rails db:migrate:status  # Check current state
# If install migration shows as "down" but tables exist, just run:
rails db:migrate  # The install migration is now idempotent and will skip existing tables
```

**Solution for separate database:**
```bash
# Option 1: Drop and recreate
rails db:drop db:create db:prepare

# Option 2: The schema file has built-in safety checks
rails db:prepare  # Will skip tables that already exist
```

**Why this is safe now**: As of v0.3+, both the install migration and schema file check if tables exist before creating them, so running migrations multiple times is safe.

### Branch switching workflow

When switching between git branches with different Rails Pulse versions:

**Single Database Setup:**
```bash
git checkout feature-branch
bundle install
rails db:migrate  # Idempotent - safe to run even if tables exist
```

**Separate Database Setup:**
```bash
git checkout feature-branch
bundle install
rails db:prepare  # Schema file will skip existing tables
```

**If you want a clean state:**
```bash
git checkout feature-branch
bundle install
rails db:drop db:create
rails db:migrate  # (single DB) or rails db:prepare (separate DB)
rails db:seed
```

### Running migrations twice

As of v0.3+, you can safely run migrations multiple times:

```bash
rails db:migrate
rails db:migrate  # Safe! Will skip tables that already exist
```

The install migration checks if Rails Pulse tables exist before creating them, and the schema file has similar safety checks.

## Architecture

### How Installation Works

1. **Schema File**: The gem ships with a complete schema definition
2. **Installation**: Copies schema to your app as `db/rails_pulse_schema.rb`
3. **Migration**: Creates a migration that loads and executes the schema
4. **Result**: All tables and columns created in one go

### How Upgrades Work

1. **New Feature Released**: Gem ships with new migration in `db/rails_pulse_migrate/`
2. **Bundle Update**: You update the gem version
3. **Upgrade Generator**: Copies new migration(s) to your app
4. **Rails Migrate**: You run the migration to apply changes

### Schema File Behavior

The schema file (`db/rails_pulse_schema.rb`) is designed for **fresh installations only**. It has important safety characteristics:

**What it does:**
- ✅ Creates missing tables
- ✅ Skips tables that already exist
- ✅ Safe to run multiple times
- ✅ Provides logging of what it's creating

**What it does NOT do:**
- ❌ Add columns to existing tables
- ❌ Modify existing columns
- ❌ Remove columns from tables
- ❌ Change indexes on existing tables

**Why this matters:**
The schema file represents the "ideal final state" for new installations. For existing installations, **you must use incremental migrations** to modify table structure.

**How it works with migrations:**
The install migration (created by `rails generate rails_pulse:install`) loads and executes the schema file. This provides a clean, single-migration installation for new users while maintaining a schema file as the source of truth. The migration uses `Rails.root.join("db/rails_pulse_schema.rb")` to locate the schema file that was copied to your app during installation.

**Example - Adding a new column:**

When adding a new feature that requires a database column:

1. Create an incremental migration in `db/rails_pulse_migrate/`:
   ```ruby
   # db/rails_pulse_migrate/20250120000000_add_priority_to_jobs.rb
   class AddPriorityToJobs < ActiveRecord::Migration[7.0]
     def change
       unless column_exists?(:rails_pulse_jobs, :priority)
         add_column :rails_pulse_jobs, :priority, :integer, default: 0
       end
     end
   end
   ```

2. Update **both** schema files to include the column (for new installations):
   ```ruby
   # db/rails_pulse_schema.rb  (source of truth)
   # lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb  (generator template — must match!)
   unless connection.table_exists?(:rails_pulse_jobs)
     connection.create_table :rails_pulse_jobs do |t|
       # ... existing columns ...
       t.integer :priority, default: 0  # New column for fresh installs
     end
   end
   ```

   > **Important**: The generator template at `lib/generators/rails_pulse/templates/db/rails_pulse_schema.rb`
   > is what gets copied into users' apps when they run `rails generate rails_pulse:install`. It must be
   > kept in sync with `db/rails_pulse_schema.rb` — failing to update it means fresh installs will be
   > missing the new column even though the source of truth is correct.

3. **For new tables only**: Add the table name to `RAILS_PULSE_TABLES` in `lib/generators/rails_pulse/base_methods.rb`. This list is the fallback used when the upgrade generator cannot parse the host app's `db/rails_pulse_schema.rb`, so it must stay in sync with the actual set of tables.

4. Update the migration regression tests in `test/migrations/upgrade_migration_test.rb`:
   - Add the new class name to `MIGRATION_CLASSES` (in filename sort order)
   - Add an assertion verifying the new column/table exists after upgrading from v0.2.7
   - Run `rake test_migrations` to verify

5. Users run the upgrade generator to get the migration:
   ```bash
   rails generate rails_pulse:upgrade
   rails db:migrate
   ```

This approach ensures:
- **Fresh installations** get the complete schema with all columns (via install migration loading schema file)
- **Existing installations** get the incremental migration to add the column
- **Safety** - the schema file never modifies existing tables
- **Single source of truth** - the schema file shows the current complete structure

**Test/Dummy App Setup:**
For Rails engine development (like Rails Pulse itself), the test/dummy app needs both:
1. The schema file at `test/dummy/db/rails_pulse_schema.rb` (synced from gem's `db/rails_pulse_schema.rb`)
2. The install migration at `test/dummy/db/migrate/TIMESTAMP_install_rails_pulse_tables.rb`

The `rake sync_test_schema` task keeps the test schema in sync with the gem schema. This runs automatically before test setup.

### Benefits

- **Clean for new users**: One migration installs everything
- **Safe for existing users**: Incremental migrations with safety checks
- **Automatic detection**: Upgrade generator catches skipped migrations
- **Standard Rails**: Familiar migration workflow
- **Reviewable changes**: See exactly what's changing before running migrations
- **Idempotent**: Schema file and migrations can run multiple times safely

## Examples

### Fresh Installation

```bash
# Install Rails Pulse
rails generate rails_pulse:install

# Create tables
rails db:migrate

# Start using Rails Pulse!
```

### Upgrading After Gem Update

```bash
# Update gem
bundle update rails_pulse

# Check for and copy new migrations
rails generate rails_pulse:upgrade

# Apply changes
rails db:migrate
rails rails_pulse:migrate_routes

# Restart server
rails restart
```

### Converting from Separate to Single Database

```bash
# 1. Export data from separate database
rails db:dump:rails_pulse > rails_pulse_backup.sql

# 2. Update database.yml (remove rails_pulse configuration)

# 3. Re-install in main database
rails generate rails_pulse:install --database=single
rails db:migrate

# 4. Import data
rails db:restore < rails_pulse_backup.sql
```
