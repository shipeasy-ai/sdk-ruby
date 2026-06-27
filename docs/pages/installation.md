# Installation & configuration

This is the canonical home for **install + `Shipeasy.configure`**. Snippets
elsewhere assume `configure` already ran at boot; this page is where it lives.

This is a **server** SDK: it authenticates with your **server key** and must
never be embedded in a browser.

## Add the gem

```ruby
# Gemfile
gem "shipeasy-sdk"
```

```sh
bundle install
```

Or without Bundler:

```sh
gem install shipeasy-sdk
```

The gem is pure Ruby (no native extensions) and runs on Ruby 3.0+. Rails is
**optional** — when Rails is loaded the gem auto-mounts a Railtie that registers
the i18n view helpers and the anon-id Rack middleware. Outside Rails (Sinatra /
Hanami / scripts) it pulls in no web framework.

### Optional: OpenFeature

The OpenFeature provider needs the `openfeature-sdk` gem (Ruby ≥ 3.4). Add it
only if you use `Shipeasy::OpenFeature::Provider` — see [openfeature](openfeature.md).

## Keys

- **Server key** (`SHIPEASY_SERVER_KEY`) — authenticates flag / experiment /
  config evaluation and metric ingestion. Set it as `c.api_key`.
- **Client (public) key** (`SHIPEASY_CLIENT_KEY`) — only needed for the i18n view
  helpers and the SSR i18n loader tag. Set it as `c.public_key`.

The SDK reads no env vars itself — you wire them through `configure`.

## `Shipeasy.configure` — once per process

Call `Shipeasy.configure` **once** at startup, then construct a cheap,
user-bound `Shipeasy::Client.new(user)` per request — every read takes **no user
argument** because the user is bound at construction.

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")   # required — server key, never a browser

  # Optional: map YOUR user object → the Shipeasy attribute hash. Runs once,
  # in the Shipeasy::Client constructor. Omit it and the object you pass to
  # Shipeasy::Client.new IS the attribute hash (identity default).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  # i18n view helpers only (see the i18n page):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")   # public client key
  c.profile    = "default"                          # i18n locale profile
end
```

- **`c.api_key`** *(required)* — your Shipeasy **server key**. Authenticates
  flags, configs, kill switches and experiments. Read it from the environment;
  never hard-code it.
- **`c.attributes`** *(optional)* — a transform from YOUR user object to the
  Shipeasy attribute hash that targeting evaluates against. The default is
  identity, so if your user object is already that hash you can omit it:

  ```ruby
  Shipeasy::Client.new({ "user_id" => "u_1", "plan" => "pro" }).get_flag("new_checkout")
  ```

### One-shot vs background poll

`configure` is first-config-wins: the first call wires everything up; later calls
are a no-op.

- **default (`c.init = true`)** — fire a one-shot fetch fire-and-forget so the
  first `Shipeasy::Client.new(user).get_flag(...)` resolves against real rules.
  Ideal for serverless / short-lived processes — no poll thread is spawned.
- **`c.poll = true`** — for a long-running server, start the **background poll**
  (initial fetch + periodic refresh, 30 s default / `X-Poll-Interval` header) so
  flags stay fresh without a redeploy. Configuration owns the lifecycle:

  ```ruby
  Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY"); c.poll = true }
  ```

### `configure` options

| option | default | what it does |
| --- | --- | --- |
| `api_key` | (required) | Server SDK key. Authenticates evaluation + ingestion. |
| `attributes` | identity | Callable mapping your user object → the Shipeasy attribute hash. |
| `init` | `true` | Fire the one-shot fetch fire-and-forget. |
| `poll` | `false` | Start the background poll (refreshes the blob over time). |
| `base_url` | `https://edge.shipeasy.dev` | API base URL for the blobs. Override for local dev / staging. |
| `env` | `"prod"` | Deployment environment tag, attached to `see()` events + usage telemetry. |
| `disable_telemetry` | `false` | Opt out of per-evaluation usage telemetry. Evaluation itself is unaffected. |
| `telemetry_url` | built-in | Override the telemetry endpoint (rarely needed). |
| `private_attributes` | `nil` | Attribute keys stripped from every outbound event before it leaves the process. They still drive **targeting** locally. See [advanced](advanced.md). |
| `sticky_store` | `nil` | Pin a user's experiment group across re-buckets. See [advanced](advanced.md). |
| `public_key` | (none) | Public client key — for the i18n view helpers / loader tag only. |
| `profile` | `"default"` | i18n locale profile read by the view helpers. |

