# All collected data stays in the host's own database

_Recorded 2026-09, reconstructing a decision made in the initial design (2025)._

Rails Pulse writes everything it collects to tables in the host app's database (or a second database the host owns, via `config.connects_to`). There is no agent process and no outbound connection by default. Users install a gem and a migration, not an account, and the gem is complete without one.

The alternative was the conventional APM shape: a lightweight agent in the app shipping events to a vendor backend. That gives better query performance at scale and lets the dashboard survive the app being down, but it means customer request data, SQL text and exception messages leave the customer's infrastructure. The gem's premise is that a large class of Rails apps would rather have monitoring they can run under their own compliance rules than monitoring that is slightly better and lives elsewhere.

The one exception is Rails Pulse Cloud, and it is opt-in: with `config.cloud.api_key` and `config.cloud.application` unset the gem makes no network calls. When they are set, it sends hourly summaries, exception group and deployment records and a per-minute health update, never the raw rows, SQL values, request URLs or exception messages they are built from (decision 0021). The detail stays here, and Cloud refers back to it by key.

The cost is real and shapes the rest of the design: the dashboard queries compete with the app for the database, retention has to be enforced by the gem (`CleanupJob`, `max_table_records`), summaries have to be precomputed because raw rows are too many to aggregate at read time, and the standalone dashboard is a second process against the same database rather than a separate service.

Any feature that sends data off the operator's own infrastructure other than through the Cloud sync contract, including alerting through third-party services, is out of scope for the gem under this decision. Remote mode, opt-in like Cloud, sends an application's data to a central the operator runs themselves (decision 0023), so it stays on that infrastructure.
