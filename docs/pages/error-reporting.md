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

`causes_the` and `extras` are chainable setters callable in any order **before**
`.to`:

```ruby
Shipeasy.see(e)
  .causes_the("checkout")
  .extras({ order_id: oid })
  .to("use cached prices")
```

## Violations (non-exception problems)

A `Violation`'s name is a **stable fingerprint** — put variable data in
`.extras`, never in the name:

```ruby
Shipeasy.see_violation("inventory_negative").extras({ sku: sku }).to("clamp to zero")
```

## Expected control flow (report nothing)

Mark an exception as expected control flow — this reports **nothing**; `.extras`
is local-debug only:

```ruby
Shipeasy.control_flow_exception(e).because("user cancelled").extras({ id: id })
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
