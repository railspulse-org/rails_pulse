# One `rails_pulse_events` table holds what Pulse notices, for the free gem and for Pro

_Recorded 2026-09, before 1.0 and before the first Pro release._

`rails_pulse_events` is a single generic table: `kind`, `subject`, `outcome`, `value`, `occurred_at`, `message` and JSON `metadata`, indexed by kind and time and by kind, subject and time. The free gem writes one kind into it, the background writer's once-a-minute heartbeat (`WriterHeartbeat`). `rails_pulse_pro` writes its alert triggers, deployment regression checks, exception alerts and job heartbeats into the same table instead of shipping `rails_pulse_pro_events`, and registers the kinds it updates in place in `config.event_retention_exempt_kinds`. `CleanupService` prunes everything else by `config.event_retention_period`; the writer prunes its own heartbeats after a day.

The alternative was one table per shape: a typed heartbeats table here and Pro's events table there. Typed columns read better, and the heartbeat's queue depth would be a column rather than a JSON key. It was rejected because the shapes are nearly the same (a kind, a subject, a number, a time, a message, some detail), because a host should migrate as few tables as possible (Pro's own decision 0002 already chose one table over two for that reason), and because with one table Pro installs with no migration at all: add the gem, write the initializer, schedule the job. Neither gem had shipped its table yet, so there was nothing to migrate.

The cost is that the heartbeat's secondary fields live in `metadata` and are parsed in Ruby. The reads that need them touch a handful of rows (the latest sample per live process); the read that runs across many rows, drops in the last hour, is a `SUM(value)` over the kind and time index. Heartbeats are most of the rows, so a kind filter is required on every query, and retention is per kind rather than per table.

A `kind` is a string, not an enum, on purpose: Pro adds kinds without the free gem knowing them, and a future free feature (a summary-job heartbeat, a schema-check notice) adds a kind without a migration.
