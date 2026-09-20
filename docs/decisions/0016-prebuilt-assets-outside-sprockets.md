# Dashboard assets are pre-built, committed, and served outside the host's asset pipeline

`npm run build` produces the JavaScript and CSS bundle into `public/rails-pulse-assets/`, and that output is committed and shipped in the gem. The gem does not add them to `config.assets.precompile`. After the host's `assets:precompile`, `rails_pulse:install_assets` copies them into `public/assets` with a SHA256 digest so `config.asset_host` and CDN-only CSP setups work. Development and hosts with no pipeline are served by `RailsPulse::Middleware::AssetServer` at `/rails-pulse-assets/<gem-version>/…`. Layouts use `tag.link` and `tag.script`, not `stylesheet_link_tag`, so the middleware paths are never rewritten onto the CDN.

Registering the sources with Sprockets or Propshaft was the original approach and was removed. The host's compressor re-minified the bundle on every precompile, which ran out of memory on small hosts, and the result depended on which pipeline and which Node the host had.

The costs: a binary-ish bundle in git that must be rebuilt by hand and verified before a release, an extra rake hook on `assets:precompile`, and a middleware in the host stack. The gem version in the asset path is what busts CDN caches, so any change to the bundle needs a version bump to reach users behind a CDN.
