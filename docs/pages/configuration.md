# Configuration

Configure the gem **once** at boot. `Shipeasy.configure` populates the shared
`Shipeasy::Configuration`, builds + registers the single global `Shipeasy::Engine`
(first-config-wins), and kicks off a one-shot fetch (fire-and-forget).

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")

  # Optional: map YOUR user object → the Shipeasy attribute hash. Runs once,
  # in the Shipeasy::Client constructor. Omit it and the object you pass to
  # Shipeasy::Client.new IS the attribute hash (identity default).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  # i18n view helpers only (see the i18n page):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.profile    = "default"
end
```

## Parameters

| Parameter    | Default                       | Description |
| ------------ | ----------------------------- | ----------- |
| `api_key`    | (required)                    | Server SDK key from the dashboard. Authenticates evaluation + ingestion. |
| `base_url`   | `https://edge.shipeasy.dev`   | Override for local dev / staging. |
| `attributes` | identity (`->(u) { u }`)      | Callable mapping your user object → the Shipeasy attribute hash. |
| `public_key` | (none)                        | Public client key — for the i18n view helpers / loader tag only. |
| `profile`    | `"default"`                   | i18n locale profile read by the view helpers. |

## The `attributes` transform

The transform runs **once**, in the `Shipeasy::Client` constructor, against the
raw user object you pass. The result is the attribute hash every getter on that
client evaluates against. With no transform, the hash you pass in IS the
attribute map:

```ruby
Shipeasy::Client.new({ "user_id" => "u_1", "plan" => "pro" }).get_flag("new_checkout")
```

## The Engine return

`Shipeasy.configure` does not return an Engine to bind; it registers the global
one. Read it anywhere with `Shipeasy.engine` (for `track`, `log_exposure`,
`see`, etc.). The legacy `Shipeasy.flags` singleton is a separate polling engine
kept for the `Shipeasy.flags.get_flag(name, user)` style.

## Long-running servers (background poll)

`configure` does a one-shot fetch only. To run the background poll (30s default,
overridden by the `X-Poll-Interval` header), call:

```ruby
Shipeasy.engine.init    # starts the poll thread
```

## Serverless / Lambda / Cloud Run

Skip the auto-init facade — build the engine explicitly and do a single
synchronous fetch with `init_once` (no poll thread):

```ruby
engine = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
engine.init_once
engine.get_flag("new_checkout", user)
```

## Lifecycle escape hatch

```ruby
client = Shipeasy::SDK.new_client   # reads api_key + base_url from Shipeasy.config
client.init
at_exit { client.destroy }
```

## Environment variables

The SDK reads no env vars itself — you wire them through `configure`. Convention:

- `SHIPEASY_SERVER_KEY` → `c.api_key`
- `SHIPEASY_CLIENT_KEY` → `c.public_key`
