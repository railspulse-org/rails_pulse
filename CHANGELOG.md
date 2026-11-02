# Changelog

All notable changes to Rails Pulse will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The dashboard now says when cleanup itself has stopped, based on the last recorded cleanup run: a warning when `RailsPulse::CleanupJob` has never run with requests past retention or when its last run is over two days old, and a critical item when the last run failed. The Storage page's Cleanup panel also shows when cleanup last ran and what it deleted. (#358)
### Fixed

- A custom range ending exactly on an hour (or midnight) now treats that bound as exclusive, so a 15:00-to-15:00 selection charts 24 hourly buckets instead of 25 and the chart matches the displayed range (#337).
- `rails generate rails_pulse:upgrade` now stamps copied migrations with a fresh timestamp instead of the gem's original one, so they run after the app's Rails Pulse install migration and `db:migrate` no longer fails on databases that have not run it yet (#420).
- `rails_pulse:migrate_routes` no longer aborts when a recorded path isn't a valid URI (for example a scanner request like `/user[email]`); such routes count as skipped and the migration continues (#414).
- Updating an exception's preserve flag with a blank or non-boolean value now returns 422 instead of a 500 or silently preserving it, and resolving an already-resolved exception keeps its original resolved time.
- Filtering the Queries page by SQL text (`q[normalized_sql_cont]`) no longer returns a 500; the filter narrows the table and the charts keep showing all queries.
- Requests whose path segments are percent-encoded (such as `/posts/caf%C3%A9`) are now grouped under their route template (`/posts/:id`) instead of each distinct encoded id getting its own route row and chart.
- Dashboard assets served by the gem (hosts without an asset pipeline and `rails_pulse_server`) are now gzipped and revalidate by ETag, and only the running gem version is cached as immutable.
- The dashboard now shows the confirmation or error after adding or removing a tag or updating an exception, so a rejected tag no longer looks the same as a saved one.
- Adding or removing tags on the same record from two processes at once no longer loses one of the edits.
- Requests and Deployments are now in the navigation, which collapses into the menu button below 1280px wide instead of making the whole page scroll sideways.
- The Tags column header on the Routes, Requests and Queries tables is no longer a sort link that silently fell back to the default order.
- The dashboard's Exceptions badge explains "quiet", "firing" and "critical" on hover, and why a firing group below the warning threshold has no Needs Attention entry.
- On a phone, the request page's Operations table keeps Duration and Impact on screen.

## [0.5.1.pre.3] - 2026-10-29

### Added

- Metric card sparklines now draw the still-in-progress day (or hour) as a dashed outline "ghost" bar with a tooltip saying the period is in progress, instead of an invisible zero bar, so "Last 14 days" visibly shows all 14 days.

### Fixed

- Metric card headline figures (P95 times, error and failure rates, totals, database load) now cover only the selected time range; when a trend was shown they aggregated the selected and previous ranges together.
- Dashboard pages no longer return a 500 when a hand-edited URL turns a filter, sort, page, limit, zoom or tag param into an array or hash; the value is ignored and the default applies.
- `rails generate rails_pulse:install_cloud` and the initializer template now say to schedule both `RailsPulse::SummaryJob` and `RailsPulse::CloudHealthJob`; the hourly Cloud sync only runs after `SummaryJob`, so nothing reached Cloud without it.
- Dashboard time ranges are now capped at one year, so a very wide custom range, chart zoom or saved time-range preference shows the most recent year instead of tying up the server building a chart point for every day.
- Request and job run pages stay small and fast when an N+1 records thousands of operations: runs of the same operation collapse into one trace bar and one table row with a count, and at most the 250 slowest groups are shown.
- With no time range chosen, the header's time range selector now names the range each page actually shows (24 hours on the dashboard and requests, 7 days on queries, jobs and exceptions, 14 days on routes) instead of always reading "Last 14 days".
- The summary cards on the routes, queries, jobs and exceptions pages now follow the selected time range, so a past range shows that range's figures and the cards agree with the main dashboard for the same range.
- Request rate and query execution rate are now averaged over the selected range rather than over twice its length.
- The dashboard's job health counts and Needs Attention job entries now follow the selected time range and tag filters instead of each job's all-time failure rate and P95, so they agree with the Jobs page.

### Changed

- The MCP server is now developed and tested against mcp 1.8.1, which tightens the gem's JSON-RPC conformance. Hosts keep choosing their own mcp version in their Gemfile; any 1.x release continues to work.
- Updated development-only dependencies (`pg` 1.7.0, `timecop` 0.9.11, `rubocop-minitest` 0.41.0); gem development/CI only, no effect on host apps.

## [0.5.1.pre.2] - 2026-10-24

### Added

- The navigation now carries a "Back to <your app>" link so there is always a way back to the host application. It points at `config.return_to_app_url` (default `/`; set to `nil` to hide it).
### Changed
- Rails Pulse now allows Ransack 6, so host apps can upgrade to it without waiting on the gem; Ransack 4 and 5 remain supported (#344).

### Fixed

- Merging routes with `rails rails_pulse:migrate_routes` now moves detail capture's hourly aggregates to the surviving route; previously that folded traffic disappeared from its charts. Aggregates from roughly the last hour, which running apps may still be updating, stay behind so nothing is counted twice.
- Detail capture no longer counts traffic against a route that cleanup has deleted: the writer re-checks its remembered routes every 10 minutes, so at most 10 minutes of folded traffic could go missing instead of everything until the next restart.
- With detail capture on, folded requests now resolve their SQL in one lookup per write batch instead of one per request, reducing the writer's database load on high-traffic installs.
- Hourly summary maintenance now stays fast as retained data grows: a covering index on operations serves the hour's query metrics without reading the table, fixing `statement_timeout` failures on large installs (#375). Run `rails rails_pulse:install:migrations && rails db:migrate` after upgrading to add the index.
- Dashboard and detail-page charts are no longer clamped to 60px tall on phone-width screens; they now keep their aspect ratio, so mobile charts are readable.
- Databases behind an adapter built on PostgreSQL, MySQL or SQLite are now recognised: with activerecord-postgis-adapter (or Trilogy for MySQL) the dashboard's storage panel failed on every table, the Storage page showed no sizes and EXPLAIN analysis was skipped; Rails Pulse now treats them as the database they run on (#387).
- Active Job jobs on Sidekiq are no longer tracked twice: each run was also recorded under Sidekiq's wrapper class (`Sidekiq::ActiveJob::Wrapper`), doubling job runs, failures and captured exceptions on the Jobs page. Wrapper rows recorded by earlier versions stay until retention removes them (#386).
- Time range presets now cover exactly the period their label names: "Last 7 Days" previously spanned 8 days and "Last 24 Hours" 25 hours. Dashboard totals, charts and period-over-period comparisons may show slightly lower numbers after upgrading because the oldest day or hour is no longer included (#355).

## [0.5.1.pre.1] - 2026-10-21

### Added

- **Detail capture for high-traffic installs.** With `config.store_full_details = { above_threshold: :slow }`, only requests and queries past the named threshold, errors and a 1% sample are stored in full, while dashboards still count all traffic from compact hourly aggregates. Off by default; upgrading adds a table, so run `rails generate rails_pulse:upgrade && rails db:migrate`.
- **How much detail capture keeps.** `rails rails_pulse:status`, the Storage page and the info icon on lists of captured requests show what share of the last day's traffic was kept in full; when it is over a quarter, the dashboard's Storage badge warns and says which setting to change.

### Fixed

- Requests whose controller raises an unhandled exception are now recorded, with the status the error page sends, so error rates and request counts include them; previously only the exception was tracked and the request was missing.

## [0.5.0] - 2026-10-16

## [0.5.0.pre.2] - 2026-10-11

### Added

- **Before-and-after comparison for every deployment.** The deployments API, `rails-pulse deployments list` and the `rails_pulse_deployments` tool now say whether each release made things worse: response time or error rate materially worse in the hour after the deploy finished than in the hour before it started, or too little traffic to tell.
- **What needs attention, and whether the thresholds fit.** `GET /rails_pulse/api/v1/insights`, `rails-pulse insights show` and the `rails_pulse_insights` tool list the routes, queries and jobs past their thresholds over one hour, day, week or month, and suggest an initializer line when `route_thresholds` or `query_thresholds` is too noisy or never fires.
- **Exact lookups for the keys Rails Pulse Cloud holds.** The API, CLI and MCP tools can now find a query by `hashed_sql`, an exception group by `fingerprint`, a route by exact path and controller action, a deployment by revision, and requests by path prefix, so a Cloud alert leads straight to the local detail.
- **Rails Pulse Cloud sync.** With `config.cloud.api_key` and `config.cloud.application` set, hourly summaries, exception groups, deployments and a per-minute health update are sent to Rails Pulse Cloud (never request URLs, SQL values or exception messages), and `rails rails_pulse:cloud:preview` prints exactly what would be sent; to use it, run `rails generate rails_pulse:install_cloud`, migrate, and schedule `RailsPulse::CloudHealthJob` every minute.
- **`rails rails_pulse:status` checks how the install is run.** It reports whether `SummaryJob` has skipped hours and whether `CleanupJob` is running, how long hourly summaries are kept, and whether jobs are tracked, and lists suggestions for each without changing the exit status. Each cleanup run is now recorded in `rails_pulse_events` so the task can tell.

### Changed

- **A query is the same query however many values it loads.** `WHERE id IN (…)` with 3 ids and with 12 ids, and a batch insert of 2 rows and of 50, used to be tracked as separate queries, each with its own stats, N+1 flags and EXPLAIN; they are now one entry. Entries recorded by earlier versions keep their old form until retention removes them, so a query may appear twice on the Queries page for a while after upgrading.
- **Hourly summaries are kept for 7 days instead of 2.** Deployment comparisons and hour-precise change points read them, so at 2 days a deploy from earlier in the week could no longer be compared; `config.hourly_summary_retention` tunes it.

### Fixed

- **Normalised SQL no longer shows some string values.** A value written in one of SQL's less common string forms — only possible in hand-written SQL — stayed visible in the normalised query on the dashboard, the API and the MCP server, and split that query's stats into one entry per value; it is now replaced with `?` like any other value. On MySQL the same happened to any value containing an apostrophe or any double-quoted value shaped like a column name, and on every database to very small or very large decimals. (#335, #313)
- **The dashboard no longer counts every Rails Pulse table on each load.** On PostgreSQL and MySQL its storage panel now shows the database's row estimates, and on SQLite it leaves record counts to the Storage page, so large installs no longer wait tens of seconds per page view; the storage-pressure checks also run once per page instead of four times. On MySQL 8, record counts and disk sizes on the dashboard and the Storage page are read current instead of from a statistics cache up to a day old. (#363)
- **Needs Attention and System Health no longer overcount traffic.** Request, error, query and exception counts were added up once per summary granularity, which inflated them and could raise an exception group's severity; today's traffic now counts in windows longer than a day. (#338)
- **Threshold recommendations no longer suggest a critical threshold equal to `very_slow` or below a rarely run slow query.** A suggested critical threshold now sits at least one step above `very_slow`, and the query check reads the period's slowest query rather than only its most expensive ones.
- **The dashboard no longer reports cleanup as blocked when it is not.** The critical "summarize first" Storage item appeared whenever expired requests were waiting for the next daily cleanup, which deletes them by age regardless of summaries; it has been removed, and a stalled summary job is still flagged.
- **PostgreSQL Unicode escape strings (`U&'…'`) are normalised to `?`** like other prefixed strings, instead of leaving `U&?` in the normalised query.
- **Daily charts no longer go blank after a daylight-saving change.** In a `config.time_zone` with daylight saving, every day after the clocks changed was drawn empty in a range that crossed the change; chart days now follow the zone's calendar.

## [0.5.0.pre.1] - 2026-10-03

### Added

- **JSON API, `rails-pulse` CLI and MCP server.** A read-only API under `/rails_pulse/api/v1`, a `rails-pulse` executable and an MCP server (`rails-pulse mcp`; add `gem "mcp"` to your Gemfile) give scripts, CI and coding agents what the dashboard shows: routes, requests, queries, jobs, job runs, exceptions and deployments. (#309)
- **Coverage reporting for agents.** `rails-pulse coverage show` and the `rails_pulse_coverage` tool report what has been recorded, how recently, any collection gaps, and which application and environment answered, so missing data is not mistaken for an all-clear. (#309)
- **Fixed windows and drilldown.** Every windowed command and tool takes ISO 8601 `since`/`until` and reports the window it measured, and `rails_pulse_queries` takes an endpoint's `route_id` to show the SQL inside it with the file and line each query came from. (#309)
- **Agent instructions.** `rails-pulse install claude` installs a Claude Code skill, and `rails-pulse install agents` writes a Rails Pulse section into `AGENTS.md`, alongside a project's own instructions with `--append`. (#309)
- `rails rails_pulse:status` reports whether the API and deployment tokens are set. (#309)
- **Dropped requests are now visible.** Each background writer records a heartbeat once a minute (queue depth and requests dropped since the last one), pruned after a day. The dashboard's health bar gains a Tracking badge, shown only when a writer is backlogged or dropping requests; the Storage page lists every live writer with its queue and drops; and `rails rails_pulse:status` reports the totals and exits 1 when anything was dropped in the last hour. (#281)
- **A `rails_pulse_events` table** for what Rails Pulse notices rather than measures, starting with the writer heartbeats above. `config.event_retention_period` (default 90 days) prunes it. Run `rails generate rails_pulse:upgrade` and migrate; tracking pauses until the table exists.
- CI now exercises the separate-database upgrade path (`bin/test_separate_database_upgrade`, SQLite and PostgreSQL), and the migration regression suite gains a 0.3.2 baseline. (#284)
- **Charts say which time zone they are in.** Every chart carries a zone badge (hover for the full zone name and the exact window shown), chart tooltips end with the zone, and the custom date range picker states the zone its inputs are read in. (#303)

### Changed

- **Daily, weekly and monthly summaries are built from shorter periods instead of raw rows.** The summary job's memory no longer grows with the length of the period or with raised retention caps, and longer periods stay complete after raw data is pruned; their P50/P95/P99 are now traffic-weighted from the hours or days below them, as the dashboard already shows for multi-period ranges. A period is summarized only once it ends, so the backfill task no longer writes a partial row for the current day. (#279)
- **`config.deployment_api_token` is now `config.deployment_token`.** The old name still works and still only records deployments; the JSON API reads a separate `config.api_token`, so a token given to a coding agent cannot record a release. (#309)
- **Recording a deployment over HTTP requires `config.deployment_token`.** The deployments endpoint no longer accepts a dashboard login in place of the token, which let any page a signed-in admin visited record a release; set the token for CI, or use the `rails_pulse:record_deployment` task, which needs none. (#309)
- **All timestamps display in the app's `config.time_zone`.** Chart axes and tooltips are formatted in that zone rather than the browser's, so a daily point no longer lands on the wrong calendar day for viewers in another zone. Request, job, exception and operation timestamps also use it instead of the server's OS zone; on a host whose server runs in UTC with a different `config.time_zone`, those pages now show the configured zone. (#303)
- **Dashboard health bar badges omit zero counts.** "26 healthy · 0 slow · 0 critical" now reads "26 healthy"; the Storage badge is shown only under warning or critical pressure.
- **Dropped the `request_store` runtime dependency.** Per-request tracking state now goes through `RailsPulse::Current`, built on Rails' own `ActiveSupport::CurrentAttributes`. No configuration or behavior change; a host that read `RequestStore.store[:rails_pulse_request_id]` directly (undocumented, but reachable) needs to switch to `RailsPulse::Current.rails_pulse_request_id`. (#277)
- **Requires Ruby 3.2+ and Rails 7.2+.** The gemspec advertised Ruby 3.1 and Rails 7.1 but CI never ran them; the floors now match what is tested, and the untested Rails 7.1 and Ruby 3.1 code paths are gone. (#270)

### Fixed

- Weekly and monthly summaries written by `SummaryJob` now include the period's last day. (#279)
- Backfill date arguments are read in the app's time zone, so backfilled summaries land on the same period boundaries the scheduled job writes instead of UTC midnights. (#279)
- **The exception-group row cap no longer counts preserved and ignored groups.** Once those exempt groups approached the cap, every cleanup run deleted the oldest deletable groups without ever getting under it. The cap now applies to deletable groups only. (#285)

## [0.4.2] - 2026-10-01

### Changed

- Patch releases can be cut from a stable branch (`0-4-stable` for 0.4.x) while `main` carries the next release; `bin/release` and CI accept those branches.

### Fixed

- **Cleanup deletes in bounded batches.** A table far over its limit was trimmed with one statement whose size grew with the overage, which could exhaust the database server's memory on a busy app; every delete now removes at most 5,000 rows per statement. (#322)
- **One failed cleanup stage no longer stops the rest.** The remaining tables are still cleaned and the error is raised once they have finished. (#322)

## [0.4.1] - 2026-09-23

### Added

- A test that fails, naming the key, when a default in `RailsPulse::Configuration` and the install template drift apart. (#272)

### Changed

- Documented what a tracked request costs, measured against the bounded writer: about 25 microseconds of request-thread overhead per request on SQLite and PostgreSQL. (#275)
- The release gate and CI now fail if anything under `app/` branches on `Rails.env`, so a code path the test suite cannot reach can no longer ship. (#273)
- Loosened the `ransack` dependency from `~> 4.0` to `>= 4.0, < 6` so host apps can upgrade to ransack 5 without dropping Rails Pulse.
- `rake test` now refuses to run when the dummy database was last set up for a different adapter, instead of loading that adapter's `schema.rb` and failing two index tests. (#276)

### Fixed

- SQL normalization no longer raises `Regexp::TimeoutError` on long queries, which could fail the whole request when N+1 detection ran during collection.
- **Metric card headline numbers now honour the global tag filter.** Disabling a tag changed each card's sparkline but not the number beside it, so the two disagreed. Both are now computed over the same summaries. (#274)

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
