# Admin API client (optional) — `Shipeasy::Admin`

The base SDK *evaluates* flags, configs, and experiments
(`Shipeasy.configure` + `Shipeasy::Client.new(user)`). The **Admin API client** is
a separate, optional surface for *administering* those resources from server code
— creating gates, starting experiments, managing configs, kill switches,
universes, metrics, events, and more.

It is **off by default**: the `shipeasy-sdk` entrypoint never loads it, and its
HTTP dependency (`faraday`) is optional. Opt in by adding faraday and requiring
the admin client:

```ruby
# Gemfile
gem "faraday"
```

```ruby
require "shipeasy/admin"
```

The client is **generated from the Shipeasy OpenAPI spec**, so it is a raw, 1:1
projection of the REST API: id-based, basis-points, snake_case. It does *not* add
the name→id resolution or percent→basis-point conveniences of the Shipeasy
CLI/MCP — reach for those tools when you want the ergonomic surface, and for this
client when you want a typed, programmatic mirror of the API.

## Authenticate and scope

Mint an **admin** SDK key (`sdk_admin_…`) and scope every call to a project.

```ruby
require "shipeasy/admin"

admin = Shipeasy::Admin::Client.new(
  api_key: ENV.fetch("SHIPEASY_ADMIN_KEY"),       # Authorization: Bearer <key>
  project_id: ENV.fetch("SHIPEASY_PROJECT_ID"),   # X-Project-Id on every request
  # base_url: "http://localhost:3000",            # defaults to https://shipeasy.ai
)

flags = admin.flags.list_gates
```

`project_id` is sent as the `X-Project-Id` header on every request. Individual
operations also accept an explicit `x_project_id:` argument to override per call.

## Resource groups

Each resource group is a reader returning the matching generated api whose
methods map 1:1 to the OpenAPI operations:

```ruby
admin.flags.create_gate(create_gate_request)
admin.experiments.create_experiment(create_experiment_request)
```

Available groups: `flags`, `configs`, `killswitch`, `experiments`, `universes`,
`attributes`, `metrics`, `events`, `ops`, `alerts`, `projects`, `profiles`,
`keys`, `drafts`, `errors`, `connectors`, `api_keys`. The exact method names,
request models, and response shapes come straight from the spec — explore them
under `Shipeasy::Admin::Generated`.

## Regenerating

The generated code lives in `lib/shipeasy_admin.rb` + `lib/shipeasy_admin/` and is
committed. When the API contract changes, refresh the vendored spec and
regenerate — only the generated tree is rewritten, never the `Client` shim:

```sh
cp <monorepo>/marketplace/openapi/openapi.json admin/openapi.json
bash scripts/gen_admin.sh
```

The generator version is pinned in `openapitools.json`.
