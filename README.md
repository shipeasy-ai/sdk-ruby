# shipeasy-sdk (Ruby)

Ruby gem for the [Shipeasy](https://shipeasy.ai) hosted service. Server-side
gate evaluation, runtime configs, experiments, and metric ingestion.

> Source-available under the [Shipeasy-SAL 1.0](./LICENSE).

## Install

```ruby
# Gemfile
gem "shipeasy-sdk"
```

## Quickstart (Rails)

Two parts: **configure once** at boot, then build a **user-bound
`Shipeasy::Client`** per request via its constructor.

`config/initializers/shipeasy.rb`:

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")

  # Optional: map YOUR user object → the Shipeasy attribute hash. Runs once,
  # in the Shipeasy::Client constructor. Omit it and the object you pass to
  # Shipeasy::Client.new IS the attribute hash (identity).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")  # for i18n view helpers
  c.profile    = "default"
end
```

`configure` builds the single global engine for you and kicks off a one-shot
fetch (fire-and-forget). Anywhere in your app, construct a bound client and call
the getters with **no user argument** — the user is bound at construction:

```ruby
flags = Shipeasy::Client.new(current_user)   # runs the attributes transform once

if flags.get_flag("new_checkout")            # NO user arg
  # ship it
end

color  = flags.get_config("button_color")
result = flags.get_experiment("checkout_cta", { label: "Buy now" })
panic  = flags.get_killswitch("payments")
```

`Shipeasy::Client` is **cheap**: it delegates evaluation to the single engine
built by `configure` — it never opens its own connection, fetches, or polls.
Construct one per user / per request.

Event ingestion (`track`) lives on the engine — `Shipeasy.engine` is the global
one `configure` registered:

```ruby
Shipeasy.engine.track(current_user.id.to_s, "checkout_completed", { revenue: 49.99 })
```

> **Upgrading from 1.x?** The heavyweight client was renamed
> `Shipeasy::SDK::FlagsClient` → `Shipeasy::Engine`, and `Shipeasy::Client` is
> now the lightweight user-bound handle. The legacy `Shipeasy.flags.get_flag(name, user)`
> singleton still works.

In a Rails view (the railtie auto-mounts these helpers when Rails is loaded):

```erb
<%= i18n_head_tags %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```

### Anonymous visitors (zero-config bucketing)

For logged-out traffic you need a *stable* unit so a fractional rollout buckets
the same on the server and in the browser. In Rails this is automatic: a Railtie
mounts `Shipeasy::SDK::RackMiddleware`, which mints the shared `__se_anon_id`
first-party cookie (read + written by every Shipeasy SDK, including the browser)
for any request without one. Evaluations then default to it with **no per-call
wiring** — `get_flag` on an anonymous request just works:

```ruby
# current_user is nil → buckets on the __se_anon_id cookie automatically
Shipeasy::Client.new({}).get_flag("new_checkout")
```

An explicit `user_id` / `anonymous_id` always wins. If you prefer to read the id
yourself it's also on the Rack env as `request.env["shipeasy.anon_id"]`. The
cookie is non-`HttpOnly` by design so the browser SDK can bucket identically. A
request with **no** unit still resolves a fully-rolled (100%) gate as on; only
fractional gates need the id. Cookie name + format are a cross-SDK contract —
see `18-identity-bucketing.md`.

For **Sinatra / Hanami / bare Rack** (no Railtie), mount it yourself:

```ruby
use Shipeasy::SDK::RackMiddleware
```

## Quickstart (plain Ruby / Sinatra / Hanami / scripts)

Same pattern, just without `config/initializers`:

```ruby
require "shipeasy-sdk"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY") }

# With no `attributes` transform, the hash you pass IS the attribute map.
Shipeasy::Client.new({ "user_id" => "u_1" }).get_flag("new_checkout")
```

The Rails view helpers (`i18n_*`) are not loaded outside Rails, so the
gem doesn't pull Rails into Sinatra/Hanami apps.

## Lambda / Cloud Run / serverless

Skip the auto-init facade — it spawns a poll thread you don't want in a
short-lived function. Build the client explicitly and call `init_once`
for a single synchronous fetch:

```ruby
engine = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
engine.init_once
engine.get_flag("new_checkout", user)
```

## Lifecycle escape hatch

If you want explicit shutdown control in a long-running worker, build the
client yourself and skip the singleton:

```ruby
client = Shipeasy::SDK.new_client     # reads api_key + base_url from Shipeasy.config
client.init
at_exit { client.destroy }
```

## Server-side rendering (SSR)

Emit the request's evaluated flags as a declarative `<script>` tag so the
browser SDK has them on first paint. `bootstrap_script_tag` carries the payload
in `data-*` attributes (**no key**); the static `se-bootstrap.js` loader
hydrates `window.__SE_BOOTSTRAP` and writes the `__se_anon_id` cookie so the
browser buckets identically to the server.

```ruby
user = { "user_id" => "u_123" }

# Two tags for the document <head>. The PUBLIC client key (not the server
# key) goes on the i18n loader tag.
head = client.bootstrap_script_tag(user, anon_id: anon_id) +
       client.i18n_script_tag(client_key, profile: "en:prod")

# …or get the raw payload ({ "flags", "configs", "experiments", "killswitches" }):
boot = client.evaluate(user)
```

`bootstrap_script_tag` also accepts `i18n_profile:` and `base_url:` (defaults to
`https://cdn.shipeasy.ai`). In **Rails**, the existing
`Shipeasy::I18n::ViewHelpers#i18n_script_tag` view helper still renders the i18n
loader tag from your app config.

## Default values

`get_flag` and `get_config` take an optional `default:` returned **only when the
value cannot be resolved** — never when a flag genuinely evaluates to `false`.

```ruby
# Flag: default is returned only when the client isn't ready yet (no blob
# fetched) or the gate doesn't exist. A gate that evaluates to false (disabled,
# or outside its rollout) returns false, NOT the default.
Shipeasy.flags.get_flag("new_checkout", user, default: true)

# Config: default is returned when the config key is absent. A decode proc still
# runs on a present value.
Shipeasy.flags.get_config("button_color", default: "blue")
Shipeasy.flags.get_config("limits", ->(v) { v["max"] }, default: 0)
```

## Evaluation detail

`get_flag_detail(name, user)` returns the boolean **and the reason** it was
reached, as a `FlagDetail` struct (`.value`, `.reason`). `get_flag` is built on
top of it. The reason is one of the `REASON_*` constants:

| Reason             | Meaning                                              |
| ------------------ | --------------------------------------------------- |
| `OVERRIDE`         | answered by a local `override_flag` (no telemetry)  |
| `CLIENT_NOT_READY` | no flag blob fetched/loaded yet                     |
| `FLAG_NOT_FOUND`   | blob present, but this gate isn't in it             |
| `OFF`              | gate present but disabled or killswitched           |
| `RULE_MATCH`       | evaluated to `true`                                 |
| `DEFAULT`          | evaluated to `false` (rollout/rule)                 |

```ruby
detail = Shipeasy.flags.get_flag_detail("new_checkout", user)
detail.value   # => true / false
detail.reason  # => "RULE_MATCH" / "DEFAULT" / "OFF" / ...
```

The `gate` usage beacon fires exactly once per `get_flag_detail` call (never on
the `OVERRIDE` short-circuit).

## Change listeners

`on_change` registers a callback fired after a background poll fetches **new**
flag/config data (HTTP 200, not a 304). It accepts a block or any callable and
returns an unsubscribe proc. Listeners never fire in test/offline mode (there is
no poll thread). A raising listener is isolated and logged, not propagated.

```ruby
unsubscribe = Shipeasy.flags.on_change { reload_local_cache! }
# ... later
unsubscribe.call
```

## Offline snapshot

For CI, air-gapped runs, or reproducing a production decision from a captured
blob, build a **no-network** client that still runs the real evaluator against a
snapshot. The snapshot JSON holds the raw response bodies of the two SDK
endpoints:

```json
{ "flags": <body of /sdk/flags>, "experiments": <body of /sdk/experiments> }
```

```ruby
client = Shipeasy::Engine.from_file("snapshot.json")
# or, from already-parsed blobs:
client = Shipeasy::Engine.from_snapshot(flags: flags_body, experiments: exps_body)

client.get_flag("new_checkout", user)        # real evaluation, no network
client.get_experiment("checkout_cta", user, {})
```

`init` / `init_once` / `track` are no-ops and telemetry is off (it reuses the
`for_testing` plumbing). Local `override_*` setters still apply on top of the
snapshot.

## Evaluation details

- **Gates** — rules matched in order; rollout bucket =
  `murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`.
- **Experiments** — `status == "running"`, optional targeting gate,
  universe holdout range, allocation bucket, then group assignment by
  weight.
- **MurmurHash3** — pure-Ruby x86_32 variant, seed 0.
- **ETag caching** — each poll sends `If-None-Match`; a 304 skips the
  JSON parse.
- **Poll interval** — defaults to 30 s; overridden by the
  `X-Poll-Interval` header from the flags endpoint.

## Testing

For unit/integration tests you want a client that does **zero network** and
returns exactly the values you seed — no api_key, no fetch, no poll thread, no
telemetry, no metric ingestion. Build one with `Shipeasy::Engine.for_testing` and
seed each entity with the `override_*` setters (Statsig-style local overrides).
An override always wins over the fetched blob, so the getters answer
deterministically:

```ruby
require "shipeasy-sdk"

client = Shipeasy::Engine.for_testing
# init / init_once are no-ops here — nothing is ever fetched.

# Flags (boolean)
client.override_flag("new_checkout", true)
client.get_flag("new_checkout", { user_id: "u_1" })   # => true

# Configs (any value; an optional decode proc still runs)
client.override_config("button_color", "blue")
client.get_config("button_color")                     # => "blue"
client.override_config("limits", { "max" => 10 })
client.get_config("limits", ->(v) { v["max"] })       # => 10

# Experiments — returns an in-experiment Eval::ExperimentResult
client.override_experiment("checkout_cta", "treatment", { label: "Buy now" })
r = client.get_experiment("checkout_cta", { user_id: "u_1" }, { label: "default" })
r.in_experiment   # => true
r.group           # => "treatment"
r.params          # => { label: "Buy now" }

# track is a no-op (no thread, no network) — assert call counts without stubbing.
client.track("u_1", "checkout_completed", { revenue: 49.99 })  # => nil

# Reset between examples
client.clear_overrides
```

The same `override_flag` / `override_config` / `override_experiment` /
`clear_overrides` setters also work on a **normal** live client (built with
`Shipeasy::Engine.new(...)`), so you can pin one value in local development while the
rest comes from the fetched blob.

### Global engine / bound client

`Shipeasy.engine` (registered by `configure`) and `Shipeasy.flags` (legacy
singleton) both fetch over the network, so in tests stub them to a
`for_testing` engine. `Shipeasy::Client.new(user)` reads `Shipeasy.engine`, so
stubbing the engine also covers the bound-client path:

```ruby
# RSpec
before do
  test_engine = Shipeasy::Engine.for_testing
  test_engine.override_flag("new_checkout", true)
  allow(Shipeasy).to receive(:engine).and_return(test_engine)
  allow(Shipeasy).to receive(:flags).and_return(test_engine) # legacy path

  # Shipeasy::Client.new(user).get_flag("new_checkout") now => true
end
```

## Configuration

| Parameter    | Default                       | Description                                                         |
| ------------ | ----------------------------- | ------------------------------------------------------------------- |
| `api_key`    | (required)                    | SDK key from the Shipeasy dashboard                                 |
| `base_url`   | `https://edge.shipeasy.dev`   | Override for local dev / staging                                    |
| `attributes` | identity (`->(u) { u }`)      | Callable mapping your user object → the Shipeasy attribute hash     |

## Documentation

[docs.shipeasy.ai](https://docs.shipeasy.ai)

## License

[Shipeasy-SAL 1.0](./LICENSE) — source-available, non-commercial-use,
permitted as a Shipeasy client.
