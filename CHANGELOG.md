# Changelog

All notable changes to Rails Pulse will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Changed

- The release gate and CI now fail if anything under `app/` branches on `Rails.env`, so a code path the test suite cannot reach can no longer ship. (#273)
### Fixed

- SQL normalization no longer raises `Regexp::TimeoutError` on long queries, which could fail the whole request when N+1 detection ran during collection.
- **Metric card headline numbers now honour the global tag filter.** Disabling a tag changed each card's sparkline but not the number beside it, so the two disagreed. Both are now computed over the same summaries. (#274)

### Changed

- Loosened the `ransack` dependency from `~> 4.0` to `>= 4.0, < 6` so host apps can upgrade to ransack 5 without dropping Rails Pulse.
- `rake test` now refuses to run when the dummy database was last set up for a different adapter, instead of loading that adapter's `schema.rb` and failing two index tests. (#276)

## [0.4.0] - 2026-09-22

Route identity changes in this release and the schema migration is irreversible, so upgrading from any 0.3.x release needs a backup and a one-time data migration. Start with "Upgrading from 0.3.x" below.

### Upgrading from 0.3.x

Applies to every 0.3.x release (0.3.0 through 0.3.3). **Back up your database first.**

```bash
bundle update rails_pulse
rails generate rails_pulse:upgrade
rails db:migrate                  # separate Pulse database: rails db:migrate:rails_pulse
rails rails_pulse:migrate_routes  # required — schema migrate alone leaves Action empty
rails rails_pulse:status          # exits 1 while anything still needs action
```

Then restart **all** processes together, not as a rolling deploy. A 0.3.x process left running against the migrated schema stops tracking and 500s on the routes page. If the new gem is deployed before its migrations run, tracking pauses and the dashboard answers 503 with these commands until the schema is current.

Separate-database hosts: add `schema_dump: false` to the `rails_pulse` entry in `config/database.yml` and delete `db/rails_pulse_structure.sql` if it exists. Do not run `db:setup` / `db:prepare` as a substitute for `db:migrate:rails_pulse`.

The upgrade generator appends this version's new settings to `config/initializers/rails_pulse.rb` without changing existing values; review them with `git diff`. Exception tracking is inserted as `config.track_exceptions = false`; set it to `true` once you have reviewed what is captured. Authentication is now on outside development and test, not only in production, so configure `config.authorize` before deploying to staging.

### Security

- Job failure messages (`rails_pulse_job_runs.error_message`) are redacted the same way exception messages are.
- CSRF protection is declared directly by the engine instead of depending on the host's `load_defaults` version.
- Authentication hooks fail closed: an `authentication_method` that returns a falsy-but-not-`false` or redirect value no longer grants access, and authentication is on by default outside development and test rather than only in production.
- EXPLAIN analysis is hardened against SQL injection and runs under a statement timeout.
- Deployment API input is bounded (revision length, metadata size, future timestamps) and the deployments table is capped.
- Backtrace source snippets are limited to `app/`, `lib/` and `config/routes.rb` instead of any file under `Rails.root`.
- The standalone dashboard's session cookie is `Secure` in production.
- Development dependencies updated for several CVEs (gem dev/CI only). Host apps should keep their own Rails current.

### Added

- **Exception tracking.** Unhandled exceptions from requests and jobs are grouped by class and location, with backtraces and redacted params, in a new Exceptions tab. Off after an upgrade and on for new installs (`config.track_exceptions`); `config.capture_exception_params` and `config.exception_message_filter` control what is stored.
- **`config.authorize`**, a fail-closed predicate for gating dashboard access and now the recommended way to secure it.
- **Schema drift guard.** When the gem is newer than its tables (deployed before `db:migrate`, or a rolling restart), tracking pauses and the dashboard answers 503 with the upgrade commands instead of erroring on every request. `config.schema_check_enabled = false` turns it off.
- **`rails rails_pulse:status`** reports schema, migration, route backfill, initializer and summary state in one command and exits 1 when something needs action.
- **Shell-based deployment tracking.** `rails rails_pulse:record_deployment[revision]` and `rails rails_pulse:finish_deployment[revision]` record and close deployments from release scripts without the HTTP API or a token.
- **Standalone dashboard authentication.** `config.standalone_authentication_method` (HTTP Basic against `RAILS_PULSE_USERNAME` / `RAILS_PULSE_PASSWORD` by default) replaces the host hooks, which the standalone process cannot run.
- **`config.async_queue_size`** bounds the background writer queue (default 1000), and `RailsPulse::Tracker.stats` reports what was dropped.
- The upgrade generator syncs new initializer settings into the host's initializer without overwriting existing values, and reports unrun migrations and outstanding route backfill instead of saying everything is up to date.

### Changed

- **BREAKING: route identity is now `[controller_action, path]`.** Different HTTP methods on the same path are tracked as distinct routes, and a one-time `rails rails_pulse:migrate_routes` backfill is required after migrating.
- **BREAKING: `rails_pulse_routes.method` is dropped and the migration is irreversible.** The HTTP verb now lives on each request. Restart all processes together after migrating.
- **One writer thread per process.** Background tracking no longer spawns a thread per request, which could exhaust the app's connection pool under a burst. A single writer drains a bounded queue on one connection and drops the newest request when the queue is full rather than slowing the app; SQL normalisation and N+1 detection run there too, off the request thread.
- **Summary aggregation upserts each period in bulk** instead of one statement per route, query and job, and runs its transaction on the Rails Pulse connection so separate-database installs cannot be left with partial summaries.
- **Dashboard assets are no longer registered with Sprockets**, which fixes `assets:precompile` running out of memory on small hosts. `rails_pulse:install_assets` copies them into `public/assets` after precompile so `config.asset_host` and CDN-only CSP keep working; remove any `rails-pulse.js` / `rails-pulse.css` entries from `config.assets.precompile`.
- Services under `app/services` autoload and reload through Zeitwerk like the rest of the engine.
- The JavaScript bundle is 66% smaller (2.19 MB to 759 KB) after tree-shaking ECharts.
- Ruby 3.1 is the minimum. The gem declared 3.0 but could not install there.

### Removed

- **BREAKING: `rails_pulse_routes.method`** (see Changed).
- `RailsPulse.warm_metric_cache!` and `RailsPulse.clear_metric_cache!`.
- The `group_by_date` / `group_by_hour` methods the gem added to the host's `ActiveRecord::Relation`.
- Three unused Stimulus controllers (`form`, `timezone`, `period_selector`), an unused chart theme, and dead CSS.

### Fixed

- **Dashboard pages issue far fewer queries.** Tag filtering runs as subqueries inside each card and chart query, the route-backfill check is a single indexed query, and table sizes are cached for five minutes.
- **Metric card sparklines are correct in time zones east of UTC.** Daily buckets follow `config.time_zone` instead of the stored UTC timestamp.
- **Charts and metric cards honour a custom date range** instead of always showing the trailing days, and custom ranges no longer render blank charts when the server's OS time zone differs from `config.time_zone`.
- A custom date range no longer 500s the dashboard on Marshal-backed session stores such as `activerecord-session_store`. (#252)
- Idle periods no longer trigger false "summary job not running" warnings; `SummaryJob` records a zero-count summary for periods with no traffic. (#250)
- The storage page reports real table sizes again instead of a leftover screenshot fixture's sample numbers.
- Dashboard status bar badges for routes, queries and jobs are clickable, matching exceptions and storage.
- Chart click/zoom handlers no longer accumulate on every tab switch, zooming to the first column of a category chart applies the range, hover popovers no longer throw after a table refresh, and the time range selector's hover border is visible.
- Tag filters match tags containing `_` on SQLite, and malformed query strings fall back to defaults instead of returning 500.
- **Lower per-query capture overhead.** The SQL, template and cache subscribers walk the call stack lazily and stop at the first app frame instead of materialising the whole stack on every event.
- Cached SQL reads are no longer captured as operations, and `config.ignored_queries` is now applied (it was validated but never consulted).
- The dashboard's own HTTP, mailer, job and storage events are no longer recorded.
- `config.logger` is honoured; a custom logger set in the initializer receives all Rails Pulse output. (#244)
- Background tracking writes no longer corrupt the test database connection under transactional tests. The initializer sets `config.async = false if Rails.env.test?`, and the tracker also writes inline whenever it detects a connection shared across threads.
- Cleanup no longer risks statement timeouts on large tables: orphan checks use a correlated `NOT EXISTS` instead of `NOT IN`, so one stalled stage no longer blocks the rest. (#253)
- **Standalone dashboard.** Settings forms no longer fail CSRF verification, the time range and filter pickers no longer 404, its own stylesheets and scripts are served, `RAILS_ENV` / `RACK_ENV` are respected, `SECRET_KEY_BASE` falls back to the host's, breadcrumb links are no longer protocol-relative when served at `/`, and the ignored-host-authentication notice is logged once per process.
- Upgrading a separate-database install works, and those installs set `schema_dump: false` so `db:migrate` does not dump or load `db/rails_pulse_structure.sql`. (#189)
- SQLite's `schema.rb` keeps the partial unique index on unrecognised routes across `db:schema:load`.
- Asset responses use lowercase headers, which `Rack::Lint` requires under Rack 3.

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

[Unreleased]: https://github.com/railspulse/rails_pulse/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/railspulse/rails_pulse/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/railspulse/rails_pulse/compare/v0.3.2...v0.3.3
[0.3.0]: https://github.com/railspulse/rails_pulse/compare/v0.2.7...v0.3.0
[0.2.7]: https://github.com/railspulse/rails_pulse/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/railspulse/rails_pulse/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/railspulse/rails_pulse/releases/tag/v0.2.5
