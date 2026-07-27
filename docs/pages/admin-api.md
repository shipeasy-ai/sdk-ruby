# Admin API client (optional) — `Shipeasy::Admin`

The base SDK *evaluates* flags, configs, and experiments
(`Shipeasy.configure` + `Shipeasy::Client.new(user)`). The **Admin API client** is
a separate, optional surface for *administering* a small, deliberate slice of
those resources from server code.

It is **intentionally lean** — three groups of operations, not the whole admin
API:

| Group                    | What it covers                                                     |
| ------------------------ | ------------------------------------------------------------------ |
| Public ticket queue      | File a bug or feature request, list the queue, read and update one item, and hold its comment thread |
| Kill-switch sub-switches | Add, edit, and delete the named nested switches on a kill switch    |
| Flag whitelists          | Read a gate and manage the whitelist on its targeting stack         |

Everything else in the admin API — experiments, metrics, events, configs, i18n,
projects, connectors, keys — is deliberately **not** here. Reach for the Shipeasy
CLI or MCP for those; they speak the complete spec. Keeping the vendored contract
small is what keeps the generated client small.

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
# file a bug on the public ticket queue, then comment on it
admin.ops.create_ops_item(create_ops_item_request)
admin.comments.create_ops_comment("42", create_ops_comment_request)

# manage a gate's whitelist (it lives on the targeting stack)
admin.flags.update_gate("g_123", update_gate_request)

# add or remove a kill switch's nested sub-switch
admin.killswitch.set_killswitch_switch("k_123", request)
admin.killswitch.unset_killswitch_switch("k_123", switch_key: "eu")
```

Available groups: `flags`, `killswitch`, `ops`, `comments`. The exact method
names, request models, and response shapes come straight from the spec — explore
them under `Shipeasy::Admin::Generated`.

## Regenerating

The generated code lives in `lib/shipeasy_admin.rb` + `lib/shipeasy_admin/` and is committed.
`admin/openapi.json` is **not** the full Shipeasy spec — it is the pruned subset
described above, produced in the monorepo by `scripts/sdk-spec/prune.mjs` from
`scripts/sdk-spec/keep-set.json`. Do not hand-edit it, and do not replace it with
the full `openapi.json`: that is what bloats the generated client back to
megabytes.

From the monorepo, re-vendor and regenerate in one step (only the generated code
is rewritten, never the hand-written shim):

```bash
pnpm sdk:spec:regen sdk-ruby
```

A monorepo pre-commit hook blocks any commit that changes the admin spec while
this vendored copy is stale, so the two cannot silently drift.

The generator version is pinned in `openapitools.json`.
