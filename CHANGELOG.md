# Changelog

All notable changes to Rails Pulse will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Dashboard status bar badges are now all clickable.** Routes, Queries, and Jobs badges link to their respective pages, matching Exceptions and Storage.
- **Standalone auth notice logged once per process.** The "standalone dashboard ignores config.authentication_method / config.authorize" notice kept its once-only flag on each controller class, so it repeated for every engine controller a visitor reached. The flag now lives on `RailsPulse::Standalone` and the notice is logged once per process.

## [0.4.0.pre.4] - 2026-09-07

## [0.4.0.pre.3] - 2026-09-06

### Added

- **Shell-based deployment tracking.** `rake rails_pulse:record_deployment` and the new `rake rails_pulse:finish_deployment[revision]` let release scripts record and close deployments without the HTTP API or a token.
- **Standalone mode improvements.** Dashboard links now resolve correctly when served at `/`, and a new `config.standalone_authentication_method` (with an HTTP Basic fallback) replaces host-app authentication, which the standalone process can't use.
- **`rails rails_pulse:status`.** Reports schema, migration, and tracking/auth config state in one command, and exits 1 if anything needs action before deploying.
- **Schema drift guard.** `RailsPulse::SchemaCheck` detects tables or columns the running gem expects but that haven't been migrated yet, and pauses tracking (dashboard returns 503) with a clear warning instead of erroring. Disable with `config.schema_check_enabled = false`.

### Fixed

- Fixed breadcrumb links becoming protocol-relative (`//queries`) when the engine is mounted at `/`.
- Fixed the standalone dashboard server 404ing on its own stylesheets and scripts.
- Fixed asset responses using mixed-case headers, which `Rack::Lint` rejects under Rack 3.
- Fixed `rails_pulse_server` ignoring `RAILS_ENV`/`RACK_ENV` and always booting `rackup` in development mode.
- Fixed the standalone server requiring a literal `SECRET_KEY_BASE` instead of falling back to the host app's.

### Security

- Updated development dependencies mail, net-imap, and json for several CVEs (gem dev/CI only).
- Updated development dependencies nokogiri, loofah, and rails-html-sanitizer for several CVEs (gem dev/CI only).
- Updated development dependencies Rails, puma, websocket-driver, and concurrent-ruby for Dependabot's critical/high alerts. Host apps should update their own Rails to 8.1.3.1.

### Changed

- `rails generate rails_pulse:upgrade` now reports unrun migrations and outstanding route backfill instead of saying everything is up to date.
- Cleaned up `rake test` output — no more RDoc warnings, stray blank lines, or leaked log noise.

## [0.4.0.pre.2] - 2026-09-04

### Fixed

- Fixed `rails generate rails_pulse:upgrade` writing a migration that failed to parse when a column comment contained an escaped quote.
- Fixed background tracking writes corrupting the test database connection under transactional tests. Existing installs should add `config.async = false if Rails.env.test?` to their initializer.

## [0.4.0.pre.1] - 2026-09-03

This release contains a **breaking schema change** and requires a one-time data migration. Back up your database first — the route migration is irreversible. See "Upgrading from 0.3.x" below.

### Security

- Job failure messages (`rails_pulse_job_runs.error_message`) are now redacted the same way exception messages are.
- CSRF protection is now declared directly by the engine instead of depending on the host's `load_defaults` version.
- Fixed `authentication_method` granting access when it returned a falsy-but-not-`false`/redirect value; it's now fail-closed.
- Hardened EXPLAIN analysis against SQL injection and added a statement timeout.
- Bounded deployment API input (revision length, metadata size, future timestamps) and capped the `rails_pulse_deployments` row count.
- Backtrace source snippets are now limited to `app/`, `lib/`, and `config/routes.rb`, instead of any file under `Rails.root`.
- The standalone dashboard's session cookie is now `Secure` in production.

### Added

- **Exception tracking.** Captures unhandled exceptions from requests and jobs, with grouping, backtraces, and redacted params in a new Exceptions tab.
- **`track_exceptions` config option**, off by default for existing installs and on by default for new ones.
- **`capture_exception_params` config option** to include filtered request params with each exception occurrence.
- **`exception_message_filter` config option** for app-specific redaction beyond the built-in rules.
- **`authorize` config option** — a fail-closed predicate for gating dashboard access; now the recommended approach.
- **The upgrade generator now syncs new initializer settings** into the host's config file without overwriting existing values.

