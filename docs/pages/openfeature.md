# OpenFeature

**This SDK ships an OpenFeature provider** (server paradigm):
`Shipeasy::OpenFeature::Provider`. It's a pure adapter over `Shipeasy::Engine` —
no change to evaluation. Boolean values map onto gates (`get_flag_detail`);
string / number / integer / float / object map onto dynamic configs
(`get_config`).

## Optional dependency

`openfeature-sdk` is an **optional** dependency, so the provider file is NOT
required by the main entrypoint. Add the gem and require the provider explicitly:

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

```ruby
client = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
client.init

OpenFeature::SDK.configure do |config|
  config.set_provider(Shipeasy::OpenFeature::Provider.new(client))
end

of = OpenFeature::SDK.build_client

on = of.fetch_boolean_value(
  flag_key: "new_checkout",
  default_value: false,
  evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: "u1"),
)
```

The provider also supports the OpenFeature lifecycle: `init` fetches the blob
once (`init_once`) and `shutdown` tears down the poll thread (`destroy`).

## Type mapping

| OpenFeature call | Shipeasy backing |
| --- | --- |
| `fetch_boolean_value` | gate (`get_flag_detail`) |
| `fetch_string_value` | dynamic config (must be a String) |
| `fetch_integer_value` | dynamic config (must be an Integer) |
| `fetch_number_value` / `fetch_float_value` | dynamic config (numeric) |
| `fetch_object_value` | dynamic config (Hash or Array) |
| `track` | `Shipeasy::Engine#track` (no-op without a targeting key) |

## Reason mapping (doc 20 cross-SDK contract)

| Shipeasy `FlagDetail#reason` | OpenFeature reason / error code |
| --- | --- |
| `RULE_MATCH` | `TARGETING_MATCH` |
| `DEFAULT` | `DEFAULT` |
| `OFF` | `DISABLED` |
| `OVERRIDE` | `STATIC` |
| `FLAG_NOT_FOUND` | `ERROR` (`FLAG_NOT_FOUND`) |
| `CLIENT_NOT_READY` | `ERROR` (`PROVIDER_NOT_READY`) |

For configs, an absent key resolves `DEFAULT`; a present value that fails the
requested type predicate resolves `ERROR` (`TYPE_MISMATCH`). The
`EvaluationContext` `targeting_key` becomes the Shipeasy `user_id`; every other
field is carried through verbatim for targeting.
