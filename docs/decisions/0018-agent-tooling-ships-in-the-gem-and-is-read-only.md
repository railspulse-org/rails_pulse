# The JSON API, CLI and MCP server ship in the gem and are read-only

_Recorded 2026-09, for the 0.5 release._

`rails_pulse` ships a token-authenticated JSON API (`app/controllers/rails_pulse/api/v1/`), the `rails-pulse` CLI (`lib/rails_pulse/cli/`) and an MCP server (`lib/rails_pulse/mcp/`) that talks to that API. All three are read-only. The API answers over the same engine mount as the dashboard but never consults the dashboard session: it accepts only `config.api_token`, and with no token configured it refuses every request.

The MCP server and CLI run on the developer's machine, not inside the application, and reach it only over HTTP. That is why every MCP tool and every CLI command lives in this gem even though some read data only an extension engine produces: there is one client to install and no version skew between the client and the server. For those endpoints the gem draws stub routes (`ExtensionController`) that answer 402 with the feature name; an installed extension appends the real routes and the stubs are skipped. The client turns a 402 into a message for the user rather than an error, so an agent mid-investigation learns what is missing and carries on with the tools that work.

The alternative was to ship the client alongside each extension that adds endpoints. It was rejected because the tooling is distribution, not product: every APM will have an MCP server, and the diagnosis workflow an agent runs (deploy, slow requests, endpoint, queries, jobs) should work for every install without anything extra.

Read-only is a promise, not an implementation detail. `MCP::Tool` annotations declare `read_only_hint`, the controllers expose only index and show actions, and nothing under the API namespace may write. A feature that needs an agent to change the application belongs in a workflow the customer runs (a PR from their own agent runner), never in these endpoints. The other constraint this inherits is decision 0006: the API serves the host's own database and sends nothing anywhere else.
