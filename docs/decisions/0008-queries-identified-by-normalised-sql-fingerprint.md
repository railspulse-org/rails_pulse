# A Query is identified by the fingerprint of its normalised SQL

_Recorded 2026-09, reconstructing a decision made in the initial design (2025)._

`RailsPulse::Query` has one row per distinct normalised statement. `SqlQueryNormalizer` replaces literal values with placeholders while preserving table and column names, and `hashed_sql` is the MD5 of that normalised text. Every `sql` operation points at the Query with the matching hash, so `SELECT * FROM users WHERE id = 1` and `... id = 2` are the same Query with two executions.

The alternative was grouping by call site (the app file and line that issued the query) or by the ActiveRecord `name` payload (`User Load`). Call site grouping is what N+1 detection wants, but it splits an identical statement issued from two places into two rows and hides that both hit the same index. Payload names are too coarse: every `User Load` collapses together regardless of its `WHERE` clause.

Fingerprint grouping is what makes the query features work: execution counts and average time per statement shape, one EXPLAIN plan per shape, and index suggestions that apply to every caller. N+1 detection is layered on top by looking for the same fingerprint repeating within one request, and the call site is recorded on the Operation (`codebase_location`) rather than used for identity.

The known cost is that normalisation is a heuristic. Statements that differ only in `IN (…)` list length or in whitespace need explicit handling in the normaliser, and a change to the normaliser changes fingerprints and orphans history. Treat the normaliser's output as a stable contract.
