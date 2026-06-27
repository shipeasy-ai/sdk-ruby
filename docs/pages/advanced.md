# Advanced

## Manual exposure

The server is stateless and never auto-logs an experiment exposure. Call
`log_exposure` at the moment you actually present the treatment:

```ruby
Shipeasy.engine.log_exposure(current_user.id.to_s, "checkout_cta")
# or pass a full user hash:
Shipeasy.engine.log_exposure({ "user_id" => "u_1", "plan" => "pro" }, "checkout_cta")
```

It re-evaluates the experiment for the user and, **only if enrolled**, POSTs a
single exposure to `/collect` (fire-and-forget). No-op in test mode or when the
user isn't enrolled.

## Private attributes

Pass `private_attributes:` to the Engine to strip named keys from every outbound
payload (`track` props and `see` extras) before they leave the process:

```ruby
engine = Shipeasy::Engine.new(
  api_key: ENV.fetch("SHIPEASY_SERVER_KEY"),
  private_attributes: ["email", "ip"],
)
```

Matched keys (string or symbol) are dropped from `track` properties and `see`
extras. Targeting still uses the attributes in-process; only egress is stripped.

## Sticky bucketing

Pass a `sticky_store:` to the Engine to pin a user's assigned experiment variant
across re-allocations. A built-in in-memory store is provided; supply your own
to persist (e.g. Redis):

```ruby
store  = Shipeasy::SDK::InMemoryStickyStore.new
engine = Shipeasy::Engine.new(
  api_key: ENV.fetch("SHIPEASY_SERVER_KEY"),
  sticky_store: store,
)
```

With no store, assignment is deterministic from the hash. A store implements
`get(unit)` / `set(unit, exp, entry)`.

## Anonymous-id bucketing (Rack middleware)

For logged-out traffic you need a *stable* unit so a fractional rollout buckets
the same on the server and the browser. In Rails this is automatic: a Railtie
mounts `Shipeasy::SDK::RackMiddleware`, which mints the shared `__se_anon_id`
first-party cookie for any request without one. Evaluations then default to it
with no per-call wiring:

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

`on_change` registers a callback fired after a background poll fetches **new**
flag/config data (HTTP 200, not a 304). It accepts a block or any callable and
returns an unsubscribe proc. Listeners never fire in test/offline mode. A raising
listener is isolated and logged, not propagated.

```ruby
unsubscribe = Shipeasy.engine.on_change { reload_local_cache! }
# ... later
unsubscribe.call
```

## SSR bootstrap

Emit the request's evaluated flags as a declarative `<script>` tag so the browser
SDK has them on first paint. `bootstrap_script_tag` carries the payload in
`data-*` attributes (**no key**):

```ruby
user = { "user_id" => "u_123" }

head = Shipeasy.engine.bootstrap_script_tag(user, anon_id: anon_id) +
       Shipeasy.engine.i18n_script_tag(client_key, profile: "en:prod")

# …or get the raw payload ({ "flags", "configs", "experiments", "killswitches" }):
boot = Shipeasy.engine.evaluate(user)
```

`bootstrap_script_tag` also accepts `i18n_profile:` and `base_url:` (defaults to
`https://cdn.shipeasy.ai`).

## Evaluation internals

- **Gates** — rules matched in order; rollout bucket =
  `murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`.
- **Experiments** — `status == "running"`, optional targeting gate, universe
  holdout range, allocation bucket, then group assignment by weight.
- **MurmurHash3** — pure-Ruby x86_32 variant, seed 0.
- **ETag caching** — each poll sends `If-None-Match`; a 304 skips the JSON parse.
- **Poll interval** — defaults to 30 s; overridden by the `X-Poll-Interval`
  header from the flags endpoint.
