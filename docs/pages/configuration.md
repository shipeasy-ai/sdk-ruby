# Configuration

## `Shipeasy.configure { ... }` — the once-per-process call

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }

  # i18n view helpers only (see the i18n page):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.profile    = "default"
end
```

- **`c.api_key`** — your Shipeasy **server key**. Authenticates flags, configs,
  kill switches and experiments. Never embed it in a browser.
- **`c.attributes`** — a transform from YOUR user object to the Shipeasy
  attribute hash that targeting evaluates against. The default is identity, so if
  your user object is already that hash you can omit it:

  ```ruby
  Shipeasy::Client.new({ "user_id" => "u_1", "plan" => "pro" }).get_flag("new_checkout")
  ```

`configure` is first-config-wins: the first call wires everything up; later calls
are a no-op. By default it kicks off a one-shot fetch fire-and-forget, so the
first `Shipeasy::Client.new(user).get_flag(...)` resolves against real rules.

## Identity default

The attribute hash you produce is the **unit of identity** — supply `user_id`
for logged-in users, or let the [anon-id middleware](advanced.md) inject
`anonymous_id` for logged-out traffic. An explicit `user_id` / `anonymous_id`
always wins.

## One-shot vs background poll

- **default (`c.init = true`)** — a one-shot fetch. Ideal for serverless /
  short-lived processes; no poll thread is spawned.
- **`c.poll = true`** — start the **background poll** (initial fetch + periodic
  refresh) for a long-running server, so flags stay fresh without a redeploy.
  Configuration owns the lifecycle; you never touch a lower-level object:

```ruby
Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY"); c.poll = true }
```

## `configure` options

Set any of these in the `configure` block:

| option | default | what it does |
| --- | --- | --- |
| `api_key` | (required) | Server SDK key. Authenticates evaluation + ingestion. |
| `attributes` | identity | YOUR user object → the Shipeasy attribute hash. |
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

## Tests and offline

For unit tests and offline evaluation, use the drop-in siblings of `configure` —
[`configure_for_testing` / `configure_for_offline`](testing.md). They take the
same `attributes` transform (and override args), skip the api key, and let
`Shipeasy::Client.new(user)` read without ever touching the network.

## Environment variables

The SDK reads no env vars itself — you wire them through `configure`. Convention:

- `SHIPEASY_SERVER_KEY` → `c.api_key`
- `SHIPEASY_CLIENT_KEY` → `c.public_key`
