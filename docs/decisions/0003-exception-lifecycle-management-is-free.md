# Exception lifecycle management is available to all users

`rails_pulse_exception_groups` includes `status`, `resolved_at`, and `preserve` columns, and the UI actions that change them (resolve, reopen, ignore, preserve toggle) are available to all users.

The rationale: these controls are basic triage. A user who can see their exceptions but cannot act on them — cannot mark something resolved, cannot silence a known-irrelevant error — gets no value from the status lifecycle at all. Restricting triage to a paid tier would make the feature actively frustrating rather than useful.

The schema columns must exist regardless because the capture service reads `status` on every request to implement the auto-reopen transition. This constraint is unchanged.
