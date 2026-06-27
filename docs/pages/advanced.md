# Advanced

## Manual exposure — `log_exposure`

The server is stateless and never auto-logs an experiment exposure. Call
`log_exposure` at the moment you actually present the treatment, on the bound
`Client` (no user argument):

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

flags.log_exposure("checkout_cta")
```

It re-evaluates the experiment and, **only if enrolled**, POSTs a single exposure
(fire-and-forget). No-op in test mode or when the user isn't enrolled.

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
in `data-*` attributes (**no key**); the static `se-bootstrap.js` loader hydrates
`window.__SE_BOOTSTRAP` and writes the `__se_anon_id` cookie so the browser
buckets identically to the server. Both helpers are package-level — they delegate
to the engine configured via `configure`, so you never touch it directly.

```ruby
user = { "user_id" => "u_123" }

# Two tags for the document <head>. The PUBLIC client key (not the server key)
# goes on the i18n loader tag.
head = Shipeasy.bootstrap_script_tag(user, anon_id: anon_id) +
       Shipeasy.i18n_script_tag(client_key, profile: "en:prod")
```

`bootstrap_script_tag` also accepts `i18n_profile:` and `base_url:` (defaults to
`https://cdn.shipeasy.ai`). In **Rails**, the `i18n_head_tags` view helper renders
the i18n loader tag from your app config — see [i18n](i18n.md).

## Evaluation internals

- **Gates** — rules matched in order; rollout bucket =
  `murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`.
- **Experiments** — `status == "running"`, optional targeting gate, universe
  holdout range, allocation bucket, then group assignment by weight.
- **MurmurHash3** — pure-Ruby x86_32 variant, seed 0.
- **ETag caching** — each poll sends `If-None-Match`; a 304 skips the JSON parse.
- **Poll interval** — defaults to 30 s; overridden by the `X-Poll-Interval`
  header from the flags endpoint.
