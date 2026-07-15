# Rails Pulse docs

Documentation for people **working on** this gem (maintainers, contributors, coding agents). End-user product docs also live on [railspulse.com](https://railspulse.com).

| Doc | Audience | Contents |
|-----|----------|----------|
| [`../AGENTS.md`](../AGENTS.md) | Everyone / agents | Always-on invariants: migrations, tests, architecture gotchas, assets, releases |
| [`database_setup.md`](database_setup.md) | Contributors shipping schema | Three-path migrations, generators, dummy schema sync |
| [`testing.md`](testing.md) | Contributors | Test conventions, matrix (9 combos), JS Vitest inventory, coverage |
| [`stimulus_echarts_usage.md`](stimulus_echarts_usage.md) | Frontend contributors | Chart helper, data shapes, safe formatter registry |
| [`releasing.md`](releasing.md) | Maintainers cutting releases | `bin/release`, `rake test_release`, publish |
| [`user/deployment-modes.md`](user/deployment-modes.md) | Ops / end users | Embedded vs standalone dashboard |
| [`agents/`](agents/) | Agent skills | Issue tracker, triage labels, domain-doc conventions |

## Suggested reading order (new contributor)

1. `AGENTS.md`
2. `database_setup.md` (if touching schema)
3. `testing.md`
4. `releasing.md` (before a release)

## Agents

Skill wiring for issue tracker, triage labels, and optional `CONTEXT.md` / `docs/adr/` lives under `agents/`. Those domain files are created lazily when needed; absence is fine.
