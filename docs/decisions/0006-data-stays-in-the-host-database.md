# All data stays in the host's own database

_Recorded 2026-09, reconstructing a decision made in the initial design (2025)._

Rails Pulse writes everything it collects to tables in the host app's database (or a second database the host owns, via `config.connects_to`). There is no hosted service, no agent process, no outbound connection, and no API key. Users install a gem and a migration, not an account.

The alternative was the conventional APM shape: a lightweight agent in the app shipping events to a vendor backend. That gives better query performance at scale and lets the dashboard survive the app being down, but it means customer request data, SQL text and exception messages leave the customer's infrastructure. The gem's premise is that a large class of Rails apps would rather have monitoring they can run under their own compliance rules than monitoring that is slightly better and lives elsewhere.

The cost is real and shapes the rest of the design: the dashboard queries compete with the app for the database, retention has to be enforced by the gem (`CleanupJob`, `max_table_records`), summaries have to be precomputed because raw rows are too many to aggregate at read time, and the standalone dashboard is a second process against the same database rather than a separate service.

Any feature that requires sending data out of the host, including alerting through third-party services, is out of scope for the core gem under this decision.
