---
name: shipeasy-ruby
description: Use Shipeasy (feature flags, configs, kill switches, A/B experiments, i18n) from Ruby. Covers Shipeasy.configure + Client.new(user), get_flag/get_config/get_experiment/get_killswitch, track, testing, OpenFeature.
---

# Shipeasy Ruby SDK

Server-side Ruby gem (`shipeasy-sdk`) for Shipeasy: feature gates, dynamic
configs, kill switches, A/B experiments, metrics, `see()` error reporting, and
Rails i18n view helpers. Server-key only — never embed in a browser. Ruby 3.0+.

Two things only: **`Shipeasy.configure`** once at boot, then
**`Shipeasy::Client.new(user)`** per request.

> **Pulling deeper docs.** Each section below links its full reference page and
> copy-paste snippets — fetch any of them as raw Markdown when you need more than
> this summary. Discover the whole tree from the manifest:
> `https://shipeasy-ai.github.io/sdk-ruby/manifest.json` (lists every
> `pages/<key>.md` and `snippets/<group>/<leaf>.md`). All URLs below are
> `https://shipeasy-ai.github.io/sdk-ruby/…`.

## Configure once (boot)

```ruby
# config/initializers/shipeasy.rb
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  # Optional: map your user object → the attribute hash (runs once in Client.new).
  c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
  # i18n only (public client key + profile):
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.profile    = "default"
end
```

Omit `c.attributes` if your user object is already the attribute hash. For a
long-running server set `c.poll = true` to keep the blob fresh in the background;
the default (one-shot fetch, no thread) is serverless-friendly.

→ More: `pages/installation.md` (per-framework setup), `pages/configuration.md`
(every option).

## Evaluate (bound `Client.new(user)` — NO user arg)

Bind the user once per request, then call without re-passing it — `track` and
`log_exposure` are on the bound client too, so experiments are end-to-end here:

```ruby
flags = Shipeasy::Client.new(current_user)   # runs the attributes transform once

flags.get_flag("new_checkout")               # bool; default: only when unresolved
flags.get_config("button_color", default: "blue")
flags.get_killswitch("payments")             # true = killed; optional switch_key
result = flags.get_experiment("checkout_cta", { label: "Buy now" })
# result.in_experiment / result.group / result.params

flags.log_exposure("checkout_cta")           # at the decision point
flags.track("purchase", { revenue: 49 })     # conversion / metric event
```

`get_flag_detail` returns a `FlagDetail` (`.value`, `.reason`: `RULE_MATCH`,
`DEFAULT`, `OFF`, `OVERRIDE`, `FLAG_NOT_FOUND`, `CLIENT_NOT_READY`).

→ More: pages `pages/flags.md` · `pages/configs.md` · `pages/killswitches.md`
(incl. named switches) · `pages/experiments.md`. Snippets
`snippets/release/{flags,configs,killswitches,experiments}.md` and
`snippets/metrics/track.md`.

## Testing (no network)

Use the `configure` siblings — seed overrides, read through the same `Client`:

```ruby
Shipeasy.configure_for_testing(
  flags:       { "new_checkout" => true },
  configs:     { "billing_copy" => { "title" => "Welcome" } },
  experiments: { "checkout_button" => ["treatment", { "color" => "green" }] },
)
Shipeasy::Client.new({ "user_id" => "u_123" }).get_flag("new_checkout") # => true

# flip a value on the spot, mid-test:
Shipeasy.override_flag("new_checkout", false)
Shipeasy.clear_overrides
```

Offline (real rules from a snapshot / file):

```ruby
Shipeasy.configure_for_offline(path: "snapshot.json")
# or snapshot: { "flags" => {...}, "experiments" => {...} }, plus optional overrides
```

→ More: `pages/testing.md` (override helpers + a working example
`shipeasy-snapshot.json`).

## OpenFeature

```ruby
require "open_feature/sdk"          # optional dep: gem "openfeature-sdk" (Ruby ≥ 3.4)
require "shipeasy/sdk/openfeature"

Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY"); c.poll = true }
OpenFeature::SDK.configure { |c| c.set_provider(Shipeasy::OpenFeature::Provider.new) } # uses the global
```

Boolean → gate; string/number/object → config.

→ More: `pages/openfeature.md` (reason mapping, type routing).

## Error reporting — see()

```ruby
begin
  charge_card(order)
rescue => e
  Shipeasy.see(e).causes_the("checkout").to("use the backup processor")
end
```

`Shipeasy.see_violation(name)` for non-exception problems;
`Shipeasy.control_flow_exception(e).because(...)` marks expected control flow
(reports nothing).

→ More: `pages/error-reporting.md` · snippets `snippets/ops/see.md`
(`.extras`, violations, control-flow exceptions).

## i18n (Rails)

```erb
<%= i18n_head_tags %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```

Outside Rails: `Shipeasy.i18n_script_tag(client_key, profile: "en:prod")` emits
the loader tag (public client key).

→ More: `pages/i18n.md` · snippets `snippets/i18n/{setup,render}.md`.

## Other surfaces

- Anon bucketing: `Shipeasy::SDK::RackMiddleware` mints the shared `__se_anon_id`
  cookie (Rails Railtie auto-mounts it); anonymous `get_flag` then just works.
- `c.private_attributes = ["email"]` strips keys from outbound events.
- `c.sticky_store = Shipeasy::SDK::InMemoryStickyStore.new` pins experiment assignment.
- SSR: `Shipeasy.bootstrap_script_tag(user)` + `Shipeasy.i18n_script_tag(client_key, "en:prod")`.
- `Shipeasy.on_change { ... }` (requires `c.poll = true`) fires after a poll fetches new data.

→ More: `pages/advanced.md`.
