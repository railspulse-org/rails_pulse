# Rails Pulse Release Process

## Quick Start

Run the interactive release script:

```bash
bin/release
```

This guides you through the entire release process automatically.

To capture the full session as an HTML report (useful for reviewing step output afterward):

```bash
bin/release-log   # requires aha: brew install aha / sudo pacman -S aha / apt install aha
```

Output is saved to `tmp/release-YYYYMMDD-HHMMSS.html` and opened automatically when the session ends.

## Manual Release

If you prefer to run steps individually:

### 1. Pre-Release Testing

Run comprehensive pre-release tests:

```bash
rake test_release
```

This runs 14 steps, in order:

1. Git status (clean working directory)
2. Appraisal gemfile sync
3. Test schema sync
4. Dummy app migration verification
5. RuboCop
6. Brakeman security scan
7. Node dependency install
8. ESLint (`npm run lint:js`)
9. JavaScript unit tests (`npm run test:js`)
10. Production asset build
11. Gem build verification
12. Generator tests (install + upgrade)
13. Migration regression tests (`rake test_migrations`)
14. Full test matrix (all databases × Rails versions)

The list lives in `Rakefile` under `test_release`; keep this section in step with it.

#### Separate-DB Upgrade Smoke Test

**Required when the release includes any new migration.**

The automated suite runs single-database only. Run this manual check to verify the
separate-database upgrade path before shipping:

1. Temporarily uncomment `config.connects_to` in
   `test/dummy/config/initializers/rails_pulse.rb` and point it at a fresh SQLite file:
   ```ruby
   config.connects_to = { database: { writing: :rails_pulse, reading: :rails_pulse } }
   ```

2. Load a historical schema baseline into that database (use the V027 schema to test the
   widest upgrade path):
   ```ruby
   # In a rails console or one-off script in the dummy app:
   conn = RailsPulse::ApplicationRecord.connection
   RailsPulse::TestSchemas::V027.call(conn)
   ```

3. Insert at least one SQL operation row so any data-backfill migration has real rows to
   process:
   ```ruby
   conn.execute("INSERT INTO rails_pulse_routes (method, path, created_at, updated_at) VALUES ('GET', '/test', datetime('now'), datetime('now'))")
   route_id = conn.select_value("SELECT id FROM rails_pulse_routes LIMIT 1")
   conn.execute("INSERT INTO rails_pulse_requests (route_id, duration, status, is_error, request_uuid, occurred_at, created_at, updated_at) VALUES (#{route_id}, 10.0, 200, 0, 'test-uuid', datetime('now'), datetime('now'), datetime('now'))")
   request_id = conn.select_value("SELECT id FROM rails_pulse_requests LIMIT 1")
   conn.execute("INSERT INTO rails_pulse_operations (request_id, operation_type, label, duration, start_time, occurred_at, created_at, updated_at) VALUES (#{request_id}, 'sql', 'SELECT * FROM users', 5.0, 0.0, datetime('now'), datetime('now'), datetime('now'))")
   ```

4. Run the upgrade generator **without** the `--database=separate` flag to verify
   auto-detection:
   ```bash
   cd test/dummy && bin/rails generate rails_pulse:upgrade
   # Expected: "Detected database setup: separate"
   ```

5. Run the migrations and route data backfill, and verify they complete without rollback:
   ```bash
   bin/rails db:migrate:rails_pulse
   bin/rails rails_pulse:migrate_routes
   ```

6. Verify the schema is current and the backfill ran correctly:
   ```bash
   bin/rails rails_pulse:status
   # Expected: "Schema: up to date", "Routes: actions backfilled, unrecognised-path index present", exit 0
   bin/rails runner "puts RailsPulse::Route.first&.controller_action"
   # Expected: a controller#action string, not blank
   ```

7. Restore the initializer: comment `connects_to` back out and delete the temporary
   SQLite file.

#### Verify assets and version-scoped caching

Dashboard assets are served from `/rails-pulse-assets/<gem-version>/...`, so the
version bump is what busts any CDN cache holding those paths as immutable. After
`assets:precompile`, confirm the logs include `[RailsPulse] Installed N dashboard
assets`.

`npm run build` is a manual step whose output is committed, so confirm the built
files under `public/rails-pulse-assets/` match their sources before tagging.

> Release-specific notes belong in the CHANGELOG's `[Unreleased]` section, not in
> this file.

### 2. Update Version

```bash
bin/bump_version X.Y.Z
```

Updates:
- `lib/rails_pulse/version.rb`
- `Gemfile.lock`
- every `gemfiles/rails_*.gemfile.lock` (discovered from the directory, so a newly
  added Rails version is picked up automatically)
- `test/dummy/Gemfile.lock`

**Pre-release versions:** use dots, not hyphens — `X.Y.Z.pre.1`, `X.Y.Z.beta.1`, `X.Y.Z.rc.1`.

### 3. Commit Changes

```bash
bin/commit_release X.Y.Z
```

Creates commit: `Bump version to vX.Y.Z`

### 4. Create Git Tag

```bash
bin/tag_release X.Y.Z
```

Opens your editor for release notes. Optionally generates a draft from git history.

Or provide notes inline:

```bash
bin/tag_release X.Y.Z --notes "Bug fixes and improvements"
```

### 5. Push to GitHub

```bash
bin/push_release --wait-ci
```

Pushes commits and tags, optionally waits for CI to complete (requires `gh` CLI).

### 6. Publish Gem

```bash
bin/publish_gem
```

Prerequisites:
- Assets built: `npm run build`
- Authenticated with RubyGems: `gem signin`

Builds the gem, publishes to RubyGems.org, and moves the `.gem` file to `pkg/`.

### 7. Create GitHub Release

Visit the GitHub releases page (automatically opens if using `bin/release`):
https://github.com/railspulse/rails_pulse/releases/new

## Individual Scripts

Each script has detailed help:

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

**Full automated release (with HTML log):**
```bash
bin/release-log
```

**Full automated release:**
```bash
bin/release
```

**Manual step-by-step:**
```bash
rake test_release
bin/bump_version X.Y.Z
bin/commit_release X.Y.Z
bin/tag_release X.Y.Z
bin/push_release --wait-ci
bin/publish_gem
```

**Emergency patch only (skips `rake test_release`; CLAUDE.md requires it for every normal release):**
```bash
bin/bump_version X.Y.Z
bin/commit_release X.Y.Z
bin/tag_release X.Y.Z --notes "Critical bug fix"
bin/push_release
bin/publish_gem
```

## Troubleshooting

**RubyGems authentication:**
```bash
gem signin
```

**Assets not built:**
```bash
npm run build
```

**Version already exists:**
Increment version and try again — RubyGems doesn't allow re-publishing.

**CI failed:**
Fix issues, commit fixes, and re-run from step 5.

**Rollback (emergency only):**
```bash
gem yank rails_pulse -v X.Y.Z  # Use sparingly!
```

## Version Guidelines

Rails Pulse follows [Semantic Versioning](https://semver.org/):

- **MAJOR** (1.0.0): Breaking changes
- **MINOR** (0.1.0): New features, backwards-compatible
- **PATCH** (0.0.1): Bug fixes, security patches

Pre-release suffixes use dots: `X.Y.Z.pre.1`, `X.Y.Z.beta.1`, `X.Y.Z.rc.1`
