# Deployment Modes

Rails Pulse offers flexible deployment options for the dashboard UI. Choose the mode that best fits your infrastructure and performance requirements.

## Dashboard Deployment Options

### Embedded Mode (Development/Staging)

The dashboard runs within your main Rails application process.

**Configuration:**

```ruby
# config/initializers/rails_pulse.rb
RailsPulse.configure do |config|
  config.mount_dashboard = true  # Default
end
```

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount RailsPulse::Engine => "/rails_pulse"
  # ... your other routes
end
```

**Access:** `https://myapp.com/rails_pulse`

**Use cases:**
- Development and testing environments
- Staging servers
- Low-to-medium traffic production apps
- Simple deployments where isolation isn't critical

**Advantages:**
- ✅ Zero additional infrastructure
- ✅ Same authentication/session as main app
- ✅ Simplest setup

**Disadvantages:**
- ❌ Dashboard shares resources with main app
- ❌ Dashboard unavailable if main app is down
- ❌ Scales with app instance count

---

### Standalone Mode (Production Recommended)

The dashboard runs as a separate Rack application process.

**Main App Configuration:**

```ruby
# config/initializers/rails_pulse.rb
RailsPulse.configure do |config|
  config.mount_dashboard = false  # Skip the dashboard asset middleware in the main app
end
```

`mount_dashboard = false` stops the main app inserting the dashboard asset
middleware. It does not affect tracking, and it does not unmount the engine:
whether `/rails_pulse` stays reachable through the main app is decided by the
`mount RailsPulse::Engine` line in `config/routes.rb`. Keep it if other parts
of your app link to `rails_pulse.root_path`; remove it to make the standalone
server the only way in. The standalone process ignores the mount path either
way — its links are generated root-relative (`RailsPulse.standalone?` is true
there), so it never produces `/rails_pulse/...` URLs against itself.

**Authentication:** the standalone process has your models but not your
app's session, Warden or Devise helpers, and runs on its own hostname, so
`config.authentication_method` and `config.authorize` are ignored there. It
uses HTTP Basic auth (`RAILS_PULSE_USERNAME`, default `admin`, and
`RAILS_PULSE_PASSWORD`) unless you set `config.standalone_authentication_method`
to a proc that renders or redirects to deny (the same contract as
`authentication_method`).

**Standalone Server:**

The dashboard is a mounted engine: it needs your app's models, routes and
`config/initializers/rails_pulse.rb` (authentication, database connection), so
the server must start from your Rails application's root directory. It loads
`config/environment.rb` from there and refuses to boot without it.

```bash
cd /path/to/your/app
RAILS_ENV=production bundle exec rackup $(bundle show rails_pulse)/lib/rails_pulse_server.ru -p 3001
```

`RAILS_ENV` matters twice: it selects the database (from `config/database.yml`
or `DATABASE_URL`, exactly as the main app does), and it decides whether
dashboard authentication is on — the default is enabled outside `development`
and `test`, so an unset `RAILS_ENV` boots an unauthenticated dashboard against
the development database.

Two environment variables are required or strongly recommended:

- `SECRET_KEY_BASE` — signs the dashboard's session cookie. When it is not
  set the server falls back to the host app's `secret_key_base` (from
  encrypted credentials or `config/secrets`), and refuses to start only if
  neither is available.
- `RAILS_ENV=production` — see above.

The session cookie is marked `Secure` in production, so it is only sent over
HTTPS. Terminate TLS at your reverse proxy (see the nginx example below). For a
deliberately non-TLS deployment on a private network, set
`RAILS_PULSE_INSECURE_SESSION=1`.

For development against the gem's own dummy app, run the same command from the
gem root instead.

**Deployment with Kamal:**

Deploy the dashboard as an accessory using the same image as your app, so
`config/environment.rb` and your initializer are present:

```yaml
# config/deploy.yml
accessories:
  rails_pulse:
    image: your-app-image  # Same image as your main app
    host: your-server
    cmd: sh -c 'bundle exec rackup $(bundle show rails_pulse)/lib/rails_pulse_server.ru -p 3001'
    env:
      clear:
        RAILS_ENV: production
      secret:
        - SECRET_KEY_BASE
        - DATABASE_URL          # or rely on config/database.yml in the image
    port: "3001:3001"  # Map container port to host port
    healthcheck:
      path: /health
      port: 3001
      interval: 10s
      timeout: 5s
```