### Changed

- **BREAKING — route identity is now `[controller_action, path]`**, so different HTTP methods on the same path are tracked as distinct routes.
- **A one-time `rails rails_pulse:migrate_routes` backfill is required** after migrating; a schema migrate alone leaves the Action column empty.
- **The JavaScript bundle is 66% smaller** (2.19 MB → 759 KB) after tree-shaking ECharts.

### Removed

- **BREAKING — `rails_pulse_routes.method` is dropped**; the HTTP verb now lives on each request. Restart all processes together after migrating.
- **BREAKING — the route migration is irreversible.** Back up your database first.
- Removed three unused Stimulus controllers (`form`, `timezone`, `period_selector`).
- Removed `theme.js`, a chart theme that was immediately overwritten and would have defeated ECharts tree-shaking.
- Removed dead CSS: unused css-zero ports, old period-selector styles, and a disabled toolbox option.
- `csp-test.js` is no longer shipped in the published gem.

### Fixed

- Fixed tag filters not matching tags containing `_` on SQLite.
- Fixed various hand-edited or malformed query strings causing 500s instead of falling back to defaults.
- Fixed chart click/zoom handlers accumulating on every chart tab switch, slowing clicks down over time.
- Fixed zooming to the first column of a category chart resetting the range instead of applying it.
- Fixed hover popovers throwing after a table refresh replaced the underlying element.
- Fixed the time range selector's hover border being invisible due to an undefined CSS variable.
- Fixed a duplicate CSS rule that made popover placement depend on file load order.
- Fixed upgrading when using a separate database installation.
- Separate-database installs now set `schema_dump: false` so `db:migrate` doesn't dump or load `db/rails_pulse_structure.sql` (#189).
- Fixed `assets:precompile` OOMing on memory-constrained hosts by not registering dashboard assets with Sprockets.
- Fixed SQLite's `schema.rb` dropping the partial unique index on unrecognised routes, which over-constrained paths on `db:schema:load`.

### Upgrading from 0.3.x

Applies to every 0.3.x release (0.3.0 through 0.3.3). **Back up your database first.**

```bash
bundle update rails_pulse
rails generate rails_pulse:upgrade
rails db:migrate                  # separate Pulse database: rails db:migrate:rails_pulse
rails rails_pulse:migrate_routes  # required — schema migrate alone leaves Action empty
```

Then restart **all** processes together, not as a rolling deploy.

Separate-database hosts: add `schema_dump: false` to the `rails_pulse` entry in
`config/database.yml` and delete `db/rails_pulse_structure.sql` if it exists. Do not
run `db:setup` / `db:prepare` as a substitute for `db:migrate:rails_pulse`.

Exception tracking stays off after upgrading. Set `config.track_exceptions = true`
once you have reviewed what is captured.

## [0.3.3] - 2026-06-23

- **Deployment tracking** — Record deployments via `POST /rails_pulse/deployments` or `rake rails_pulse:record_deployment[sha]`, shown as marker lines on performance charts.
- **`deployment_api_token` config option** — Secures the deployments endpoint with a token header for CI/CD use.
- Charts now use a native ECharts time axis instead of a separate labels array, enabling deployment markers and better zoom behaviour.

## [0.3.0] - 2026-04-30

This is the largest release to date — a full UI overhaul with switchable charts and
automatic health status across the dashboard. Existing installs need to run two new
migrations.

### Added

