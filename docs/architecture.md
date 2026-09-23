# Architecture

How a request, a job, and an hour of data move through Rails Pulse. Read before touching collection, the tracker, summaries, or the standalone server. Every step names its file.

## Boot

`lib/rails_pulse/engine.rb` wires everything in initializers with explicit ordering:

| Initializer | Does |
|---|---|
| `rails_pulse.inflections` | pins acronym-prone file names so a host's `inflect.acronym` cannot rename constants (`ACRONYM_SAFE_INFLECTIONS`) |
| `rails_pulse.assets` | inserts `Middleware::AssetServer` after `Rack::Runtime` unless `config.mount_dashboard` is false |
| `rails_pulse.middleware` | appends `Middleware::RequestCollector` to the host stack |
| `rails_pulse.operation_notifications` | `Subscribers::OperationSubscriber.subscribe!` |
| `rails_pulse.exception_notifications` | `Subscribers::ExceptionSubscriber.subscribe!` |
| `rails_pulse.active_job` | includes `ActiveJobExtensions` into `ActiveJob::Base` |
| `rails_pulse.configure_sidekiq` / `configure_delayed_job` | adapter middleware and plugin, after `active_job` |

`app/` is Zeitwerk-managed; `lib/rails_pulse/` is required explicitly in `engine.rb`. `RailsPulse.configuration` (`lib/rails_pulse/configuration.rb`) validates every setting on assignment and again at boot.

## Request path

