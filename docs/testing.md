# Testing

Standards for people working on the Rails Pulse gem. Short always-on rules also live in `AGENTS.md`; this file is the deeper reference.

## Core rules

1. **Execute real application code.** Prefer fixtures and real objects over stubs of your own models, services, helpers, and concerns. Stub external I/O when needed.
2. **Test public APIs only.** Private methods are covered indirectly.
3. **Prefer fixtures** (`fixtures :rails_pulse_…` at the class top). Create records only for one-off edge cases.
4. **No bare `rescue` in tests.** Use `assert_raises` for expected failures.
5. **Use specific assertions:** `assert_operator`, `assert_includes`, `assert_in_delta`, `assert_difference`, `assert_kind_of`, predicate forms where they read better.
6. **Organize with comment headers** (`# Structure Tests`, `# Calculation Tests`, `# Edge Cases`).
7. **Always cover edges:** nil, empty, zero, boundaries, 100% cases when relevant.
8. **Time:** `travel_to` in setup; always `travel_back` in teardown.
9. **Config mutation:** restore originals in an `ensure` block.

## Helper tests

Inherit `ActionView::TestCase`, include the helper (and `RailsPulse::Engine.routes.url_helpers` when generating paths). Do not stub the helper under test.

## Running Ruby tests

```bash
# Default: SQLite3, whatever Rails version the root Gemfile.lock resolves
# (currently Rails 8.1.x — check Gemfile.lock)
DB=sqlite3 rails test

DB=postgresql rails test
DB=mysql2 rails test

# Full matrix: 3 databases × 3 Appraisal Rails lines = 9 combinations
# Paths always include test/system (Chrome headless by default)
rake test_matrix

# Headed Chrome + no parallel workers (easier visual debugging)
BROWSER=true rails test test/system
BROWSER=true rake test_matrix
```

`Appraisals` defines `rails-7-2`, `rails-8-0`, and `rails-8-1`. `rake test_matrix` in the Rakefile uses databases `mysql2`, `postgresql`, `sqlite3` against those three Appraisal names.

PostgreSQL / MySQL need local servers. Common env vars used by the suite:

```bash
POSTGRES_USERNAME POSTGRES_PASSWORD POSTGRES_HOST POSTGRES_PORT
MYSQL_USERNAME MYSQL_PASSWORD MYSQL_HOST MYSQL_PORT
```

(`MYSQL_PASSWORD` is also read by `test_matrix` when invoking Appraisal.)

Parallelization (`test/test_helper.rb`): workers run unless `BROWSER=true` or `COVERAGE=true`.

## JavaScript tests

Vitest + JSDOM. Controllers live under `app/javascript/rails_pulse/controllers/`; tests under `test/javascript/controllers/`.

```bash
npm run test:js          # single run (also used by rake test_release)
npm run test:js:watch
npm run test:js:coverage
```

Mount helpers: `test/javascript/setup.js` (`mountController`). Always `teardown()` in `afterEach`.

### Controllers with unit tests today

| Controller | Test file |
|---|---|
| `chart` | `chart_controller.test.js` (formatters / data paths; ECharts stubbed) |
| `chart_switcher` | `chart_switcher_controller.test.js` |
| `collapsible` | `collapsible_controller.test.js` |
| `color_scheme` | `color_scheme_controller.test.js` |
| `custom_range` | `custom_range_controller.test.js` |
| `dialog` | `dialog_controller.test.js` |
| `form` | `form_controller.test.js` |
| `global_filters` | `global_filters_controller.test.js` |
| `pagination` | `pagination_controller.test.js` |
| `period_selector` | `period_selector_controller.test.js` |
| `series_toggle` | `series_toggle_controller.test.js` |
| `table_sort` | `table_sort_controller.test.js` |
| `time_range` | `time_range_controller.test.js` |

### Controllers without JSDOM tests today

Prefer system tests (or add targeted unit tests only where logic is mockable without canvas / native widgets):

`context_menu`, `datepicker`, `deployment_markers_toggle`, `expandable_rows`, `flame_graph`, `icon`, `index`, `menu`, `popover`, `timezone`

`IntersectionObserver` / `ResizeObserver` are no-op mocked in `test/javascript/setup.js` so imports that reference them do not crash.

When stubbing `window.location`, include `toString()` because controllers use `new URL(window.location)`.

## Coverage

SimpleCov via `.simplecov` when `COVERAGE=true`:

```bash
COVERAGE=true rails test
# or
rake test_coverage
```

Thresholds: **90%** overall, **80%** per file; branch coverage enabled. Open `coverage/index.html` after a run. Migrations, dummy app, config, and test code are excluded per `.simplecov`.

## Schema sync for the dummy app

```bash
rake sync_test_schema   # mirrors db/rails_pulse_schema.rb → test/dummy/…
```

Runs automatically as part of test setup / `test_release`. See `docs/database_setup.md` and `AGENTS.md` for the three-path migration rules.