- **New chart types across all sections** — Routes, queries, and jobs now have dedicated, switchable chart panels (percentiles, volume, error/failure rate, duration)
- **Dashboard health summary** — New `HealthSummary` model surfaces an overall health status and highlights routes/queries/jobs that need attention
- **Dashboard "Needs Attention" section** — Automatically surfaces slow routes, high error rates, and problematic jobs without manual digging
- **Storage pressure indicator** — Tracks and displays database storage growth so you know when to adjust retention settings
- **Flame graph view for requests** — Request detail pages now include a flame graph visualisation of operation timing
- **P95 duration tracking for jobs** — Job runs now record and display p95 duration alongside average duration
- **Database load metric for queries** — New card and chart tracking cumulative database load (execution count × avg duration) over time
- **Diagnostic fields for queries** — Query show pages now surface diagnostic information alongside existing analysis
- **Chart series toggle** — Show/hide individual series on charts without leaving the page
- **Performance status concern** — Shared `HasPerformanceStatus` concern for models that report a health status
- **Metric strip component** — New compact summary strip component for displaying multiple metrics inline
- **Setup banner** — Onboarding banner shown to users who haven't completed setup
- **Time range selector** — Redesigned time range UI with a custom date range option
- **Suggestions service** — Query show pages surface optimisation suggestions (caching, controller, SQL, HTTP, view) via dedicated suggestion services
- **Statistics module** — New `RailsPulse::Statistics` module for shared statistical calculations
- **Cleanup stats reporter** — Detailed reporting on what the cleanup job removed each run
- **Cleanup task runner** — Extracted cleanup orchestration into `CleanupTaskRunner` for testability
- **Config and migration installers** — Extracted install/upgrade logic into `ConfigInstaller` and `MigrationInstaller` classes
- **Schema parser** — New `SchemaParser` for reading and diffing schema state during upgrades
- **Icon helper** — Centralised `IconHelper` for rendering SVG icons
- **Route helper** — Centralised `RouteHelper` for building internal dashboard links
- **CSP helper** — Dedicated `CspHelper` for content security policy nonce management
- **Backfill summaries job** — New job to backfill summary records for historical data

### Changed

- **Dashboard redesigned** — Full overhaul with health summary, attention sections, and chart panels replacing the previous card layout
- **Routes, queries, and jobs index pages redesigned** — Consistent layout with metric cards, switchable chart tabs, and paginated tables
- **Metric card component updated** — Cards now support a richer data structure with trend indicators
- **Application controller refactored** — Split into focused concerns (`ChartTableConcern`, `MetricCardConcern`, `PaginationConcern`, `SessionFiltersConcern`, `TagFilterConcern`, `TimeRangeConcern`, `ZoomRangeConcern`)
- **`normalized_sql` column expanded to `text`** — Removes the 1000-character limit on PostgreSQL and MySQL (migration provided)
- **Diagnostic fields added to queries table** — New columns captured at instrumentation time
- **Summary job and service refactored** — Cleaner separation between job scheduling and summary calculation logic
- **Cleanup job refactored** — Now uses `CleanupTaskRunner` and reports statistics via `CleanupStatsReporter`
- **Configuration expanded** — New configuration options exposed in the initializer template
- **Upgrade generator simplified** — Now delegates to `MigrationInstaller` and `ConfigInstaller`
- **Asset server middleware updated** — Improved asset serving reliability
- **Request collector middleware updated** — Performance improvements and cleaner instrumentation
- **Operation subscriber refactored** — Cleaner event handling and reduced complexity
- **Seeds refactored** — Dummy app seeds split into focused files under `db/seeds/rails_pulse/`
- **Test coverage significantly expanded** — Controller concerns, helpers, models, services, and system tests all substantially extended

### Removed

- `StatusHelper` removed — status rendering consolidated into model concerns and view components
- `ChartFormatters` helper removed — chart formatting moved into chart model classes
- Slow queries and slow routes table models removed — replaced by the Needs Attention system
- Unused `average_response_time` and `p95_response_time` dashboard chart classes removed
- `requests/tables/index.rb` removed — requests index now uses a shared approach
- `routes/cards/average_response_times` and `routes/charts/average_response_times` removed — replaced by percentile-based equivalents
- `jobs/cards/average_duration` and `jobs/cards/total_jobs` removed — replaced by updated cards
- Timezone controller removed
- Application mailer stub removed

## [0.2.7] - 2026-04-17

No changelog entry — see git history.

## [0.2.6] - 2026-04-15

No changelog entry — see git history.

## [0.2.5] - 2026-04-14

No changelog entry — see git history.

[Unreleased]: https://github.com/railspulse/rails_pulse/compare/v0.4.0.pre.1...HEAD
[0.4.0.pre.1]: https://github.com/railspulse/rails_pulse/compare/v0.3.3...v0.4.0.pre.1
[0.3.3]: https://github.com/railspulse/rails_pulse/compare/v0.3.2...v0.3.3
[0.3.0]: https://github.com/railspulse/rails_pulse/compare/v0.2.7...v0.3.0
[0.2.7]: https://github.com/railspulse/rails_pulse/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/railspulse/rails_pulse/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/railspulse/rails_pulse/releases/tag/v0.2.5