1. `Middleware::RequestCollector#call` (`lib/rails_pulse/middleware/request_collector.rb`) skips when `RequestStore.store[:skip_recording_rails_pulse_activity]` is set (the dashboard's own requests, ignored routes, assets unless `track_assets`), otherwise assigns a request UUID and an empty operations array in `RequestStore`.
2. During the request, `Subscribers::OperationSubscriber` (`lib/rails_pulse/subscribers/operation_subscriber.rb`) appends one hash per instrumentation event: `sql.active_record`, `process_action.action_controller`, `render_template` / `render_partial` / `render_layout` / `render_collection.action_view`, `cache_read` / `cache_write.active_support`, `request.net_http`, `perform.active_job`, `deliver.action_mailer`, `service_upload.active_storage`. The SQL, template and cache subscribers walk the stack lazily to record the first app frame as `codebase_location`. Query-cache hits and `ignored_queries` are dropped here.
3. After the response, the middleware deep-copies the operations (RequestStore is thread-local; see `RequestStore is thread-local` in `CLAUDE.md`), builds a tracking hash, and calls `Tracker.track_request`.
4. `RailsPulse::Tracker` (`lib/rails_pulse/tracker.rb`) pushes onto a bounded queue (`config.async_queue_size`). One writer thread per process drains it in batches on one connection from the Rails Pulse pool. When full, the newest request is dropped and counted; `Tracker.stats` exposes depth and drops for the current process. Once a minute (`Writer::HEARTBEAT_INTERVAL`, kept by the `pop` timeout so an idle writer still reports) the writer records a `WriterHeartbeat` (`app/models/rails_pulse/writer_heartbeat.rb`), an `Event` of kind `writer_heartbeat` with `host:pid` as subject, drops since the last sample as value and the queue depth in metadata, and prunes heartbeats older than a day, so `Dashboard::HealthSummary#tracking_counts`, the Storage page and `rails_pulse:status` can add up every process's writer. With `config.async = false`, or when the tracker detects a transactional-test connection, `perform_tracking` runs inline and there are no heartbeats. See decision 0005.
5. On the writer: `Route.find_or_create_for_request` resolves `[controller_action, path]` (decision 0004), `Request` is inserted, `SqlQueryNormalizer` (`app/services/rails_pulse/sql_query_normalizer.rb`) fingerprints each SQL operation into a `Query` (decision 0008), `Tracker.detect_n_plus_one` flags repeated fingerprints, and `Operation` rows are bulk-inserted.
6. `ExceptionSubscriber` (`lib/rails_pulse/subscribers/exception_subscriber.rb`) runs on `process_action.action_controller` when the payload carries an exception, and calls `ExceptionCaptureService.capture` (`app/services/rails_pulse/exception_capture_service.rb`) synchronously (decision 0015).

### What a tracked request costs

Two costs, on two threads. On the request thread: the middleware's own work plus, per instrumentation event, one hash appended to the operations array and a lazy stack walk that stops at the first frame under `app/` (`OperationSubscriber#find_app_frame`), then one push onto the writer queue after the response. On the writer thread: the route lookup, the request insert, SQL normalisation, N+1 detection and one bulk insert of the operations. `bin/benchmark` measures the request-thread side against a pass-through Rack app, so the `async: true` row is the fixed per-request overhead and the `async: false` row is what the writer thread absorbs when it runs inline. Measured 2026-09-21 on Ruby 3.3.6, Rails 8.1.3.1, 200 iterations (`bin/benchmark --iterations=200`; `--markdown` reprints the table from `benchmarks/results/`, which is not tracked):

| DB | Scenario | Median (ms) | P95 (ms) | P99 (ms) | DB writes |
|---|---|---|---|---|---|
| sqlite3 | Baseline (disabled) | 0.001 | 0.001 | 0.001 | 0 |
| sqlite3 | Enabled, async: true | 0.025 | 0.032 | 0.042 | 0 |
| sqlite3 | Enabled, async: false | 5.319 | 9.789 | 22.411 | 2 |
| postgresql | Baseline (disabled) | 0.001 | 0.001 | 0.001 | 0 |
| postgresql | Enabled, async: true | 0.026 | 0.033 | 0.155 | 0 |
| postgresql | Enabled, async: false | 5.624 | 8.654 | 22.757 | 2 |

The per-event subscriber cost is not in this table because the pass-through app emits no events; it scales with the number of SQL, template and cache events in a request, at a few microseconds each since the stack walk became lazy (#265).

## Job path

`ActiveJobExtensions` (`lib/rails_pulse/active_job_extensions.rb`) wraps `perform` in `JobRunCollector.track` (`lib/rails_pulse/job_run_collector.rb`), which creates the `Job` aggregate row and a `JobRun`, collects operations exactly as the request path does, records status, attempts and queue wait, and on failure calls `ExceptionCaptureService` before re-raising. Adapters that bypass Active Job get their own hook: `adapters/sidekiq_middleware.rb`, `adapters/delayed_job_plugin.rb`, `adapters/job_wrapper.rb`. `config.job_adapters` switches each one off.

## Aggregation

`app/jobs/rails_pulse/summary_job.rb` runs hourly (the host schedules it). It calls `SummaryService` (`app/services/rails_pulse/summary_service.rb`) for the previous hour, and at day, week and month boundaries for those periods. The service computes count, average, min, max, P50, P95, P99 and status buckets per Route, Query and Job, plus the overall request rollup, and upserts all rows in one statement against the summaries unique index (decision 0013). The overall row is written even for an empty period; its timestamp is the heartbeat that the stale banner, `rails_pulse:status`, `Dashboard::StoragePressure` and `CleanupService` read. `BackfillSummariesJob` rebuilds from raw rows.

`app/services/rails_pulse/operations/` (`Series`, `Metric`, `Compare`, `ChangePoint`) is the historical comparison layer over summaries: baseline window against comparison window, regression thresholds, change-point placement from hourly rows.

## Dashboard

Controllers under `app/controllers/rails_pulse/` read summaries through `Tables::Index` classes and the card classes in `app/models/rails_pulse/cards/`. The requests page is the exception: it lists individual `Request` rows because per-request detail is the point. Filtering is Ransack with explicit `ransackable_attributes` on every model; tag filters run as subqueries (`TagFilterService`). Charts are one Stimulus controller over tree-shaken ECharts; see `docs/charts.md`.

`ApplicationController` gates every page: schema check first (below), then authentication (`authenticate_rails_pulse_user!`: `authentication_method`, then `authorize`, then HTTP Basic; decision 0014).

## Retention

`app/jobs/rails_pulse/cleanup_job.rb` calls `CleanupService` (`lib/rails_pulse/cleanup_service.rb`): age-based deletion by `full_retention_period`, then count-based by `max_table_records`, `rails_pulse_events` by `event_retention_period` except `event_retention_exempt_kinds`, hourly summaries by `hourly_summary_retention`, `preserve` exempting exception groups (decision 0017). `rake rails_pulse:cleanup` runs the same service; `cleanup_stats` reports sizes.

## Schema check

`RailsPulse::SchemaCheck` (`lib/rails_pulse/schema_check.rb`) runs once per process on first write or render. Missing tables or `SENTINEL_COLUMNS` pause tracking after one warning and make `ApplicationController` render `shared/schema_outdated` with 503 (decision 0012). `rails rails_pulse:status` (`lib/rails_pulse/tasks/status_reporter.rb`) reports the same plus migrations, route backfill and initializer state, exiting 1 when action is needed.

## Standalone server

`exe/rails_pulse_server` execs `rackup` on `lib/rails_pulse_server.ru`, which requires the host's `config/environment.rb` from the current directory, calls `RailsPulse.standalone!` (`lib/rails_pulse/standalone.rb`), and serves the engine at `/` behind `Rack::Static`, `Rack::MethodOverride`, `ActionDispatch::Cookies` and `ActionDispatch::Session::CookieStore`. `standalone!` overrides `find_script_name` so engine URL helpers stop prefixing the host mount path. Authentication falls through to `standalone_authentication_method`, then HTTP Basic. `/health` reports `Tracker.healthy?`. Decision 0010.

## Assets

Built by `npm run build` into `public/rails-pulse-assets/` and committed. Served by `Middleware::AssetServer` at `/rails-pulse-assets/<version>/…` in development and pipeline-less hosts, or copied into `public/assets` with a digest by `rails_pulse:install_assets` after the host's `assets:precompile`. Not registered with Sprockets. Decision 0016.

## Events

`rails_pulse_events` (`app/models/rails_pulse/event.rb`) holds what Pulse noticed rather than measured, one row per outcome or sample tagged by `kind`, with `subject`, `value`, `occurred_at`, `message` and JSON `metadata`. The free gem writes `writer_heartbeat` rows; `rails_pulse_pro` writes `alert_rule`, `deployment_regression`, `exception_alert` and `job_heartbeat` rows into the same table and registers `job_heartbeat` in `config.event_retention_exempt_kinds`, so a Pro install needs no migration. Decision 0019.

## Deployments

`Deployment` rows come from `rake rails_pulse:record_deployment[rev]` / `finish_deployment[rev]` (`lib/tasks/rails_pulse.rake`) or `POST /rails_pulse/deployments` (`DeploymentsController`, token in `X-Rails-Pulse-Token` compared with `secure_compare`). Controllers assign `@deployment_markers` and `render_stimulus_chart` merges them into time-axis charts.
