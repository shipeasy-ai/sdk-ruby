# OpenFeature provider

The Ruby SDK ships an **OpenFeature server provider**,
`Shipeasy::OpenFeature::Provider`, so apps standardised on the CNCF OpenFeature
API can plug Shipeasy in as the backing provider. It is a pure adapter over the
engine you set up with [`Shipeasy.configure`](configuration.md) — evaluation is
unchanged and runs locally against the cached blob. Boolean values map onto gates
(`get_flag_detail`); string / number / integer / float / object map onto dynamic
configs (`get_config`).

## Optional dependency

`openfeature-sdk` (module `OpenFeature::SDK::Provider`, Ruby ≥ 3.4) is an
**optional** dependency, so the provider file is NOT required by the main
entrypoint. Add the gem and require the provider explicitly:

```ruby
# Gemfile
gem "openfeature-sdk"
```

```ruby
require "open_feature/sdk"
require "shipeasy/sdk/openfeature"
```

(If you forget `openfeature-sdk`, requiring the provider raises a clear
`LoadError` telling you to add it.)

## Wiring

Construct the provider with **no argument** — it resolves the engine you
configured with `Shipeasy.configure`, so you never build one yourself:

```ruby
require "open_feature/sdk"
require "shipeasy/sdk/openfeature"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY"); c.poll = true }

OpenFeature::SDK.configure do |config|
  config.set_provider(Shipeasy::OpenFeature::Provider.new)   # uses the configured global
end

of = OpenFeature::SDK.build_client
on = of.fetch_boolean_value(
  flag_key: "new_checkout",
  default_value: false,
  evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: "u1"),
)
```

(`Provider.new` resolves automatically from `Shipeasy.configure` — construct it
after your `configure` call.) The provider also supports the OpenFeature
lifecycle: `init` fetches the blob once and `shutdown` tears the poll thread down.

## Type mapping

| OpenFeature call | Shipeasy backing |
| --- | --- |
| `fetch_boolean_value` | gate (`get_flag_detail`) |
| `fetch_string_value` | dynamic config (must be a String) |
| `fetch_integer_value` | dynamic config (must be an Integer) |
| `fetch_number_value` / `fetch_float_value` | dynamic config (numeric) |
| `fetch_object_value` | dynamic config (Hash or Array) |
| `track` | conversion tracking (no-op without a targeting key) |

## Reason mapping (Shipeasy → OpenFeature)

| Shipeasy `FlagDetail#reason` | OpenFeature reason | error code |
| --- | --- | --- |
| `RULE_MATCH` | `TARGETING_MATCH` | — |
| `DEFAULT` | `DEFAULT` | — |
| `OFF` | `DISABLED` | — |
| `OVERRIDE` | `STATIC` | — |
| `FLAG_NOT_FOUND` | `ERROR` | `FLAG_NOT_FOUND` |
| `CLIENT_NOT_READY` | `ERROR` | `PROVIDER_NOT_READY` |

For configs, an absent key resolves to the OpenFeature `default_value` with
reason `DEFAULT`; a present value that fails the requested type predicate resolves
`ERROR` (`TYPE_MISMATCH`). Exceptions never propagate to OpenFeature — they
surface as reason `ERROR` / `GENERAL`. The `EvaluationContext` `targeting_key`
becomes the Shipeasy `user_id`; every other field is carried through verbatim for
targeting.
