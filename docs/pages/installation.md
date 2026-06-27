# Installation

## Gem

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

## Runtime

- Ruby (MRI) — a modern release; the gem is pure Ruby (no native extensions).
- Rails is **optional**. When Rails is loaded the gem auto-mounts a Railtie that
  registers the i18n view helpers and the anon-id Rack middleware. Outside Rails
  (Sinatra / Hanami / scripts) it pulls in no web framework.

## Require

```ruby
require "shipeasy-sdk"
```

In a Rails app the gem is required automatically by Bundler; you only need an
initializer that calls `Shipeasy.configure`.

## Keys

- **Server key** (`SHIPEASY_SERVER_KEY`) — authenticates flag/experiment/config
  evaluation and metric ingestion. Set it as `c.api_key`.
- **Client (public) key** (`SHIPEASY_CLIENT_KEY`) — only needed for the i18n view
  helpers and the SSR i18n loader tag. Set it as `c.public_key`.

Next: [configuration](configuration.md).
