# Route identity is `[controller_action, path]`, not `[method, path]`

Before 0.4.0 a Route was one `[method, path]` pair, so `GET /users` and `POST /users` were two rows and a resourceful controller spread across several routes with nothing linking them. Path normalisation was also inconsistent: `/posts/42` and `/posts/:id` could both exist depending on when a request was recorded.

From 0.4.0 a Route is one `[controller_action, path]` pair. The HTTP verb moves onto each Request, and a Route accumulates every verb seen for it in `http_methods`. The action is resolved from the host router at collection time, and historical rows are backfilled by `rails rails_pulse:migrate_routes`, which fills `controller_action`, normalises parameterised paths, merges rows that now share an identity, and adds a partial unique index so unrecognised paths (nil action) stay unique by path alone.

The trade-off is a one-time, irreversible data migration and a hard requirement to restart every process together: the old `rails_pulse_routes.method` column is dropped, so a 0.3.x process writing against the new schema fails. We accepted that because the alternative, keeping both identities live, doubled every routes query and left the dashboard unable to answer "how is `posts#show` doing" at all.

Requests whose action cannot be resolved (404s, middleware short-circuits) fall back to grouping by path. Their cardinality is bounded by `max_table_records[:rails_pulse_routes]` and count-based cleanup.
