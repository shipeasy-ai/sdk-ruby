# Advanced

## Exposure logging (auto)

Experiment exposure is **automatic**: `universe(name).assign` logs a single
exposure event the moment a unit is enrolled — reading *is* the exposure, so
there is no separate `log_exposure` call.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

flags.universe("checkout").assign   # enrolled → one exposure POSTed (fire-and-forget)
```

The exposure is **deduped per process** per `(unit, experiment, group)`, so
repeated `assign` calls in one server don't spam `/collect`. It's a no-op when
the unit isn't enrolled and under
[`configure_for_testing` / `configure_for_offline`](testing.md).

## Private attributes

Pass `c.private_attributes` to [`Shipeasy.configure`](configuration.md) to strip
the named keys from every outbound event (`track` props and `see` extras) before
it leaves the process (LD/Statsig `privateAttributes`). The server evaluates
locally, so private attrs **still drive targeting** — they just never reach
`/collect`:

```ruby
Shipeasy.configure do |c|
  c.api_key            = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.private_attributes = ["email", "ssn"]
end
```

Matched keys (string or symbol) are dropped from egress; targeting still uses
them in-process.

## Sticky bucketing

Pass `c.sticky_store` to `configure` to pin a user's experiment assignment across
allocation changes. `Shipeasy::SDK::InMemoryStickyStore` is built in; implement
your own (`get(unit)` / `set(unit, exp, entry)`) for a durable backend (e.g.
Redis):

```ruby
Shipeasy.configure do |c|
  c.api_key      = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.sticky_store = Shipeasy::SDK::InMemoryStickyStore.new
end
```

Absent a store, bucketing is deterministic (MurmurHash3 over the unit).

## Bucketing unit (`bucketBy`)

The bucketing unit per experiment is **server-driven**: an experiment can be
configured to bucket on a non-default attribute (e.g. `company_id`) in the
dashboard, and the SDK reads it from the experiment definition — falling back to
`user_id` then `anonymous_id`. Make sure that attribute is present in the user
map you pass.

## Anonymous-id bucketing (Rack middleware)

For logged-out traffic you need a *stable* unit so a fractional rollout buckets
the same on the server and the browser. In Rails this is automatic: a Railtie
mounts `Shipeasy::SDK::RackMiddleware`, which mints the shared `__se_anon_id`
first-party cookie for any request without one. Evaluations then **default to
it** with no per-call wiring:

```ruby
# current_user is nil → buckets on the __se_anon_id cookie automatically
Shipeasy::Client.new({}).get_flag("new_checkout")
```

An explicit `user_id` / `anonymous_id` always wins. The id is also on the Rack
env as `request.env["shipeasy.anon_id"]`. The cookie is non-`HttpOnly` by design
so the browser SDK buckets identically (cross-SDK contract — see
`18-identity-bucketing.md`).

For **Sinatra / Hanami / bare Rack** (no Railtie), mount it yourself:

```ruby
use Shipeasy::SDK::RackMiddleware
```

## Change listeners

`Shipeasy.on_change` registers a callback fired after a background poll fetches
**new** flag/config data (HTTP 200, not a 304). It requires `configure(poll:
true)`, accepts a block or any callable, and returns an unsubscribe proc.
Listeners never fire in test/offline mode. A raising listener is isolated and
logged, not propagated.

```ruby
unsubscribe = Shipeasy.on_change { reload_local_cache! }
# ... later
unsubscribe.call
```

## Server-side rendering (SSR)

Emit the request's evaluated flags as a declarative `<script>` tag so the browser
SDK has them on first paint. `Shipeasy.bootstrap_script_tag` carries the payload
in `data-*` attributes (**no key**); the `/sdk/runtime.js` browser runtime reads
them, installs `window.shipeasy`, republishes `window.__SE_BOOTSTRAP` for the npm
client SDK and writes the `__se_anon_id` cookie so the browser buckets
identically to the server. Every tag helper is package-level — they
delegate to the engine configured via `configure`, so you never touch it
directly.

```erb
<%# The document <head>, in full. The PUBLIC client key (never the server key)
    goes on the i18n loader tag; the bootstrap tag embeds no key at all. %>
<%= Shipeasy.bootstrap_script_tag(user, anon_id: anon_id) %>
<%= Shipeasy.i18n_script_tag %>
```

### Every argument is optional

All three tag helpers fall back to what `Shipeasy.configure` already set, so the
bare call is the normal one — pass an argument only to override the configured
value for that one tag. Under Rails each returns `html_safe` markup, so `<%= … %>`
renders it without a `.html_safe` at the callsite.

| Helper | Signature | Defaults |
| --- | --- | --- |
| `Shipeasy.i18n_script_tag` | `(client_key = nil, profile:, base_url:)` | `config.public_key`, `config.profile`, `config.cdn_base_url` |
| `Shipeasy.bootstrap_script_tag` | `(user = nil, anon_id:, i18n_profile:, base_url:)` | anonymous request, no anon id, `config.profile`, `config.cdn_base_url` |
| `Shipeasy.devtools_script_tag` | `(project_id = nil, client_key:, base_url:, defer: true)` | `config.project_id`, `config.public_key`, `config.cdn_base_url` |

A tag still renders when a value is missing (the browser bundle reports what it
needs), but the SDK logs a warning naming the `configure` setting to fill in.

In **Rails**, the `i18n_head_tags` view helper renders the inline label blob plus
the loader tag from your app config — see [i18n](i18n.md).

### Devtools overlay tag

`Shipeasy.devtools_script_tag` emits the hosted devtools overlay bundle — nothing
to install, no overlay code in your bundle. It reads the project id and public
client key off the tag, and opens with **Shift+Alt+S** or on any page loaded with
`?se=1`. It is `defer`red by default: a developer tool never belongs on the
critical rendering path.

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.project_id = ENV.fetch("SHIPEASY_PROJECT_ID")   # for the devtools tag
end
```

```erb
<%= Shipeasy.devtools_script_tag %>
```

Adding it unconditionally is fine: the overlay only opens for someone with a
signed-in Shipeasy session, so on a page where nobody has authenticated it
renders nothing and says nothing. Gating it on your own staff or environment
check is **optional** — worth it only if you'd rather the bundle not load for
end users at all:

```erb
<% if current_user&.staff? %><%= Shipeasy.devtools_script_tag %><% end %>
```

### No anon→identified flip

When you pass an **identified** user (any trait beyond `anonymous_id`), the tag
also carries that identity as `data-user` — the user's traits minus
`anonymous_id`, as HTML-escaped JSON. The browser SDK adopts it on first paint,
so a Ruby-backend + JS-frontend app never flips from anonymous to identified
after hydration; both sides bucket on the same identity from the first render. A
purely anonymous request (only `anonymous_id`, or an empty user) emits **no**
`data-user`. See `experiment-platform/18-identity-bucketing.md`.

## Evaluation internals

- **Gates** — modern gates carry an ordered gatekeeper `stack`: entries are
  tried top-to-bottom and the gate passes on the first whose rules match **and**
  whose rollout bucket hits (each entry buckets at its own rollout %, with a
  linear ramp supported over time). A gate with no `stack` falls back to the
  legacy flat path: rules matched in order, then rollout bucket =
  `murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`.
- **Experiments** — `status == "running"`, optional targeting gate, universe
  holdout range, allocation bucket, then group assignment by weight.
- **MurmurHash3** — pure-Ruby x86_32 variant, seed 0.
- **ETag caching** — each poll sends `If-None-Match`; a 304 skips the JSON parse.
- **Poll interval** — defaults to 30 s; overridden by the `X-Poll-Interval`
  header from the flags endpoint.
