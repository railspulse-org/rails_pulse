---
name: rails-pulse
description: Investigate Rails application performance with Rails Pulse. Use when asked about slow endpoints, regressions after a deploy, expensive or N+1 SQL, error rates, failing background jobs, or whether a performance fix worked. Prefers the rails_pulse_* MCP tools; falls back to the rails-pulse CLI.
---

# Rails Pulse

Rails Pulse records every request, SQL query, background job and exception of a Rails application in the application's own database. This skill gives you read access to that data so you can find what is slow, why, and whether a change fixed it. Nothing here can modify the application.

## When to use it

- Investigating a performance complaint or a slow endpoint
- Diagnosing a regression after a deployment
- Finding expensive or N+1 SQL queries
- Investigating an increased error rate
- Analysing background job failures or slowness
- Validating whether a performance fix worked
- Reviewing or tuning alerting (extension)

## Interfaces

### MCP tools (preferred when available)

All tools are read-only. Each returns a `summary` and `next_steps`.

| Tool | Purpose |
|------|---------|
| `rails_pulse_routes` | Discover endpoints: request volume, latency and errors per route |
| `rails_pulse_slow_requests` | The slowest endpoints for a period |
| `rails_pulse_errors` | Recent 4xx/5xx responses grouped by endpoint |
| `rails_pulse_endpoint` | Deep profile of one endpoint |
| `rails_pulse_queries` | Most expensive SQL queries, with N+1 detection |
| `rails_pulse_jobs` | Background job health and recent failures with error classes |
| `rails_pulse_deployments` | Recent deployments; with the extension, each one's regression check outcome |
| `rails_pulse_request_stats` | Weekly or monthly stats with the change against the previous period (extension) |
| `rails_pulse_alerts` | Recent alert triggers grouped by rule (extension) |
| `rails_pulse_alert_rules` | Configured alert rules, cooldown state, quiet hours (extension) |
| `rails_pulse_suggested_thresholds` | Backtested threshold suggestions for new alert rules (extension) |
| `rails_pulse_setup` | Setup and tuning checklist with paste-ready config snippets (extension) |

Tools marked extension need an extension the application may not have. Without it they return `requires_extension: true` with a message. Relay that to the user once and carry on with the other tools; do not retry.

### CLI

The `rails-pulse` executable ships with the gem. Add `--json` for structured output.

| Command | Purpose |
|---------|---------|
| `rails-pulse routes list --json` | Tracked routes (add `--since` for stats) |
| `rails-pulse requests list --json` | Recorded requests with status and time filters |
| `rails-pulse queries list --json` | SQL queries (add `--since` for timing stats) |
| `rails-pulse jobs list --json` | Background jobs with lifetime stats |
| `rails-pulse job_runs list --json` | Individual job runs with error class and message |
| `rails-pulse deployments list --json` | Deployments (regression outcomes with the extension) |
| `rails-pulse alerts list --json` | Fired alert events (extension) |
| `rails-pulse alert_rules list --json` | Configured alert rules (extension) |
| `rails-pulse thresholds show --json` | Suggested alert thresholds (extension) |
| `rails-pulse summary show --json` | Weekly or monthly performance summary (extension) |
| `rails-pulse setup check --json` | Setup and tuning checklist (extension) |

## Investigation workflow

### 1. Establish the time period

Check recent deployments first; a regression usually lines up with one.

```
rails_pulse_deployments(period: "last_7_days")
rails-pulse deployments list --json
```

With the regression extension, a deployment with `regression_outcome: "triggered"` names the metric that moved and when.

### 2. Identify affected endpoints

```
rails_pulse_slow_requests(period: "last_24_hours", limit: 10)
rails_pulse_routes(search: "checkout", period: "last_7_days")
rails-pulse requests list --limit 50 --json
```

### 3. Profile the suspect endpoint

```
rails_pulse_endpoint(endpoint: "CheckoutController#create", period: "last_7_days")
rails-pulse requests list --since 2026-06-01T00:00:00Z --json
```

### 4. Check errors

```
rails_pulse_errors(period: "last_24_hours", status: "5xx")
rails-pulse requests list --status 5xx --since 2026-06-01T00:00:00Z --json
```

### 5. Inspect SQL and background jobs

```
rails_pulse_queries(period: "last_24_hours", sort: "total_duration")
rails_pulse_queries(n_plus_one_only: true)
rails_pulse_jobs(period: "last_24_hours")
rails-pulse queries list --since 2026-06-01T00:00:00Z --json
rails-pulse job_runs list --status failed --json
```

### 6. Correlate with source code

Use the `controller#action` name to find the code. Look for N+1 queries, missing indexes, expensive work in the request path, unnecessary serialization and missing caching.

### 7. Fix, then validate

After the fix is deployed, re-check the same endpoint over the period since the deploy.

```
rails_pulse_deployments(period: "last_24_hours")
rails_pulse_endpoint(endpoint: "CheckoutController#create", period: "last_hour")
```

## Alerting and setup workflows (extension)

Only when these tools answer with data rather than `requires_extension`.

**Alerting.** `rails_pulse_alert_rules` shows what is configured, disabled, noisy (high `trigger_count_7d`) or silent. `rails_pulse_alerts(period: "last_7_days")` shows what fired. `rails_pulse_suggested_thresholds(days: 14)` proposes strict, balanced and relaxed thresholds backtested against real traffic; `would_have_fired` is the number of hours in the window that would have triggered. Check `existing_rules` before proposing a rule for a metric that is already covered. Rules live in Ruby config, not the database.

**Setup and tuning.** Run `rails_pulse_setup` (or `rails-pulse setup check --json`) about a week after install and every few months after. It returns ordered `findings`, each with a `status`, a `reason` and where relevant a `snippet` and the `file` it belongs in. If `phase` is `install` there is not enough data yet: fix any `missing` data-flow findings, report `next_check`, and stop; do not guess thresholds. Apply `missing`, `needs_attention` and `suggested` snippets to the file each finding names. Snippets use `REPLACE_WITH_EMAIL` and `REPLACE_WITH_HOST` placeholders because the API never returns delivery targets; ask the user for real values and never invent them. `pending` findings are configured but have not had time to run; report them as not verified yet, not as problems.

## Guidelines

- **SQL is not always the cause.** External API calls, serialization, view rendering and application logic slow requests too.
- **Use more than one tool.** Cross-reference latency with error rates, SQL timing and job performance before concluding.
- **Check the error rate.** A fast endpoint with a high error rate may be failing early rather than performing well.
- **Read percentiles, not just averages.** A low average with a high p95 or p99 means intermittent trouble.
- **Weigh request volume.** A slow endpoint nobody calls may not be worth the work.
- **Job aggregates are all-time.** `rails_pulse_jobs` counts and percentiles cover the job's whole history; only `recent_failures` is scoped to the period.

## Authentication

The CLI and MCP server read credentials from environment variables or `~/.rails-pulse`. The token is `config.api_token` in the application's Rails Pulse initializer.

```
RAILS_PULSE_URL=https://myapp.com
RAILS_PULSE_TOKEN=my-secret-token
RAILS_PULSE_MOUNT_PATH=/rails_pulse   # optional, default /rails_pulse
```

```yaml
# ~/.rails-pulse
url: https://myapp.com
token: my-secret-token
mount_path: /rails_pulse
```

Interactive setup: `rails-pulse configure`.

## CLI reference

List commands accept `--limit N` (1 to 500, default 25), `--offset N` and `--json`. Time-based commands also accept `--since TIME` and `--until TIME` as ISO 8601. JSON output is `{ "data": [...], "meta": { "total", "limit", "offset" } }`; page with `--offset`.
