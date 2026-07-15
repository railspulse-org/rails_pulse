# Deployment Modes

End-user / ops guide for running the Rails Pulse **dashboard**. Product install docs also live on [railspulse.com](https://railspulse.com). Maintainer notes about migrations are in `docs/database_setup.md`.

## Embedded mode

Dashboard runs inside the host Rails app (default).

```ruby
# config/initializers/rails_pulse.rb
RailsPulse.configure do |config|
  config.mount_dashboard = true  # default in RailsPulse::Configuration
end
```

```ruby
# config/routes.rb
mount RailsPulse::Engine => "/rails_pulse"
```

Access: `https://myapp.com/rails_pulse`.

**Tradeoffs:** same process and auth as the app; no extra process; dashboard shares app resources and goes down with the app.

## Standalone mode

Dashboard as a separate Rack process using `lib/rails_pulse_server.ru`.

```ruby
RailsPulse.configure do |config|
  config.mount_dashboard = false
end
```

Also remove or comment out `mount RailsPulse::Engine` in the main app routes so the UI is not also exposed there. `mount_dashboard` controls dashboard-related middleware/assets initialization; routes control URL accessibility.

### `SECRET_KEY_BASE`

Required for every standalone boot. `rails_pulse_server.ru` always calls `ENV.fetch("SECRET_KEY_BASE")` and raises if it is unset (session cookie secret).

### How the process loads

`lib/rails_pulse_server.ru` picks a load path from the **current working directory**:

1. **`test/dummy/config/environment.rb` present** (gem checkout) — boots the dummy Rails app.
2. **`config/environment.rb` present** (typical host app) — boots that Rails app. Database and `RailsPulse` config come from the app’s usual initializer / `database.yml` / `DATABASE_URL` handling. The server file does **not** re-parse `database.yml` in this branch.
3. **Neither present** — minimal boot: requires the gem, then connects using:
   - `DATABASE_URL` if set, else
   - `config/database.yml` for `RAILS_ENV` (default `production`), preferring a `rails_pulse` entry then falling back to the primary entry, else
   - raises. In this branch it also sets `config.enabled = false` so the dashboard process does not record tracking data, and calls `RailsPulse::ApplicationRecord.establish_connection`.

Recommended production pattern: run from the **host app** directory (path 2) with `SECRET_KEY_BASE` set, after configuring Rails Pulse in the app as usual. Prefer the gem’s executable (resolves the rackup file inside the installed gem):

```bash
export SECRET_KEY_BASE=...
bundle exec rails_pulse_server
# equivalent: rackup <gem>/lib/rails_pulse_server.ru -p 3001
# PORT overrides the default 3001
```

Only use `bundle exec rackup lib/rails_pulse_server.ru` when that file exists in the current tree (for example while developing inside this gem checkout).

### Healthcheck

`GET /health` on the standalone server returns JSON:

```json
{
  "status": "ok",
  "mode": "dashboard",
  "database": "connected",
  "timestamp": "<ISO8601>"
}
```

HTTP **200** when `RailsPulse::Tracker.healthy?` succeeds (`SELECT 1` on `RailsPulse::ApplicationRecord`), otherwise **503** with `"unhealthy"` / `"disconnected"`. Suitable for Kamal/Docker/Kubernetes probes.

Example Kamal accessory (illustrative — adjust image/cmd to match how you ship the host app):

```yaml
accessories:
  rails_pulse:
    image: your-app-image
    host: your-server
    cmd: bundle exec rails_pulse_server
    env:
      clear:
        RAILS_ENV: production
        SECRET_KEY_BASE: <%= ENV.fetch("SECRET_KEY_BASE") %>
        # Plus whatever DB config your app boot needs (DATABASE_URL, etc.)
        # Optional: PORT: "3001"
    port: "3001:3001"
    healthcheck:
      path: /health
      port: 3001
```

## Tracking: async vs sync

`RailsPulse.configuration.async` defaults to **`true`**. When true, `RailsPulse::Tracker.track_request` wraps persistence in `Async { ... }`; when false, it runs synchronously.

Host apps may set `config.async = false` for synchronous writes. The gem’s own test dummy sets `config.async = false if Rails.env.test?` so the suite is deterministic — that is a **test/dummy** setting, not something the gem forces on every host app in `test`.

## Migrating embedded → standalone

1. Start the standalone process and confirm `/health` and the UI.
2. Set `mount_dashboard = false` and unmount the engine from main routes.
3. Deploy the main app; keep using the standalone URL.
