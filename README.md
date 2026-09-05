<div align="center">
  <img src="app/assets/images/rails_pulse/rails-pulse-logo.png" alt="Rails Pulse" width="200" />
</div>

---

# Rails Pulse

**Self-hosted performance monitoring for Rails apps**

![Gem Version](https://img.shields.io/gem/v/rails_pulse)
![Rails Version](https://img.shields.io/badge/Rails-7.2%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)
![Ruby Version](https://img.shields.io/badge/Ruby-3.0%2B-red)

Rails Pulse is a Rails engine that monitors your app's performance from the inside. It tracks slow requests, N+1 queries, SQL performance, background jobs, and unhandled exceptions. All data stays in your own database, no third-party cloud, no SaaS subscription, no data leaving your servers.

<table border="0">
  <tr border="0" style="border:0">
    <td border="0" style="border:0">
    <img src="app/assets/images/rails_pulse/dashboard.png" alt="Dashboard" width="400" /></td>
    <td style="border:0"><img src="app/assets/images/rails_pulse/request-show.png" alt="Request detail" width="400" /></td>
  </tr>
  <tr>
    <td style="border:0"><img src="app/assets/images/rails_pulse/query-show.png" alt="Query detail" width="400" /></td>
    <td style="border:0"><img src="app/assets/images/rails_pulse/route-show.png" alt="Route detail" width="400" /></td>
  </tr>
</table>

## Installation

Add to your Gemfile:

```ruby
gem 'rails_pulse'
```

Run the installer:

```bash
bundle install
rails generate rails_pulse:install
rails db:migrate
```

Mount the dashboard in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount RailsPulse::Engine => "/rails_pulse"
end
```

Schedule the background jobs:

```ruby
RailsPulse::SummaryJob.perform_later  # cron: 5 * * * *
RailsPulse::CleanupJob.perform_later  # cron: 0 1 * * *
```

Your dashboard is now at `http://localhost:3000/rails_pulse`.

## Upgrading

From 0.3.3:

```bash
bundle update rails_pulse
rails generate rails_pulse:upgrade
rails db:migrate                  # or: rails db:migrate:rails_pulse
rails rails_pulse:migrate_routes  # required — fills Action and merges same-action paths
```

Restart all processes after migrate. This release changes how routes are stored (`method` moves off the route onto each request), so mixed old/new processes are not supported.

The upgrade generator appends new settings to `config/initializers/rails_pulse.rb` without rewriting what you already set. Review with `git diff` and keep or discard hunks.

To see where an install stands at any point — schema, unrun migration files, route backfill, initializer — run `rails rails_pulse:status`. It exits 1 when something needs action, so it can gate a deploy.

Exception tracking is **off** for existing installs. The generator inserts `config.track_exceptions = false`; set it to `true` after migrating to opt in:

```ruby
config.track_exceptions = true
config.capture_exception_params = true  # params are filtered via Rails' filter_parameters
```

Separate-database hosts: set `schema_dump: false` on the `rails_pulse` entry in `config/database.yml` and delete `db/rails_pulse_structure.sql` if that file exists.

If you previously added `rails-pulse.js` / `rails-pulse.css` to `config.assets.precompile`, remove those entries — the gem no longer registers dashboard assets with Sprockets (that re-minify OOMs small hosts). Production deploys that use `config.asset_host` or a CDN-only CSP should run `assets:precompile` so `rails_pulse:install_assets` copies digested files into `public/assets`.

Full install guide: [railspulse.com/documentation/installation](https://railspulse.com/documentation/installation)

Separate database setup: [railspulse.com/documentation/database](https://railspulse.com/documentation/database)

## Configuration

Rails Pulse works out of the box with sensible defaults. To customise, edit `config/initializers/rails_pulse.rb`:

```ruby
RailsPulse.configure do |config|
  config.enabled = true

  config.request_thresholds = {
    slow: 700,
    very_slow: 2000,
    critical: 4000
  }

  config.track_jobs = true
  config.capture_job_arguments = false  # keep false to protect sensitive data

  config.track_exceptions = true
  config.capture_exception_params = true  # params are filtered via Rails' filter_parameters

  config.full_retention_period = 30.days
end
```

Full configuration reference: [railspulse.com/documentation/advanced](https://railspulse.com/documentation/advanced)

## Authentication

Rails Pulse has no built-in user accounts; you protect the dashboard using your app's existing auth. Authentication is on by default outside development and test, and with nothing configured it falls back to HTTP Basic against `RAILS_PULSE_USERNAME` / `RAILS_PULSE_PASSWORD` (denying everything if the password is unset).

The simplest hook is a predicate that receives the controller and returns `true` to allow — anything else is a 403:

```ruby
RailsPulse.configure do |config|
  config.authorize = ->(controller) { controller.current_user&.admin? }
end
```

If you need to redirect to a login page instead, use `authentication_method`, which runs inside the controller and denies by rendering or redirecting:

```ruby
RailsPulse.configure do |config|
  config.authentication_redirect_path = "/login"

  config.authentication_method = proc {
    unless user_signed_in? && current_user.admin?
      redirect_to main_app.root_path, alert: "Access denied"
    end
  }
end
```

Returning `false` from `authentication_method` without responding is also treated as a denial, but `nil` (what `unless … end` returns on success) allows the request — so keep predicate-style checks in `authorize`.

Authentication guide: [railspulse.com/documentation/authentication](https://railspulse.com/documentation/authentication)

## Features

- **Request monitoring** — every request is timed and stored with its route, status, SQL count, and duration. Slow requests are flagged automatically based on thresholds you control.
- **Query analysis** — captures the queries behind each request, detects N+1 patterns, and tracks normalized SQL across requests so you can see which queries are hurting you in production, not just in development.
- **Job tracking** — monitors background job duration, queue wait time, and failure rates. Works with any Active Job adapter.
- **Exception tracking** — captures unhandled exceptions from web requests and background jobs, groups them by class and location, and shows full backtraces with filtered request params. See recurring errors in production without a separate error monitoring service.
- **System health bar** — at-a-glance dashboard summary showing healthy, slow, and critical counts across your routes, queries, jobs, and storage. Lets you see the overall state of your app before drilling into specifics.
- **No data leaves your app** — everything is stored in your own database. No third-party cloud, no SaaS subscription, no outbound connections.
- **Low overhead** — tracking is async and uses a thread-local flag to skip recording Rails Pulse's own internal requests.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/railspulse/rails_pulse).

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).
