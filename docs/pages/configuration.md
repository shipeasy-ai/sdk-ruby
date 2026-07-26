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
| `base_url` | `https://api.shipeasy.ai` | API base URL for the blobs. Override for local dev / staging. |
| `env` | `"prod"` | Deployment environment tag, attached to `see()` events + usage telemetry. Also the fallback used to decide "is production" for the egress defaults below when no native env var is set. |
| `is_network_enabled` | environment-derived | Master switch for **all** outbound requests (blob fetch, `track`, exposures, `see()`, telemetry). On in production, off elsewhere. See [Network & telemetry defaults](#network--telemetry-defaults). |
| `disable_telemetry` | environment-derived | Opt out of per-evaluation usage telemetry. Defaults off in production / on outside it. Forced off when the network is disabled. Evaluation itself is unaffected. |
| `disable_internal_error_reporting` | `false` | Opt out of SDK self-monitoring (see below). Evaluation itself is unaffected. |
| `clean_backtrace` | `true` | Filter `see()` error stacks to your **application** frames using Rails' own backtrace cleaner (gem/framework noise stripped). No-op outside Rails. Set `false` to report the raw backtrace. See [error reporting](error-reporting.md). |
| `telemetry_url` | built-in | Override the telemetry endpoint (rarely needed). |
| `private_attributes` | `nil` | Attribute keys stripped from every outbound event before it leaves the process. They still drive **targeting** locally. See [advanced](advanced.md). |
| `sticky_store` | `nil` | Pin a user's experiment group across re-buckets. See [advanced](advanced.md). |
| `log_level` | `:warn` | SDK diagnostic verbosity — one of `:silent`, `:error`, `:warn`, `:info`, `:debug`. See below. |
| `public_key` | (none) | Public client key — for the i18n view helpers and the SSR loader / devtools tags only. |
| `profile` | `"default"` | i18n locale profile read by the view helpers and the SSR tags. |
| `project_id` | (none) | Your project id (`proj_…`) — read by `Shipeasy.devtools_script_tag`. See [advanced](advanced.md). |

## Fail-safe reads & the `log_level` option

The runtime reads and side-effect calls on `Shipeasy::Client` — `get_flag`,
`get_flag_detail`, `get_config`, `universe(name).assign`, `get_killswitch`,
`track` — **never raise into your code**. If anything goes wrong internally (a
bad blob, a `decode` block that throws, a serialization error), the SDK rescues
it, logs a diagnostic, and returns the documented **safe default** instead:

- `get_flag` / `get_config` → the `default:` you passed,
- `universe(name).assign` → a not-enrolled `Assignment` (`name`/`group` `nil`;
  `get` still resolves the universe default or your fallback),
- `get_killswitch` → `false`,
- `track` → `nil`.

So a flag read on the request path can never take down a request. (Setup and
lifecycle calls — `Shipeasy::Client.new` before `configure`,
`configure_for_offline` with no source, a bad snapshot file — still raise
loudly; those are boot-time misconfiguration you want to catch.)

`c.log_level` tunes how loud those recovered-error diagnostics are. Levels, from
quietest to loudest: `:silent`, `:error`, `:warn` (the default), `:info`,
`:debug`. A message at a level is emitted only when the configured level is at
least as verbose (so `:warn` shows `error` + `warn`, and `:silent` mutes every
diagnostic). Set it in the `configure` block:

```ruby
Shipeasy.configure do |c|
  c.api_key   = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.log_level = :silent   # or :error / :info / :debug
end
```

## SDK self-monitoring

When that last-resort guard swallows one of the SDK's **own** internal errors —
a bug on Shipeasy's side, not yours — the SDK also reports it to **Shipeasy's own
project** (a dedicated, baked-in destination), so the SDK team can find and fix
SDK bugs across every app it runs in. This is entirely separate from your
[`see()`](error-reporting.md) reporting: these internal errors **never land in
your project or Errors tab**. The report is fire-and-forget on a background
thread, deduped, and can never slow down or break a read.

It's on by default. Opt out with `c.disable_internal_error_reporting = true`:

```ruby
Shipeasy.configure do |c|
  c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.disable_internal_error_reporting = true
end
```

## Network & telemetry defaults

The SDK is **quiet by default outside production**. Two egress controls default
**on in production and off in every other environment**, so an app that embeds
`shipeasy-sdk` makes **no outbound request from a dev machine or CI** unless it
opts in:

- **`is_network_enabled`** — the master switch for **all** outbound requests:
  flag/config/experiment fetch, `track`, exposure logging, `see()` reports, SDK
  self-monitoring, **and** telemetry. When off, the SDK is fully offline — reads
  resolve from your overrides / the `default:` you pass, and nothing is sent.
- **`disable_telemetry`** — usage telemetry only; on in production, off outside
  it. It is forced off whenever `is_network_enabled` is off.

"Production" is decided with this precedence:

1. A native runtime env var, checked in order: `SHIPEASY_ENV`, `RAILS_ENV`,
   `RACK_ENV`, `APP_ENV`. A value of `production` / `prod` (case-insensitive) ⇒
   production; **any other present value** (`development`, `staging`, `test`, …)
   ⇒ not production.
2. If none of those is set, the SDK's own `env` option (which defaults to
   `"prod"`) decides — so a real production deploy stays on by default.

An **explicitly-passed** value always overrides the environment-derived default:

```ruby
Shipeasy.configure do |c|
  c.api_key            = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.is_network_enabled = true    # force the network on regardless of environment
  # c.is_network_enabled = false # or fully offline even in production
end
```

So a local run stays offline automatically, while production keeps flags,
experiments, `track`, and telemetry live — no per-environment wiring needed. To
run live in a non-production environment (e.g. a staging box), set a production
env var there (`RAILS_ENV=production` / `SHIPEASY_ENV=production`) or pass
`c.is_network_enabled = true`.

## Tests and offline

For unit tests and offline evaluation, use the drop-in siblings of `configure` —
[`configure_for_testing` / `configure_for_offline`](testing.md). They take the
same `attributes` transform (and override args), skip the api key, and let
`Shipeasy::Client.new(user)` read without ever touching the network.

## Environment variables

The SDK reads no env vars itself — you wire them through `configure`. Convention:

- `SHIPEASY_SERVER_KEY` → `c.api_key`
- `SHIPEASY_CLIENT_KEY` → `c.public_key`
- `SHIPEASY_PROJECT_ID` → `c.project_id`
