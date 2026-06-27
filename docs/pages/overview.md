# Shipeasy Ruby SDK — Overview

`shipeasy-sdk` is the server-side Ruby gem for the [Shipeasy](https://shipeasy.ai)
hosted service: feature gates (flags), dynamic configs, kill switches, A/B
experiments, metric ingestion, and i18n view helpers for Rails. It is
Rails-friendly but works in plain Ruby, Sinatra, Hanami, and serverless too.

## Mental model: configure once, bind a Client per user

There are two parts:

1. **`Shipeasy.configure { |c| ... }`** — runs once at boot. It builds the single
   global **Engine**, registers it, and kicks off a one-shot fetch of the
   flag/experiment blobs (fire-and-forget).
2. **`Shipeasy::Client.new(user)`** — a cheap, user-bound handle you construct per
   user / per request. It delegates every evaluation to the global engine; it
   never opens its own connection, fetches, or polls.

```ruby
# boot (config/initializers/shipeasy.rb)
Shipeasy.configure do |c|
  c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY")
end

# per request
flags = Shipeasy::Client.new(current_user)
flags.get_flag("new_checkout")                       # NO user arg — bound at construction
flags.get_config("button_color")
flags.get_experiment("checkout_cta", { label: "Buy" })
flags.get_killswitch("payments")
```

## Engine vs Client

| | `Shipeasy::Engine` | `Shipeasy::Client` |
| --- | --- | --- |
| Holds the connection, fetch, poll thread, cache | yes | no |
| Getters take a `user` argument | yes (`get_flag(name, user)`) | no (user bound in constructor) |
| `track` / `log_exposure` / `see` live here | yes | — (use `Shipeasy.engine`) |
| Build it | `Shipeasy.configure` registers one as `Shipeasy.engine` | `Shipeasy::Client.new(user)` |

Event ingestion lives on the engine: `Shipeasy.engine.track(user_id, event, props)`.

## Pages

- [installation](installation.md) — gem + runtime
- [configuration](configuration.md) — `Shipeasy.configure`, attributes, env, lifecycle
- [flags](flags.md) — `get_flag` + `get_flag_detail`
- [configs](configs.md) — `get_config`
- [killswitches](killswitches.md) — `get_killswitch`
- [experiments](experiments.md) — `get_experiment` + `track`
- [i18n](i18n.md) — Rails view helpers (this SDK has them)
- [error-reporting](error-reporting.md) — `see()`
- [testing](testing.md) — `for_testing` / `override_*` / `from_file`
- [openfeature](openfeature.md) — `Shipeasy::OpenFeature::Provider`
- [advanced](advanced.md) — manual exposure, private attributes, sticky bucketing, anon-id
