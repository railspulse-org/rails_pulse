# Public API

Rails Pulse follows [Semantic Versioning](https://semver.org/) starting at 1.0. This page
lists the public surface: what a host application, the `rails-pulse` CLI, the MCP server, and
the Pro gem are meant to depend on, and what contract each entry carries between minor
releases.

Everything not listed here is internal — `RailsPulse::Cards::*`, `Charts::*`, `Tables::*`,
controllers, concerns, `Tracker` internals below `.stats`/`.flush!`, and any other class or
method not named on this page. Internal code can change shape in a minor release; the entries
below cannot, except across a major version.

## Configuration

`RailsPulse.configure { |config| ... }` yields a `RailsPulse::Configuration` instance and
validates it on the block's return, raising `ArgumentError` for an invalid setting.

Every configuration key (~45, covering thresholds, retention, authentication, job tracking,
tags, and more) is documented inline in the install template —
`lib/generators/rails_pulse/templates/rails_pulse.rb` — which is also what an existing
installation's initializer is synced against on upgrade. That file is the source of truth for
what each key does and its default; this page does not duplicate it.

- `RailsPulse.configuration` — the current `Configuration` instance.
- `RailsPulse.logger` — the logger Rails Pulse writes to: `config.logger` if set, otherwise
  `Rails.logger` tagged `"RailsPulse"`, falling back to `Logger.new($stdout)` before Rails has
  booted a logger.
- `RailsPulse.connects_to` — `config.connects_to`, or `nil` when unset or unconfigured.

## Navigation

- `RailsPulse.register_nav_item(label:, path_helper:, icon:, position: 100)` — adds an entry
  to the dashboard sidebar, sorted by `position` ascending. Intended for the Pro gem and other
  extensions to add pages without forking the layout.
- `RailsPulse.nav_items` — the registered items in sort order.

## Pro detection

- `RailsPulse.pro?` — `true` when `RailsPulse::Pro` is defined, `false` otherwise. This is the
  documented way to branch on whether Pro is installed; do not check `defined?` directly.

## Operations — regression detection

`RailsPulse::Operations` is the interface anything built on top of Rails Pulse (dashboards,
findings, Pro tooling) should use to answer "did this get worse?" and "when did it change?".
It reads only from summaries, so it stays available long after raw requests have aged out of
retention.

- **`Operations::Compare`** — measures a subject's recent behaviour against its own history.
  - `Compare.call(subject, metric: :p95, as_of: Time.current)` → a `Comparison`, always
    returned; ask it `comparable?` before reading a verdict. `subject` is a `Route`, `Query`,
    `Job`, or `:requests`. `metric` is `:p50`, `:p95`, `:p99`, `:avg`, or `:error_rate`.
  - `Compare.scan(scope, metric: :p95, as_of: Time.current)` → an `Array<Comparison>` for
    every record in `scope` (a `Route`, `Query`, or `Job` relation or class), filtered to
    comparisons with usable data on both sides.
- **`Operations::Comparison`** — the value object `Compare` returns. Read-only; carries
  `subject`, `metric`, `period_type`, `baseline_value`, `baseline_count`, `baseline_periods`,
  `current_value`, `current_count`, plus derived `comparable?`, `delta`, `ratio`,
  `percent_change`, `direction` (`:up`/`:down`/`:flat`/`:unknown`), and `unit`.
- **`Operations::ChangePoint`** — estimates when a metric changed by finding the split in a
  time series that best separates a "before" from an "after". Precision is bounded by how long
  hourly summaries are retained (`config.hourly_summary_retention`); beyond that window the
  estimate is pinned to a day, and the result says which.
  - Returns a `ChangePoint::Result` struct: `at`, `granularity` (`"hour"` or `"day"`),
    `before_value`, `after_value`, `before_count`, `after_count`, plus `ratio`, `delta`, and
    `hourly?`.

`Operations::Metric`, `Operations::Series`, and `Operations::Subject` are internal helpers used
by `Compare` and are not part of this contract.

> The `Operations` namespace visually collides with the `Operation` model and
> `OperationsController` (the per-request timeline). The name is being kept for 1.0; a rename
> would be a breaking change and is not currently planned.

## Background jobs

Each is an `ActiveJob`; enqueue it the same way as any other job in the host app.

- `RailsPulse::SummaryJob.perform_later(target_hour = nil)` — rolls up hourly, and (at
  hour/day/week/month boundaries) daily, weekly, and monthly summaries ending at
  `target_hour` (default: the start of the hour one hour ago).
- `RailsPulse::CleanupJob.perform_later` — runs retention-based cleanup when
  `config.archiving_enabled`; returns the stats hash from `CleanupService`, or `nil` if
  archiving is disabled.
- `RailsPulse::BackfillSummariesJob.perform_later(start_date, end_date, period_types = ["hour", "day"])`
  — backfills summaries for an existing date range.

## Rake tasks

| Task | Purpose |
|---|---|
| `rails_pulse:status` | Reports schema, migration, route-backfill, and initializer state; exits 1 when something needs action. |
| `rails_pulse:migrate_routes` | Backfills controller actions, normalizes paths, and consolidates multi-verb routes on existing route rows. |
| `rails_pulse:record_deployment[revision]` | Records a deployment event. |
| `rails_pulse:finish_deployment[revision]` | Marks the latest deployment for a revision as finished. |
| `rails_pulse:backfill_summaries` | Backfills summary data from existing requests and operations. |
| `rails_pulse:cleanup` | Performs data cleanup based on configured retention policies. |
| `rails_pulse:cleanup_stats` | Shows current table sizes and cleanup configuration, without deleting anything. |
| `rails_pulse:install_assets` | Copies pre-built dashboard assets into `public/assets` without running the host's JS compressor. |

`rails_pulse:install`, `install_migrations`, and `install_config` exist to support the
generators below and are not typically invoked directly.

## Generators

- `rails generate rails_pulse:install` — sets up a new installation: schema, initializer,
  migrations.
- `rails generate rails_pulse:upgrade` — brings an existing installation's schema and
  initializer up to date with the running gem version.

## Tracker

`RailsPulse::Tracker` is the async writer; only these two entry points are public:

- `RailsPulse::Tracker.stats` — `{ queue_size:, dropped:, running: }` for the background
  writer thread. Zeros before the writer has been used.
- `RailsPulse::Tracker.flush!` — persists everything currently queued and stops the writer.
  The next tracked request starts it again. Intended for tests and shutdown hooks.

## Schema drift guard

`RailsPulse::SchemaCheck` answers whether the live database matches what the running gem
version expects, pausing tracking (and returning a 503 from the dashboard) when it does not.

- `SchemaCheck.current?` — `true` when every required table and sentinel column is present.
- `SchemaCheck.missing` — a hash of table → missing columns (or `[:table]` for a table that
  doesn't exist at all); empty when current or when the check is disabled.

`config.schema_check_enabled = false` turns the guard off entirely.

## What is not covered

Everything else — including but not limited to `RailsPulse::Cards::*`, `Charts::*`,
`Tables::*`, all controllers and views, `TimeRangeConcern` and friends, `RequestCollector`,
`OperationSubscriber`, and any method on the classes above not listed here — is internal
implementation detail. It may change shape, move, or be removed in a minor release.
