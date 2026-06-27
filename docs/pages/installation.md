# Installation & configuration

This page is the canonical home for installing the gem and calling
`Shipeasy.configure`. Snippets elsewhere assume `configure` already ran here at
boot.

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

The gem is pure Ruby (no native extensions) and runs on a modern MRI release.
Rails is **optional** — when Rails is loaded the gem auto-mounts a Railtie that
registers the i18n view helpers and the anon-id Rack middleware. Outside Rails
(Sinatra / Hanami / scripts) it pulls in no web framework.

## Keys

- **Server key** (`SHIPEASY_SERVER_KEY`) — authenticates flag / experiment /
  config evaluation and metric ingestion. Set it as `c.api_key`.
- **Client (public) key** (`SHIPEASY_CLIENT_KEY`) — only needed for the i18n view
  helpers and the SSR i18n loader tag. Set it as `c.public_key`.

The SDK reads no env vars itself — you wire them through `configure`.

## `Shipeasy.configure` — once at boot

Configure the gem **once** at startup. `Shipeasy.configure` populates the shared
`Shipeasy::Configuration`, builds + registers the single global `Shipeasy::Engine`
(first-config-wins), and kicks off a one-shot fetch (fire-and-forget). After it
runs you construct a cheap, user-bound `Shipeasy::Client.new(user)` per request —
the bound client never opens its own connection, fetches, or polls.

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")   # required — server key

  # Optional: map YOUR user object → the Shipeasy attribute hash. Runs once,
  # in the Shipeasy::Client constructor. Omit it and the object you pass to
  # Shipeasy::Client.new IS the attribute hash (identity default).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  c.base_url   = "https://edge.shipeasy.dev"        # optional — override for local/staging

  # i18n view helpers only (see below + the i18n page):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")   # public client key
  c.profile    = "default"                          # i18n locale profile
end
```

### configure parameters

| Parameter    | Default                       | Description |
| ------------ | ----------------------------- | ----------- |
| `api_key`    | (required)                    | Server SDK key. Authenticates evaluation + ingestion. |
| `base_url`   | `https://edge.shipeasy.dev`   | Override for local dev / staging. |
| `attributes` | identity (`->(u) { u }`)      | Callable mapping your user object → the Shipeasy attribute hash. Runs once, in the `Shipeasy::Client` constructor. |
| `public_key` | (none)                        | Public client key — for the i18n view helpers / loader tag only. |
| `profile`    | `"default"`                   | i18n locale profile read by the view helpers. |

### The `attributes` transform

The transform runs **once**, in the `Shipeasy::Client` constructor, against the
raw user object you pass. The result is the attribute hash every getter on that
client evaluates against. With no transform, the hash you pass in IS the
attribute map:

```ruby
Shipeasy::Client.new({ "user_id" => "u_1", "plan" => "pro" }).get_flag("new_checkout")
```

### init / poll vs one-shot

`configure` does a one-shot fetch only. For a long-running server you usually
want the background poll thread (30s default, overridden by the
`X-Poll-Interval` response header):

```ruby
Shipeasy.engine.init    # starts the background poll thread
```

For serverless / short-lived functions, skip the poll thread and do a single
synchronous fetch (see **Serverless** below).

---

## Rails

Bundler requires the gem automatically; you only need an initializer that calls
`Shipeasy.configure`.

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")  # for i18n view helpers
  c.profile    = "default"
end

# Start the background poll for a persistent server:
Shipeasy.engine.init
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
yourself if you want zero-config anonymous bucketing.

```ruby
require "shipeasy-sdk"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY") }
Shipeasy.engine.init                    # background poll for a long-running server

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

Skip the auto-init facade — it spawns a poll thread you don't want in a
short-lived function. Build the engine explicitly and do a single synchronous
fetch with `init_once` (no poll thread):

```ruby
engine = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
engine.init_once
engine.get_flag("new_checkout", user)
```

Next: [configuration deep-dive](configuration.md) · [flags](flags.md) ·
[experiments](experiments.md) · [i18n](i18n.md).