**Nginx Configuration:**

```nginx
server {
    server_name pulse.myapp.com;

    location / {
        proxy_pass http://localhost:3001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Use cases:**
- Production environments
- High-traffic applications
- When you need dashboard isolation
- When dashboard needs independent scaling

**Advantages:**
- ✅ Dashboard remains accessible if main app is under load
- ✅ Separate resource allocation
- ✅ Enhanced security isolation
- ✅ Independent scaling
- ✅ Healthcheck endpoint for orchestration tools

**Disadvantages:**
- ❌ Requires additional process/container
- ❌ Separate authentication setup (HTTP Basic by default; see above)
- ❌ Slightly more complex deployment

---

## Tracking Behavior

Rails Pulse persists tracking data on a background thread by default (`config.async = true`), so the database writes for a request do not hold up its response.

- **Production/Development:** the middleware hands each request's data to one writer thread per process through a bounded queue and returns. The writer drains the queue in batches on a single connection from the Rails Pulse pool, so tracking never holds more than one of your app's connections no matter how bursty traffic gets.
- **Queue full:** when the writer cannot keep up (`config.async_queue_size`, default 1000 pending requests) the newest request is dropped rather than blocking the app. Drops are counted and logged at most once a minute; `RailsPulse::Tracker.stats` reports the queue depth and lifetime drop count.
- **Shutdown:** an `at_exit` hook drains the queue (up to 5 seconds) so a graceful restart does not lose the last requests. `RailsPulse::Tracker.flush!` does the same on demand.
- **Test:** writes happen inline. The generated initializer sets `config.async = false if Rails.env.test?`, and the tracker also falls back to inline writes on its own whenever it detects a transactional-test connection, because Rails shares that single connection with every thread.

**Performance Impact:**
- The request thread only pushes the collected data onto the queue; SQL normalisation and N+1 detection run on the writer
- Database writes happen off the request thread, and a batch of requests shares one connection checkout and one operations insert
- Set `config.async = false` to write inline before the response is sent

---

## Healthcheck Endpoint

The standalone dashboard includes a healthcheck endpoint at `/health` that verifies database connectivity.

**Testing the healthcheck:**
```bash
curl http://localhost:3001/health
```

**Response when healthy (200 OK):**
```json
{
  "status": "ok",
  "mode": "dashboard",
  "database": "connected",
  "timestamp": "2025-11-30T12:00:00Z"
}
```

**Response when unhealthy (503 Service Unavailable):**
```json
{
  "status": "unhealthy",
  "mode": "dashboard",
  "database": "disconnected",
  "timestamp": "2025-11-30T12:00:00Z"
}
```

**Use this endpoint with:**
- Kamal healthcheck configuration
- Docker/Kubernetes liveness and readiness probes
- Load balancer health checks
- External monitoring systems (Pingdom, UptimeRobot, etc.)

---

## Recommendation by Environment

| Environment | Recommended Mode | Rationale |
|-------------|-----------------|-----------|
| Development | Embedded | Simplicity, immediate access |
| Test | Embedded | Easier test setup |
| Staging | Embedded or Standalone | Depends on production similarity goals |
| Production (< 10 req/s) | Embedded | Simple deployment acceptable |
| Production (> 10 req/s) | Standalone | Better isolation and reliability |
| Production (High Traffic) | Standalone | Critical for dashboard availability |

---

## Migration from Embedded to Standalone

1. **Deploy standalone server** (no changes to main app yet):
   ```bash
   bundle exec rackup lib/rails_pulse_server.ru -p 3001
   ```

2. **Verify dashboard works** at standalone URL

3. **Update main app config**:
   ```ruby
   config.mount_dashboard = false
   ```
   Optionally remove `mount RailsPulse::Engine` from `config/routes.rb` so
   the embedded dashboard is no longer reachable.

4. **Deploy main app changes**

5. **Update documentation/bookmarks** with new dashboard URL

This allows zero-downtime migration.
