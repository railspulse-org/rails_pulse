# The standalone dashboard is the mounted engine booted from the host app, not a separate application

_Recorded 2026-09, reconstructing a decision made when standalone mode was added (0.3)._

`rails_pulse_server` loads the host's `config/environment.rb` from the current directory, sets `RailsPulse.standalone!`, and serves `RailsPulse::Engine` at `/` behind a minimal Rack stack (`Rack::Static`, `Rack::MethodOverride`, `ActionDispatch::Cookies`, `ActionDispatch::Session::CookieStore`). It refuses to boot without a host environment.

The alternative was a self-contained dashboard application that connects to the database directly and needs no host code. That would run anywhere, including on a machine without the app deployed, and could have its own authentication stack.

Booting the host won because the dashboard depends on the host in ways a standalone app cannot replicate: `config/initializers/rails_pulse.rb` (thresholds, tags, SLOs, `connects_to`), the host router for resolving `controller_action` and linking routes, the host models for query and exception context, and the host's `secret_key_base` and `filter_parameters`. Duplicating that configuration in a second app is the drift problem the gem exists to avoid.

Two consequences follow and are handled in `RailsPulse::Standalone` rather than left to users. Engine URL helpers prefix the mount path from the host route set, which 404s when the engine is served at `/`, so `standalone!` overrides `find_script_name` to return an empty string in this process only. And the host's session, Warden and Devise helpers cannot run here, so `authentication_method` and `authorize` are ignored in favour of `standalone_authentication_method`, falling back to HTTP Basic. The cost is that the standalone process must be deployed from the same image or checkout as the app, which the Kamal accessory pattern in the docs assumes.
