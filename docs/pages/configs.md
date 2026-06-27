# Dynamic configs

Typed remote-config values. Configs are not user-scoped, but `get_config` is
exposed on the bound Client for one-stop ergonomics.

## Bound Client form

```ruby
flags = Shipeasy::Client.new(current_user)

color = flags.get_config("button_color")          # raw value
```

## Engine form

```ruby
Shipeasy.engine.get_config("button_color")
```

## Optional decode + default

The signature is `get_config(name, decode = nil, default: nil)`:

- `decode` — an optional proc that runs on a **present** value to project it.
- `default` — returned when the config key is **absent**. The decode proc still
  runs on a present value; it does not run on the default.

```ruby
flags.get_config("button_color", default: "blue")

# Decode a nested field, with a fallback when the key is missing:
flags.get_config("limits", ->(v) { v["max"] }, default: 0)
```

The default is returned only when the config key is genuinely absent (or the
client isn't ready) — not for a present value that happens to be falsy.
