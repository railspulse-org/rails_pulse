# Rails Pulse — Agent Integration

Rails Pulse gives AI coding agents read access to a Rails application's performance data: requests, SQL queries, background jobs, exceptions and deployments, all from the application's own database. Two interfaces, one token.

## MCP server

```
rails-pulse mcp
```

The server needs the `mcp` gem, which Rails Pulse does not depend on: add `gem "mcp", "~> 1.0"` to the application's Gemfile (a development group is enough), or `gem install mcp` when running `rails-pulse` outside Bundler.

**Claude Code** (`~/.claude.json`):
```json
{
  "mcpServers": {
    "rails-pulse": {
      "command": "rails-pulse",
      "args": ["mcp"],
      "env": {
        "RAILS_PULSE_URL": "https://myapp.com",
        "RAILS_PULSE_TOKEN": "your-token"
      }
    }
  }
}
```

**Cursor** (`.cursor/mcp.json`):
```json
{
  "mcpServers": {
    "rails-pulse": { "command": "rails-pulse", "args": ["mcp"] }
  }
}
```

### Tools

All tools are read-only. Each returns a `summary` and `next_steps`.

| Tool | Purpose |
|------|---------|
| `rails_pulse_routes` | Discover endpoints with request volume, latency and errors |
| `rails_pulse_slow_requests` | Slowest endpoints for a period |
| `rails_pulse_errors` | Recent errors grouped by endpoint |
| `rails_pulse_endpoint` | Deep performance profile of one endpoint |
| `rails_pulse_queries` | Most expensive SQL queries with N+1 detection |
| `rails_pulse_jobs` | Background job health and recent failures |
| `rails_pulse_deployments` | Deployments; regression check outcomes with the extension |
| `rails_pulse_request_stats` | Period stats with comparison against the previous period (extension) |
| `rails_pulse_alerts` | Recent alert triggers grouped by rule (extension) |
| `rails_pulse_alert_rules` | Configured alert rules and their state (extension) |
| `rails_pulse_suggested_thresholds` | Backtested alert threshold suggestions (extension) |
| `rails_pulse_setup` | Setup and tuning checklist with paste-ready config snippets (extension) |

Tools marked extension need an extension the application may not have. Without it they return `requires_extension: true` with a message instead of data. Relay that once and continue with the other tools.

## CLI

The `rails-pulse` CLI works without MCP. Append `--json` for structured output.

| Command | Description |
|---------|-------------|
| `rails-pulse routes list` | Tracked routes (`--since` adds request stats) |
| `rails-pulse requests list` | Recorded requests with status and time filters |
| `rails-pulse queries list` | SQL queries (`--since` adds timing stats) |
| `rails-pulse jobs list` | Background jobs with performance stats |
| `rails-pulse job_runs list` | Individual job runs with errors |
| `rails-pulse deployments list` | Deployments (regression outcomes with the extension) |
| `rails-pulse alerts list` | Fired alert events (extension) |
| `rails-pulse alert_rules list` | Configured alert rules (extension) |
| `rails-pulse thresholds show` | Suggested alert thresholds (extension) |
| `rails-pulse summary show` | Weekly or monthly performance summary (extension) |
| `rails-pulse setup check` | Setup and tuning checklist (extension) |

Common flags: `--limit N` (1 to 500, default 25), `--offset N`, `--json`, `--since TIME` / `--until TIME` (ISO 8601).

## Authentication

Set `RAILS_PULSE_URL` and `RAILS_PULSE_TOKEN` (the application's `config.api_token`), or run `rails-pulse configure` to write `~/.rails-pulse`.

## Investigation pattern

1. Pin the time window to a deployment (`rails_pulse_deployments`)
2. Identify slow or failing endpoints (`rails_pulse_slow_requests`); resolve names with `rails_pulse_routes`
3. Profile the suspect endpoint (`rails_pulse_endpoint`)
4. Check errors (`rails_pulse_errors`)
5. Inspect SQL and jobs (`rails_pulse_queries`, `rails_pulse_jobs`)
6. Correlate with source code
7. Fix, deploy, and re-check the same endpoint

## Alerting and setup patterns (extension)

**Alerting.** Review configured rules (`rails_pulse_alert_rules`) and what fired (`rails_pulse_alerts`), get backtested suggestions (`rails_pulse_suggested_thresholds`), and recommend changes to `config.alerts` in the alerting initializer.

**Setup and tuning.** Run `rails_pulse_setup` about a week after install and every few months after. If `phase` is `install`, fix the `missing` data-flow findings and re-run later rather than guessing thresholds. Apply each `missing`, `needs_attention` and `suggested` snippet to the file named on the finding. Replace `REPLACE_WITH_EMAIL` and `REPLACE_WITH_HOST` with values from the user; the API never returns delivery targets. Treat `pending` findings as not yet verified, not as problems.
