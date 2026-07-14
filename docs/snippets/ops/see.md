Report a caught, handled error (or a non-exception "violation") to Shipeasy with
`see()` — fire-and-forget, never re-raises. Package-level, so it reports against
the engine from `Shipeasy.configure`. Assumes `Shipeasy.configure` ran at
startup — see Installation.

### Report a handled exception

```ruby
begin
  charge(order)
rescue => e
  # .causes_the(subject)   what the error affects (e.g. "checkout")
  # .to(outcome)           the terminal — what you do about it; builds + fires once
  Shipeasy.see(e).causes_the("checkout").to("use the backup processor")
  fallback_charge(order)
end
```

### Attach context with `.extras(...)`

```ruby
begin
  charge(order)
rescue => e
  # .extras(hash)          structured fields attached to the report; call it
  #                        BEFORE .to, or pass extras inline as .to(outcome, hash).
  #                        (A stray .extras AFTER .to is ignored with a warning —
  #                        it never raises into the rescue block.)
  Shipeasy.see(e).causes_the("checkout").extras({ order_id: oid }).to("use cached prices")

  # equivalent — extras folded into the terminal, no ordering to remember:
  Shipeasy.see(e).causes_the("checkout").to("use cached prices", { order_id: oid })
end
```

### Attach context from anywhere with `Shipeasy.add_extras(...)`

```ruby
# Buffer extras earlier in the request — from any layer, not just the rescue.
# Every see() report that fires LATER in the same request carries them, so you
# don't have to thread context down into the catch site. Fiber-local, so
# concurrent requests never mix; the Rack middleware clears it per request
# (Rails auto-mounts it — outside Rack, call Shipeasy.clear_extras yourself).
Shipeasy.add_extras(order_id: order.id, tenant: tenant.slug)

# ...deep in a service, later in the same request...
begin
  charge(order)
rescue => e
  # report carries order_id + tenant automatically; a chained .extras / .to
  # extras of the same key wins over the ambient one.
  Shipeasy.see(e).causes_the("checkout").to("use cached prices")
end
```

### Report a non-exception violation

```ruby
# a bad state that isn't an exception — the name is a STABLE fingerprint; put
# variable data in .extras, never the name. .to() is the terminal.
Shipeasy.see_violation("missing_invoice").causes_the("billing").to("skip the dunning email")
```

### Mark an expected exception — report NOTHING

```ruby
begin
  parse(token)
rescue StopIteration => e
  # transmits nothing; .because(...) / .extras() are local-debug only
  Shipeasy.control_flow_exception(e).because("end of stream is expected")
end
```
