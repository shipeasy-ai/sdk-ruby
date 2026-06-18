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

`config/initializers/shipeasy.rb` is all you need:

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")  # for i18n view helpers
  c.profile    = "default"
end
```

Anywhere in your app:

```ruby
user = { user_id: current_user.id, plan: current_user.plan }

if Shipeasy.flags.get_flag("new_checkout", user)
  # ship it
end

color  = Shipeasy.flags.get_config("button_color")
result = Shipeasy.flags.get_experiment("checkout_cta", user, { label: "Buy now" })
Shipeasy.flags.track(current_user.id.to_s, "checkout_completed", { revenue: 49.99 })
```

`Shipeasy.flags` is a lazy, **fork-safe** singleton: the first call from
each process spawns its own `FlagsClient` and starts the background poll
thread, including post-fork Puma workers under `preload_app!`. No need
for `before_worker_boot` hooks or holding a global constant.

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
Shipeasy.flags.get_flag("new_checkout", {})
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

Shipeasy.flags.get_flag("new_checkout", { user_id: "u_1" })
```

The Rails view helpers (`i18n_*`) are not loaded outside Rails, so the
gem doesn't pull Rails into Sinatra/Hanami apps.

## Lambda / Cloud Run / serverless

Skip the auto-init facade — it spawns a poll thread you don't want in a
short-lived function. Build the client explicitly and call `init_once`
for a single synchronous fetch:

```ruby
client = Shipeasy::SDK::FlagsClient.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
client.init_once
client.get_flag("new_checkout", user)
```

## Lifecycle escape hatch

If you want explicit shutdown control in a long-running worker, build the
client yourself and skip the singleton:

```ruby
client = Shipeasy::SDK.new_client     # reads api_key + base_url from Shipeasy.config
client.init
at_exit { client.destroy }
```

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
client = Shipeasy::SDK::FlagsClient.from_file("snapshot.json")
# or, from already-parsed blobs:
client = Shipeasy::SDK::FlagsClient.from_snapshot(flags: flags_body, experiments: exps_body)

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
telemetry, no metric ingestion. Build one with `FlagsClient.for_testing` and
seed each entity with the `override_*` setters (Statsig-style local overrides).
An override always wins over the fetched blob, so the getters answer
deterministically:

```ruby
require "shipeasy-sdk"

client = Shipeasy::SDK::FlagsClient.for_testing
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
`FlagsClient.new(...)`), so you can pin one value in local development while the
rest comes from the fetched blob.

### Rails singleton

`Shipeasy.flags` is a process-wide singleton that fetches over the network, so
in tests prefer a `for_testing` client. If a code path reaches through
`Shipeasy.flags` directly, stub the singleton to the test client in your test
setup:

```ruby
# RSpec
before do
  test_client = Shipeasy::SDK::FlagsClient.for_testing
  test_client.override_flag("new_checkout", true)
  allow(Shipeasy).to receive(:flags).and_return(test_client)
end
```

## Configuration

| Parameter  | Default                   | Description                         |
| ---------- | ------------------------- | ----------------------------------- |
| `api_key`  | (required)                | SDK key from the Shipeasy dashboard |
| `base_url` | `https://cdn.shipeasy.ai` | Override for local dev / staging    |

## Documentation

[docs.shipeasy.ai](https://docs.shipeasy.ai)

## License

[Shipeasy-SAL 1.0](./LICENSE) — source-available, non-commercial-use,
permitted as a Shipeasy client.
