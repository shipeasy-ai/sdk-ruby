---
name: shipeasy-ruby
description: Use Shipeasy (feature flags, configs, kill switches, A/B experiments, i18n) from Ruby. Covers configure() + Client(user), get_flag/get_config/get_experiment/get_killswitch, track, testing, OpenFeature.
---

# Shipeasy Ruby SDK

Server-side Ruby gem (`shipeasy-sdk`) for Shipeasy: feature gates, dynamic
configs, kill switches, A/B experiments, metrics, and Rails i18n view helpers.

## Install

```ruby
# Gemfile
gem "shipeasy-sdk"
```

```ruby
require "shipeasy-sdk"
```

## Configure once (boot)

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  # Optional: map your user object → the attribute hash (runs once in Client.new).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
  # i18n only (public client key + profile):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.profile    = "default"
end
```

`configure` builds the single global `Shipeasy::Engine`, registers it as
`Shipeasy.engine`, and does a one-shot fetch. Call `Shipeasy.engine.init` for the
background poll in long-running servers; use `Shipeasy::Engine.new(...).init_once`
in serverless (no thread).

## Evaluate per user (bound Client — NO user arg)

```ruby
flags = Shipeasy::Client.new(current_user)   # runs the attributes transform once

flags.get_flag("new_checkout")               # => true/false; default: only when unresolved
flags.get_config("button_color", default: "blue")
flags.get_killswitch("payments")             # true = killed; optional switch_key
result = flags.get_experiment("checkout_cta", { label: "Buy now" })
# result.in_experiment / result.group / result.params
```

`get_flag_detail` returns `.value` + `.reason` (`RULE_MATCH` / `DEFAULT` / `OFF` /
`FLAG_NOT_FOUND` / `CLIENT_NOT_READY` / `OVERRIDE`).

The low-level Engine getters take the user explicitly:
`Shipeasy.engine.get_flag("new_checkout", user)`.

## Track conversions + manual exposure

```ruby
Shipeasy.engine.track(current_user.id.to_s, "checkout_completed", { revenue: 49.99 })
Shipeasy.engine.log_exposure(current_user.id.to_s, "checkout_cta")  # call when treatment shown
```

## i18n (Rails)

```erb
<%= i18n_head_tags %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```

## Error reporting — see()

```ruby
begin
  charge_card(order)
rescue => e
  Shipeasy.engine.see(e).causes_the("checkout").to("use the backup processor")
end
```

`see_violation(name)` for non-exception problems; `control_flow_exception(e).because(...)`
to mark expected control flow (reports nothing). Module facade:
`Shipeasy::SDK.see(e)...`.

## Testing (zero network)

```ruby
client = Shipeasy::Engine.for_testing
client.override_flag("new_checkout", true)
client.get_flag("new_checkout", { user_id: "u_1" })   # => true
client.override_config("button_color", "blue")
client.override_experiment("checkout_cta", "treatment", { label: "Buy now" })
client.clear_overrides

# Stub the global engine so Shipeasy::Client picks it up:
# allow(Shipeasy).to receive(:engine).and_return(client)
```

Offline snapshot: `Shipeasy::Engine.from_file("snapshot.json")` /
`from_snapshot(flags:, experiments:)` — real evaluator, no network.

## OpenFeature

```ruby
require "open_feature/sdk"          # optional dep: gem "openfeature-sdk"
require "shipeasy/sdk/openfeature"

engine = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
engine.init
OpenFeature::SDK.configure { |c| c.set_provider(Shipeasy::OpenFeature::Provider.new(engine)) }
```

Boolean → gate, string/number/object → dynamic config.

## Advanced

- `private_attributes: ["email"]` — strip keys from `track`/`see` egress.
- `sticky_store: Shipeasy::SDK::InMemoryStickyStore.new` — pin experiment variants.
- Anonymous traffic buckets on the `__se_anon_id` cookie (Rails Railtie auto-mounts
  `Shipeasy::SDK::RackMiddleware`; mount it yourself in Sinatra/Hanami).
