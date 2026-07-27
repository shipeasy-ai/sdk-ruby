# Error reporting — `see()`

**This SDK has `see()`** — a structured error-reporting surface: every handled
exception documents its product *consequence*, not just its stack. The report is
a fire-and-forget POST; it never blocks or raises into the request path. It is
package-level — it reports against the engine you set up with
[`Shipeasy.configure`](configuration.md), so there is no object to construct or
pass around.

> If you don't know the consequence of an exception, don't catch it.

## Report a caught exception

`Shipeasy.see(problem)` returns a chain. Set the consequence with
`causes_the(subject)` and terminate with `.to(outcome)` — `.to` builds the wire
event and fires once:

```ruby
begin
  charge_card(order)
rescue => e
  Shipeasy.see(e).causes_the("checkout").to("use the backup processor")
end
```

### Where extras go in the chain

`causes_the(subject)` and `.to(outcome)` are two halves of one sentence and must
stay adjacent, so fold the extras into the terminal:

```ruby
# PREFERRED — the consequence reads as one sentence:
Shipeasy.see(e).causes_the("checkout").to("use cached prices", { order_id: oid })
```

`.to` fires the report synchronously, so a stray `.extras` chained **after**
`.to` is ignored with a warning — it never raises into your rescue block, but
the extras are **dropped**:

```ruby
# WRONG — extras silently lost:
Shipeasy.see(e).causes_the("checkout").to("use cached prices").extras({ order_id: oid })

# WRONG — extras wedged between the subject and the outcome. You read
# "checkout … order_id … use cached prices" and lose the consequence.
Shipeasy.see(e).causes_the("checkout").extras({ order_id: oid }).to("use cached prices")
```

When the context already exists *above* the rescue, prefer
[`Shipeasy.add_extras`](#attach-context-from-anywhere-shipeasyadd_extras) over
the inline form — it keeps the catch site a clean one-liner.

### Attach context from anywhere: `Shipeasy.add_extras`

To attach context without threading it into the rescue block, buffer it earlier
in the request with `Shipeasy.add_extras`. Every `see()` report that fires later
in the **same request** merges it in:

```ruby
# from any layer, early in the request
Shipeasy.add_extras(order_id: order.id, tenant: tenant.slug)

# ...later, deep in a service...
rescue => e
  Shipeasy.see(e).causes_the("checkout").to("use cached prices")
  # report carries order_id + tenant automatically
end
```

The buffer is **fiber-local**, so concurrent requests never bleed into each
other, and it merges into *every* report in the request (not just the first). A
chained `.extras` / `.to` extra of the same key overrides an ambient one. The
Rack middleware clears the buffer at the end of each request (Rails auto-mounts
it); in a background job or script call `Shipeasy.clear_extras` when a unit of
work ends.

## Violations (non-exception problems)

A `Violation`'s name is a **stable fingerprint** — put variable data in
`.extras`, never in the name:

```ruby
Shipeasy.see_violation("inventory_negative").to("clamp to zero", { sku: sku })
```

## Expected control flow (report nothing)

Mark an exception as expected control flow — this reports **nothing**; `.extras`
is local-debug only:

```ruby
Shipeasy.control_flow_exception(e).because("user cancelled").extras({ id: id })
```

## Cleaned backtraces (Rails)

On Rails, `see()` stacks are filtered to **your application** frames by default —
gem and framework noise is stripped so a report reads like the part of the stack
you can act on. This leverages Rails' own `Rails.backtrace_cleaner`
(`ActiveSupport::BacktraceCleaner`, the same cleaner Rails uses for its own error
pages); the SDK does not invent its own frame-filtering rules. Outside Rails it is
a no-op and the raw backtrace is sent.

If a stack lives entirely in framework/gem code (the cleaner would strip every
frame), the SDK falls back to the raw backtrace so an error is never left with an
empty stack.

Turn it off to always report the full, unfiltered backtrace:

```ruby
Shipeasy.configure do |c|
  c.api_key         = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.clean_backtrace = false
end
```

## Guarantees

- Fire-and-forget; never raises into caller code.
- Spam-guarded: identical events within 30s collapse to one send, with a hard
  per-process cap (the worker dedupes by fingerprint anyway).
- No-op in test/offline mode (`configure_for_testing` / `configure_for_offline`
  never send). A `see()` before any client exists warns and no-ops — it never
  raises.
- `extras` are sanitized (string/numeric/boolean only, truncated, ≤20 keys) and
  respect the configured private-attribute list.
