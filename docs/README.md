# docs/

What you cannot work out from the code: how the pieces fit, why the important choices were made, and the working rules. Written for whoever is changing the gem, which is mostly the maintainer and AI agents, so it is short, factual and checkable against the code. Nothing here describes user-facing behaviour; that lives on railspulse.com and in the README, and a change to behaviour is not done until those are updated too.

`CLAUDE.md` at the root is the entry point and carries the rules in short form. `CONTEXT.md` is the glossary.

| File | Read it before |
|---|---|
| `architecture.md` | touching collection, the tracker, summaries, cleanup, the schema check, the standalone server, or assets |
| `migrations.md` | any schema change |
| `testing.md` | writing or changing a test |
| `charts.md` | adding a chart, a formatter, or an ECharts feature |
| `releasing.md` | cutting a release |
| `decisions/` | proposing a change to something one of them covers; each is what we do, what we rejected, and the cost |
| `agents/` | agent workflow: domain vocabulary, the issue tracker, triage labels |

A decision file is rewritten when the decision changes; git keeps the history. Nothing in this folder is a snapshot of a past state.
