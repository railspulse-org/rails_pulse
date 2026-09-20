# One polymorphic summaries table serves routes, queries, jobs and the overall rollup

_Recorded 2026-09, reconstructing a decision made in the initial design (2025)._

`rails_pulse_summaries` holds every pre-aggregated period for every subject. The row is keyed by `summarizable_type` / `summarizable_id`, `period_type` (`hour`, `day`, `week`, `month`) and `period_start`, and carries count, average, min, max, P50, P95, P99, total, standard deviation and status buckets. The overall request rollup uses type `RailsPulse::Request` with id 0, and is written even for an empty period so its timestamp serves as `SummaryJob`'s heartbeat.

The alternative was a summary table per subject (`route_summaries`, `query_summaries`, `job_summaries`), each with only the columns that subject needs. That avoids nullable columns and polymorphic joins, and lets each table have its own indexes.

One table won because the dashboard treats all subjects the same way: the same chart classes, the same metric cards, the same percentile maths and the same cleanup query run for a route, a query or a job by changing one `where` clause. `SummaryService` upserts every subject's rows for a period in one bulk statement against a single unique index. Adding a new summarisable subject (deployments, exception groups) is a new `summarizable_type` value, not a new table and a new set of dashboard code.

The accepted costs are nullable columns that only apply to some subjects (status buckets mean nothing for a query), the `summarizable` polymorphic index being the hot path for every dashboard query, and the table being the largest one in the schema after operations. Hourly rows are pruned after `hourly_summary_retention` to keep it bounded.
