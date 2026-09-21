# Rails Pulse

A Rails engine that instruments a host app's requests, queries, jobs, and exceptions, storing the data in the host app's own database and surfacing it via a mounted dashboard.

## Language

### Traffic

**Route**:
One row per `[controller_action, path]` pair, for example `posts#show` at `/posts/:id`. A route carries every HTTP verb seen for that pair in `http_methods`; GET and POST on the same path are the same route when they resolve to the same action. Routes are the unit the dashboard ranks and tags.
_Avoid_: endpoint, URL, action (on its own)

**Unrecognised route**:
A Route whose `controller_action` is nil because the host router did not match the request (404s, middleware short-circuits). These are grouped by path alone and kept unique by a partial index on `path WHERE controller_action IS NULL`.
_Avoid_: unknown route, 404 route

**Request**:
One recorded HTTP request: duration, status, HTTP method, response size, error flag, and the Route it belongs to. Requests are the raw data that summaries aggregate, and cleanup deletes them first.
_Avoid_: hit, call, transaction

**Operation**:
One timed step inside a Request or JobRun: `sql`, `controller`, `template`, `partial`, `layout`, `collection`, `cache_read`, `cache_write`, `http`, `job`, `mailer` or `storage`. Together an entry's operations form its timeline. A `sql` operation also points at the Query it ran.
_Avoid_: span, event, segment

**Query**:
One normalised SQL statement, identified by `hashed_sql` over `normalized_sql` (literals replaced with placeholders). N+1 detection, EXPLAIN analysis and index suggestions hang off the Query, not the Operation.
_Avoid_: statement, SQL (as a noun for the row)

### Jobs

**Job**:
One row per background job class, with lifetime aggregates (`runs_count`, `failures_count`, P95 and P99 duration).
_Avoid_: worker, task

**JobRun**:
One execution of a Job with a status from `enqueued`, `running`, `success`, `failed`, `discarded` or `retried`. The last four are final. A JobRun owns Operations just as a Request does.
_Avoid_: execution, attempt (an attempt is a counter on the run)

### Aggregation

**Summary**:
A pre-aggregated row for one subject (a Route, Query, Job, or the overall request rollup, marked by `summarizable_type` Request with `summarizable_id` 0) over one period: count, average, P50, P95, P99, error count. `SummaryJob` writes them each hour, and writes the overall row even for an empty period so its timestamp doubles as the job's heartbeat.
_Avoid_: rollup, metric, stat

**Period type**:
The bucket size of a Summary: `hour`, `day`, `week` or `month`. Hourly summaries are pruned after `hourly_summary_retention` (default two days); the others follow the full retention period.
_Avoid_: granularity, interval, resolution

**Baseline and comparison window**:
The historical comparison compares the traffic-weighted metric across `baseline_window` (default 28 days) of day summaries against `comparison_window` (default one day). A change is a **regression** only when it clears both the ratio and the absolute floor in `regression_thresholds`.
_Avoid_: trend (that word is reserved for the metric-card arrow against the previous period)

**Performance status**:
The bucket a route, request, query or job falls into against its thresholds hash: `healthy`, `slow`, `very_slow` or `critical`. The dashboard health bar folds `very_slow` into `slow` and reports three counts.
_Avoid_: severity, level, grade

### Organisation

**Tag**:
A label from `config.tags` attached to a Route, Request, Query, Job or JobRun through the `Taggable` concern. Tags are stored serialised on the row and filter every index page. The defaults are only suggestions; no tag name has special behaviour.
_Avoid_: label, category, flag

**Deployment**:
A row recorded by the rake tasks or the deployments API with a revision, `started_at` and optional `finished_at` and metadata. Charts draw deployments as vertical markers so a change lines up with a release.
_Avoid_: release, deploy marker (the marker is how a Deployment is drawn, not the row)

### Collection

**Tracker**:
The single background writer per process. The middleware pushes each request's collected data onto a bounded queue (`async_queue_size`, default 1000); the Tracker drains it on one connection and drops the newest request when the queue is full. With `config.async = false`, or on a transactional-test connection, it writes inline.
_Avoid_: worker, collector (that is the middleware), reporter

