# Testing

## Commands

```bash
DB=sqlite3 rake test                 # default; also runs test/migrations in a separate process afterwards
                                     # refuses to run if the last test_setup was for another adapter
DB=postgresql rake test              # needs POSTGRES_USERNAME/PASSWORD/HOST/PORT (port 5434 locally)
DB=mysql2 rake test                  # needs MYSQL_USERNAME/PASSWORD/HOST/PORT
BROWSER=true DB=sqlite3 rake test    # include system tests; disables parallelisation
COVERAGE=true rake test              # SimpleCov, serial; thresholds 90% total, 80% per file (.simplecov)
rake test_matrix                     # 3 Rails versions (Appraisals) × 3 databases = 9 runs
rake test_migrations                 # upgrade regression tests only
npm run test:js                      # Vitest + JSDOM for Stimulus controllers
bin/test_generators                  # install + upgrade generators against a scratch app
bin/test_separate_database_upgrade   # upgrade from a schema baseline with config.connects_to; BASELINE=V027 for the oldest
```

Never run a bare `rails test` over the repo: it includes `test/migrations/`, whose non-transactional upgrade test rebuilds the database from a v0.2.7 snapshot mid-suite and breaks every fixture-dependent test after it.

CI (`.github/workflows/test.yml`) runs the Ruby × Rails matrix on SQLite and PostgreSQL, a MySQL job, system tests, the separate-database upgrade smoke test on SQLite and PostgreSQL, RuboCop, Brakeman, ESLint, JS tests, generator tests, a gem build, and a changelog check. One matrix cell sets `COVERAGE=true` so the SimpleCov thresholds are enforced.

## Rules

1. Execute real code. Mock only external services (HTTP, third-party APIs, the clock). Never stub your own models, services, helpers or Rails.
2. Test public methods only. Private methods are covered through them; never assert a private method exists.
3. Fixtures first (`test/fixtures/rails_pulse_*.yml`, declared with `fixtures :table` at the top of the class). Create records only for values fixtures cannot express.
4. No `rescue` in tests. Expected errors use `assert_raises`.
5. Every assertion is specific. No `assert true`, no catch-alls.
6. Group tests with comment headers: `# Structure Tests`, `# Calculation Tests`, `# Edge Cases`.
7. Names follow subject + action + context: `"card calculates average duration for specific job"`.
8. `assert_operator` for comparisons, `assert_includes` for membership, `assert_in_delta` for floats, `assert_kind_of` for types, `assert_predicate` for predicates, `assert_difference` for counts.
9. `assert_not` family, not `refute`. That is what the suite and `rubocop-rails-omakase` use.
10. Edge cases every time: nil, empty, zero, boundaries, 100%, only-current-window, only-previous-window.
11. Time: `travel_to` in `setup`, `travel_back` in `teardown`, relative dates in helpers (`days_ago:`), never wall-clock reads in assertions.
12. Configuration changes are restored in `ensure`, and `RailsPulse::Summary.delete_all` in `setup` when a test depends on summaries being absent.
13. Repetitive setup goes in private helpers with keyword arguments.
14. Show the arithmetic in a comment when an expected value is derived: `# (100*10 + 200*5) / 15 = 133.3ms`.
15. Ordered collections: `each_cons(2)` guarded by `if size > 1`.
16. Positive and negative cases for every validation.
17. Module nesting matches `app/`: `RailsPulse::Jobs::Cards::AverageDurationTest`.
18. Helper tests inherit `ActionView::TestCase`, include the helper module and `RailsPulse::Engine.routes.url_helpers` when links are generated, and run the helper for real.
19. Tests pass under any random seed and in parallel. Shared state is a bug.
20. `ENV["TEST_TYPE"] = "functional"` in `setup` where the test helper switches behaviour on it (`test/rails_pulse_test.rb` and controller tests).

## Layout

| Directory | Holds |
|---|---|
| `test/models`, `test/controllers`, `test/services`, `test/helpers`, `test/lib` | unit and functional tests mirroring `app/` and `lib/` |
| `test/system` | Capybara; run with `BROWSER=true`; includes `csp_compliance_test.rb` |
| `test/migrations` | upgrade regression from `test/support/schemas/` baselines |
| `test/generators` | install, upgrade, convert-to-migrations |
| `test/javascript/controllers/*.test.js` | Vitest; shared `mountController` in `test/javascript/setup.js` |
| `test/support` | helpers: `chart_validation_helpers.rb`, `generator_test_helpers.rb`, `database_helpers.rb`, `schemas/` |
| `test/dummy` | host app; its schema is synced by `rake sync_test_schema` |

## JavaScript tests

One `*.test.js` per controller that has logic testable without a browser. Mount with `mountController`, call `teardown()` in `afterEach`, stub `window.location` as a plain object with `toString()` when a controller reads URL params, coerce `history.replaceState` arguments with `String()` before asserting. `IntersectionObserver` and `ResizeObserver` are no-op mocks in `setup.js`.

Do not write JSDOM tests for rendering in `chart`, or for `flame_graph`, `popover` and `datepicker`; they need canvas, `getBoundingClientRect` or Flatpickr. Those are system tests. `chart` and `index` have JSDOM tests for formatter lookup, config building and listener lifecycle only.
