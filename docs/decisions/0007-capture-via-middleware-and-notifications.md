# Capture uses Rack middleware and ActiveSupport::Notifications, not monkey patches

_Recorded 2026-09, reconstructing a decision made in the initial design (2025)._

Requests are timed by `RailsPulse::Middleware::RequestCollector`, inserted at the end of the host's middleware stack. Everything inside a request is captured by `OperationSubscriber`, which subscribes to the instrumentation events Rails already emits: `sql.active_record`, `process_action.action_controller`, the `render_*.action_view` events, `cache_read` / `cache_write.active_support`, `request.net_http`, `perform.active_job`, `deliver.action_mailer` and `service_upload.active_storage`. Per-request state lives in `RequestStore` until the middleware hands it to the tracker.

The rejected alternative was patching `ActiveRecord::Base`, `ActionController::Base` and friends to time calls directly, which is how several commercial agents work. Patches see more (arguments, return values, code paths Rails does not instrument) but break on Rails upgrades, conflict with other gems that patch the same methods, and are hard to make safe under concurrency.

The accepted limits: Rails Pulse can only measure what Rails instruments. Time outside the middleware stack (Puma queueing, TLS) is invisible; libraries that do not emit notifications (raw `Net::HTTP` subclasses, some HTTP clients, Redis) are not captured unless they adopt Rails' instrumentation. Adding a new operation type means subscribing to an existing event, never adding a patch.
