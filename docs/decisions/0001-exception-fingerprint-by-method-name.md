# Exception fingerprint uses method name, not line number

The fingerprint that determines which ExceptionGroup an occurrence belongs to is computed as `SHA256("ExceptionClass:relative_file#method_name")` using the first app-code frame in the backtrace. Line number is deliberately excluded. The file path is stored relative to `Rails.root` (falling back to the `app/` / `lib/` / `config/` suffix) so Capistrano-style release prefixes do not split groups across deploys.

Line-number fingerprints cause group splits on every nearby code edit — adding a blank line, extracting a variable, reformatting — even when the underlying bug is identical. Method names survive routine refactors and are stable enough to be the grouping key for the lifetime of the codebase. The trade-off is that two different raise sites within the same method hash to the same group, but that is rare and acceptable compared to constant group fragmentation.

**Exception:** when the first app frame is an anonymous context (method name contains `"block"` or starts with `"<"`, e.g. `block in <class:Foo>`, `<main>`), the fingerprint falls back to `relative_file:line`. Anonymous contexts have no stable method name, and grouping all scope/class-body exceptions in a file together would produce false positives.
