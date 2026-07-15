# Rails Pulse Release Process

## Quick Start

```bash
bin/release
```

Interactive release. HTML session log (requires `aha`, e.g. `brew install aha`):

```bash
bin/release-log
```

Output: `tmp/release-YYYYMMDD-HHMMSS.html`.

## Manual Release

### 1. Pre-Release Testing

```bash
rake test_release
```

`test_release` in the Rakefile runs **14 steps**:

1. Appraisal gemfile install (`bundle exec appraisal install`)
2. Test schema sync (`rake sync_test_schema`)
3. Dummy app migration verification (`rake verify_dummy_migrations`)
4. Clean git working tree
5. RuboCop
6. Brakeman
7. `npm install`
8. `npm run lint:js`
9. `npm run test:js`
10. `npm run build` (checks `public/rails-pulse-assets`, `vendor/assets/stylesheets`, `vendor/assets/javascripts`)
11. `gem build rails_pulse.gemspec`
12. Generator tests (`./bin/test_generators`)
13. Migration regression (`rake test_migrations`)
14. Full test matrix (`rake test_matrix`: 3 DBs × 3 Rails Appraisal lines, including `test/system` headless)

#### Separate-DB Upgrade Smoke Test

**Required when the release includes any new migration.** `test_release` exercises the single-database path only.

1. Temporarily uncomment `config.connects_to` in `test/dummy/config/initializers/rails_pulse.rb` and point it at a fresh SQLite file:
   ```ruby
   config.connects_to = { database: { writing: :rails_pulse, reading: :rails_pulse } }
   ```

2. Load a historical schema baseline (widest upgrade path uses V027):
   ```ruby
   conn = RailsPulse::ApplicationRecord.connection
   RailsPulse::TestSchemas::V027.call(conn)
   ```

3. Insert at least one SQL operation row so backfill migrations have data (adjust SQL for your adapter):
   ```ruby
   conn.execute("INSERT INTO rails_pulse_routes (method, path, created_at, updated_at) VALUES ('GET', '/test', datetime('now'), datetime('now'))")
   route_id = conn.select_value("SELECT id FROM rails_pulse_routes LIMIT 1")
   conn.execute("INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at) VALUES (#{route_id}, 10.0, 200, 0, 'test-uuid', datetime('now'), datetime('now'), datetime('now'))")
   request_id = conn.select_value("SELECT id FROM rails_pulse_requests LIMIT 1")
   conn.execute("INSERT INTO rails_pulse_operations (request_id, operation_type, label, duration, start_time, occurred_at, created_at, updated_at) VALUES (#{request_id}, 'sql', 'SELECT * FROM users', 5.0, 0.0, datetime('now'), datetime('now'), datetime('now'))")
   ```

4. From the dummy app, run upgrade **without** `--database=separate` to exercise auto-detection:
   ```bash
   cd test/dummy && bin/rails generate rails_pulse:upgrade
   # Expected: "Detected database setup: separate"
   ```

5. Migrate and verify:
   ```bash
   bin/rails db:migrate:rails_pulse
   bin/rails runner "puts RailsPulse::Operation.first&.actual_sql"
   # Expect the SQL that was stored for backfill (label-derived when that migration is included)
   ```

6. Restore the initializer (comment `connects_to` out) and delete the temporary SQLite file.

### 2. Update Version

```bash
bin/bump_version 0.3.0
```

Updates:

- `lib/rails_pulse/version.rb`
- `Gemfile.lock`
- `gemfiles/rails_7_2.gemfile.lock`
- `gemfiles/rails_8_0.gemfile.lock`
- `gemfiles/rails_8_1.gemfile.lock`

Pre-release versions use **dots**, not hyphens: `0.3.0.pre.1`, `0.3.0.beta.1`, `0.3.0.rc.1`.

### 3. Commit Changes

```bash
bin/commit_release 0.3.0
```

Creates commit: `Bump version to v0.3.0`

### 4. Create Git Tag

```bash
bin/tag_release 0.3.0
```

Opens an editor for release notes (optional draft from history), or:

```bash
bin/tag_release 0.3.0 --notes "Bug fixes and improvements"
```

### 5. Push to GitHub

```bash
bin/push_release --wait-ci
```

Requires `gh` if waiting on CI.

### 6. Publish Gem

```bash
bin/publish_gem
```

Prerequisites: `npm run build` already done (or fresh), `gem signin` for RubyGems. Builds, publishes, moves the `.gem` into `pkg/`.

### 7. Create GitHub Release

https://github.com/railspulse/rails_pulse/releases/new

## Individual Scripts

```bash
bin/release --help
bin/release-log --help
bin/bump_version --help
bin/commit_release --help
bin/tag_release --help
bin/push_release --help
bin/publish_gem --help
```

## Quick Reference

```bash
bin/release-log   # full interactive release with HTML log
bin/release

rake test_release
bin/bump_version 0.3.0
bin/commit_release 0.3.0
bin/tag_release 0.3.0
bin/push_release --wait-ci
bin/publish_gem
```

**Emergency yank (avoid):** `gem yank rails_pulse -v 0.3.0`

## Version Guidelines

[Semantic Versioning](https://semver.org/): MAJOR breaking, MINOR features, PATCH fixes. Pre-release suffixes use dots.
