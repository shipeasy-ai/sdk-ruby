# Shipeasy Ruby SDK — Overview

`shipeasy-sdk` is the server-side Ruby gem for the [Shipeasy](https://shipeasy.ai)
hosted service: feature gates (flags), dynamic configs, kill switches, A/B
experiments, metric tracking, `see()` error reporting, and i18n view helpers for
Rails. It uses your **server key** and must never be embedded in a browser. It is
Rails-friendly but works in plain Ruby, Sinatra, Hanami, and serverless too.

## Mental model: configure once, bind a `Client` per user

There are exactly two things to learn:

1. **`Shipeasy.configure { |c| ... }`** — call it **once** at boot with your
   server key and an optional `attributes` transform (your user object → the
   Shipeasy attribute hash). This is the whole setup story.
2. **`Shipeasy::Client.new(user)`** — construct a cheap, **user-bound** handle per
   request and read with **no user argument** (the user is bound at construction).

```ruby
# boot (config/initializers/shipeasy.rb)
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
end

# per request — construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

flags.get_flag("new_checkout")                       # NO user arg — bound at construction
flags.get_config("button_color")
result = flags.get_experiment("checkout_cta", { label: "Buy" })
flags.log_exposure("checkout_cta")                   # at the decision point
flags.track("purchase", { revenue: 49 })             # on conversion
flags.get_killswitch("payments")
```

## What the bound `Client` does

Everything you need per request is on `Shipeasy::Client.new(user)` — no user
argument on any call:

- `get_flag(name, default: false)` · `get_flag_detail(name)`
- `get_config(name, decode = nil, default: nil)`
- `get_killswitch(name, switch_key = nil)`
- `get_experiment(name, default_params, decode = nil)`
- `log_exposure(experiment_name)` · `track(event_name, props = {})`

So an experiment is **end-to-end Client-only**. Constructing a
`Shipeasy::Client.new(user)` before `Shipeasy.configure` raises `Shipeasy::Error`.

## The configure family

| call | when |
| --- | --- |
| [`Shipeasy.configure { ... }`](configuration.md) | production — your server key |
| [`Shipeasy.configure_for_testing(...)`](testing.md) | unit tests — no network, seed overrides |
| [`Shipeasy.configure_for_offline(...)`](testing.md) | evaluate real rules from a snapshot / file |

After any of them, you read the same way: `Shipeasy::Client.new(user)`.

## Pages

- [installation](installation.md) — gem, frameworks (Rails / Sinatra / serverless), `configure`
- [configuration](configuration.md) — `Shipeasy.configure`, keys, attributes, one-shot vs poll, options
- [flags](flags.md) — `get_flag` + `get_flag_detail`
- [configs](configs.md) — `get_config`
- [killswitches](killswitches.md) — `get_killswitch`, named switches
- [experiments](experiments.md) — `get_experiment`, `log_exposure`, `track`
- [i18n](i18n.md) — Rails view helpers + the SSR loader tag
- [error-reporting](error-reporting.md) — `see()` structured reporting
- [testing](testing.md) — `configure_for_testing`, `configure_for_offline`, overrides
- [openfeature](openfeature.md) — `Shipeasy::OpenFeature::Provider`
- [advanced](advanced.md) — anon-id middleware, private attributes, sticky bucketing, manual exposure, SSR
