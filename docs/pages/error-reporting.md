# Error reporting — `see()`

**This SDK has `see()`.** It's a structured error-reporting surface: every
handled exception documents its product *consequence*, not just its stack. The
report is a fire-and-forget POST to `/collect`; it never blocks or raises into
the request path.

> If you don't know the consequence of an exception, don't catch it.

## Report a caught exception

`see(problem)` returns a chain. Set the consequence with `causes_the(subject)`
and terminate with `.to(outcome)` — `.to` builds the wire event and fires once:

```ruby
begin
  charge_card(order)
rescue => e
  Shipeasy.engine.see(e).causes_the("checkout").to("use the backup processor")
end
```

`causes_the` and `extras` are chainable setters callable in any order **before**
`.to`:

```ruby
Shipeasy.engine
  .see(e)
  .causes_the("checkout")
  .extras({ order_id: oid })
  .to("use cached prices")
```

## Module-level facade

`Shipeasy::SDK.see` / `see_violation` / `control_flow_exception` dispatch through
the last-constructed default client, so you can report without holding an engine
reference:

```ruby
Shipeasy::SDK.see(e).causes_the("checkout").to("use cached prices")
```

(If no client exists yet the call is a logged no-op — the error is dropped, not
raised.)

## Violations (non-exception problems)

A `Violation`'s name is a **stable fingerprint** — put variable data in
`.extras`, never in the name:

```ruby
Shipeasy.engine.see_violation("inventory_negative").extras({ sku: sku }).to("clamp to zero")
```

## Expected control flow (report nothing)

Mark an exception as expected control flow — this reports **nothing**; `.extras`
is local-debug only:

```ruby
Shipeasy.engine.control_flow_exception(e).because("user cancelled").extras({ id: id })
```

## Guarantees

- Fire-and-forget POST to `/collect`; never raises into caller code.
- Spam-guarded: identical events within 30s collapse to one send, with a hard
  per-process cap (the worker dedupes by fingerprint anyway).
- No-op in test mode (`for_testing` / snapshot engines never send).
- `extras` are sanitized (string/numeric/boolean only, truncated, ≤20 keys) and
  respect the configured private-attribute list.
