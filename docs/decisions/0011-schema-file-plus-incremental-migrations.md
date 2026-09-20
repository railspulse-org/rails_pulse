# Fresh installs load one schema file; existing installs run incremental migrations

`db/rails_pulse_schema.rb` defines every table and is the source of truth. A fresh install copies it into the host and runs one migration that executes it. Each later change ships as a guarded migration in `db/rails_pulse_migrate/`, copied into the host by `rails generate rails_pulse:upgrade`. The schema file only ever creates tables that do not exist; it never alters one.

The rejected alternative was ordinary engine migrations from day one: a growing chain of files that every install, new or old, replays in order. That is what most engines do. It was rejected because a new user would run dozens of migrations to reach a state one file describes, every migration would have to stay valid against every intermediate schema forever, and a mistake in one old migration breaks fresh installs as well as upgrades.

The cost is that every schema change touches several places (see `docs/migrations.md`), the generator template copy of the schema must be kept identical, and the upgrade generator needs a fallback (`detect_missing_columns`) for hosts whose migration history and schema file disagree. Tests in `test/migrations/` replay upgrades from a v0.2.7 snapshot to catch drift.
