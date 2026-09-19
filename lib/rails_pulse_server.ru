# Load the host Rails environment. The dashboard is a mounted engine and needs
# the host's models, routes and initializer (authentication, database), so run
# this from the Rails application's root — or from the gem root, which loads
# the dummy app for development.
if File.exist?("test/dummy/config/environment.rb")
  require_relative "../test/dummy/config/environment"
elsif File.exist?("config/environment.rb")
  require File.expand_path("config/environment", Dir.pwd)
else
  abort <<~MESSAGE
    RailsPulse standalone dashboard: config/environment.rb not found in #{Dir.pwd}.

    Run from your Rails application's root directory:

      cd /path/to/your/app
      RAILS_ENV=production bundle exec rackup $(bundle show rails_pulse)/lib/rails_pulse_server.ru -p 3001

    RAILS_ENV selects the database and enables dashboard authentication.
  MESSAGE
end

# Root-relative links and standalone authentication — see lib/rails_pulse/standalone.rb.
RailsPulse.standalone!

# Disable output buffering so logs appear immediately
$stdout.sync = true
$stderr.sync = true

# Build the Rack app with session support
require "rack/session/cookie"
require "rack/static"
require "rack/method_override"
require "securerandom"
require_relative "rails_pulse/rack_compat"
require_relative "rails_pulse/middleware/asset_server"

# Simple Rack app that just serves the dashboard
class DashboardApp
  def initialize
    @dashboard = RailsPulse::Engine
  end

  def call(env)
    # Health check endpoint
    if env["PATH_INFO"] == "/health"
      healthy = RailsPulse::Tracker.healthy? rescue false
      status_code = healthy ? 200 : 503

      return [
        status_code,
        { "content-type" => "application/json" },
        [ {
          status: healthy ? "ok" : "unhealthy",
          mode: "dashboard",
          database: healthy ? "connected" : "disconnected",
          timestamp: Time.now.iso8601
        }.to_json ]
      ]
    end

    # All other requests go to RailsPulse Engine (dashboard)
    @dashboard.call(env)
  end
end

# Dashboard assets. RouteHelper#asset_path emits one of two URL shapes: the
# gem-served fallback (/rails-pulse-assets/<version>/...) or, once
# assets:precompile has run, the digested copies it installs under the host's
# public/assets. In the main app those are served by AssetServer (inserted
# into the host middleware stack by the engine) and by ActionDispatch::Static
# or the CDN. This process calls the engine directly and has neither, so both
# are served here; without them every dashboard page renders unstyled.
use RailsPulse::Middleware::AssetServer,
  RailsPulse::Engine.root.join("public").to_s,
  urls: [ "/rails-pulse-assets" ],
  headers: RailsPulse::Engine.asset_headers

use Rack::Static,
  urls: [ "/assets" ],
  root: Rails.public_path.to_s,
  header_rules: [ [ :all, RailsPulse::Engine.asset_headers ] ]

# The mounted engine gets this from the host app's default stack; here it
# must be added explicitly or the settings forms' PATCH routes 404.
use Rack::MethodOverride

# Add session middleware for the dashboard. The cookie is signed with
# SECRET_KEY_BASE when set, otherwise with the host app's own secret_key_base
# (config/environment.rb is already loaded above) — hosts on encrypted
# credentials have no SECRET_KEY_BASE environment variable.
secret_key = ENV["SECRET_KEY_BASE"].to_s
if secret_key.empty?
  secret_key = begin
    Rails.application.secret_key_base.to_s
  rescue StandardError
    ""
  end
end
if secret_key.empty?
  raise "SECRET_KEY_BASE environment variable must be set for standalone dashboard " \
        "(no Rails secret_key_base was available to fall back to)"
end

# `secure` keeps the session cookie off plain HTTP in production. Set
# RAILS_PULSE_INSECURE_SESSION=1 only for a deliberately non-TLS deployment
# (a private network with no reverse proxy in front).
use Rack::Session::Cookie,
  key: "rails_pulse_session",
  secret: secret_key,
  same_site: :lax,
  httponly: true,
  secure: Rails.env.production? && ENV["RAILS_PULSE_INSECURE_SESSION"].blank?,
  max_age: 86400  # 1 day

run DashboardApp.new