```ruby
# example: staging env, telemetry off, redact `email`, background poll
Shipeasy.configure do |c|
  c.api_key            = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.env                = "staging"
  c.disable_telemetry  = true
  c.private_attributes = ["email", "ip"]
  c.poll               = true
end
```

**Identity default.** The attribute hash you produce is the unit of identity —
supply `user_id` for logged-in users, or let the anon-id middleware (below)
inject `anonymous_id` for logged-out traffic. An explicit `user_id` /
`anonymous_id` always wins. Constructing `Shipeasy::Client.new(user)` before
`configure` raises `Shipeasy::Error`.

---

## Rails

Bundler requires the gem automatically; you only need an initializer that calls
`Shipeasy.configure`.

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
  c.poll       = true                              # background poll for a persistent server

  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")  # for i18n view helpers
  c.profile    = "default"
end
```

Then in a controller / anywhere per request:

```ruby
flags = Shipeasy::Client.new(current_user)   # runs the attributes transform once
flags.get_flag("new_checkout")               # NO user arg — bound at construction
```

The Railtie mounts the i18n view helpers and `Shipeasy::SDK::RackMiddleware`
(which mints the shared `__se_anon_id` cookie for anonymous bucketing) with no
extra wiring. In a Rails view:

```erb
<%= i18n_head_tags %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```

## Sinatra / Hanami / bare Rack

No Railtie here, so configure in your app file and mount the anon-id middleware
yourself for zero-config anonymous bucketing.

```ruby
require "shipeasy-sdk"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY"); c.poll = true }

class App < Sinatra::Base
  use Shipeasy::SDK::RackMiddleware     # mints __se_anon_id for logged-out traffic

  get "/" do
    flags = Shipeasy::Client.new(current_user || {})
    flags.get_flag("new_checkout") ? "new" : "old"
  end
end
```

The i18n view helpers (`i18n_*`) are not loaded outside Rails, so the gem does
not pull Rails into a Sinatra/Hanami app.

## Plain Ruby / scripts

Same pattern, just without `config/initializers`:

```ruby
require "shipeasy-sdk"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY") }

# With no `attributes` transform, the hash you pass IS the attribute map.
Shipeasy::Client.new({ "user_id" => "u_1" }).get_flag("new_checkout")
```

## Serverless / Lambda / Cloud Run

The default `configure` (one-shot fetch, no poll thread) is already
serverless-friendly: the fetch is fire-and-forget and no background thread is
spawned. Just leave `c.poll` off (its default).

```ruby
Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY") }   # c.poll defaults to false
Shipeasy::Client.new(user).get_flag("new_checkout")
```

## Tests and offline

For unit tests and offline evaluation, swap `configure` for one of its drop-in
siblings — no api key, no network — then read through the same
`Shipeasy::Client.new(user)`:

```ruby
# unit tests: seed values, zero network
Shipeasy.configure_for_testing(flags: { "new_checkout" => true })

# offline: evaluate the real rules from a snapshot / file
Shipeasy.configure_for_offline(path: "shipeasy-snapshot.json")
```

See [testing](testing.md) for the full override args.

Next: [configuration deep-dive](configuration.md) · [flags](flags.md) ·
[experiments](experiments.md) · [i18n](i18n.md).