**Event**:
A row in `rails_pulse_events`: something Rails Pulse noticed rather than measured, tagged by `kind` with a `subject`, a `value`, `occurred_at` and JSON `metadata`. The free gem writes writer heartbeats; Rails Pulse Pro writes its alert triggers, regression checks, exception alerts and job heartbeats into the same table. Pruned by `event_retention_period`, except kinds in `event_retention_exempt_kinds`.
_Avoid_: log, audit row, notification (that is a Pro Delivery)

**Writer heartbeat**:
The Event of kind `writer_heartbeat` each writer records once a minute: `host:pid` as subject, requests dropped since the previous heartbeat as value, queue depth and capacity in metadata. A writer silent for three minutes is treated as gone; heartbeats are pruned after a day. The dashboard's Tracking badge, the Storage page and `rails_pulse:status` add them up across processes.
_Avoid_: ping, stats row, health check (that is `Tracker.healthy?`)

**Schema check**:
The once-per-process test that every table and each sentinel column the running gem expects is present. When the database is behind, tracking pauses and the dashboard answers 503 until the upgrade commands are run.
_Avoid_: migration check, version check

### Exception tracking

**ExceptionGroup**:
One row per distinct exception site — identified by exception class and the first app-code method in the backtrace. Accumulates a lifetime occurrence count (`occurrence_count` / "Total Seen") and tracks lifecycle status. Never represents a single event. Stores `location` as a Rails.root-relative `file#method` (or `file:line` for anonymous frames) used for fingerprinting and display.
_Avoid_: error, issue, bug

**ExceptionOccurrence**:
A single instance of an exception being raised. Always belongs to an ExceptionGroup. Stores up to 50 parsed backtrace frames, request context, and deploy SHA at the time of the event. Cleanup may delete occurrence rows while the group's lifetime count remains.
_Avoid_: event, record, entry

**Fingerprint**:
A SHA256 hash of `exception_class + relative first_app_frame_file#method_name`. Determines which ExceptionGroup an ExceptionOccurrence belongs to. The file path is relative to `Rails.root` (or the `app/` / `lib/` / `config/` suffix) so it is stable across deploys. Stable across line-number changes; changes only when the method is renamed or moved.
_Avoid_: hash, digest, key

**First app frame**:
The first backtrace frame whose file path matches `/app/`, `/lib/`, or `/config/` and does not match a gem path (`/gems/`, `/rubygems/`, `/bundler/`, `/lib/ruby/`). Used as the canonical location for fingerprinting and grouping.
_Avoid_: stack frame, top frame

**Status** (on ExceptionGroup):
Lifecycle state: `open` (active), `resolved` (fixed), `ignored` (known, not worth acting on). A resolved group auto-reopens to `open` when a new occurrence arrives. An ignored group does not reopen automatically. New occurrences for an ignored group are not stored — the group's `occurrence_count` and `last_seen_at` still update, but no ExceptionOccurrence row is created.
_Avoid_: state, flag

**Preserve** (on ExceptionGroup):
A boolean flag that exempts a group from all automatic cleanup — count-based pruning, orphan deletion, and deletion of that group's occurrence rows. Independent of status; a group can be both `resolved` and preserved.
_Avoid_: pin, keep, retain

### Capture

**ExceptionSubscriber**:
The ActiveSupport::Notifications subscriber that fires on `process_action.action_controller` and passes the exception (if any) to the ExceptionCaptureService. Skips an exception already recorded by JobRunCollector on the same request (`perform_now`).

**JobRunCollector**:
On a failed job, calls ExceptionCaptureService so background-job exceptions are grouped alongside web-request ones. Rake tasks are not captured automatically.

**ExceptionCaptureService**:
The service that parses the backtrace, computes the fingerprint, upserts the ExceptionGroup, creates the ExceptionOccurrence, and handles the resolved→open reopen transition.
