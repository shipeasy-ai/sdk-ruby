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
  # .extras(hash)          structured fields attached to the report
  Shipeasy.see(e).causes_the("checkout").extras({ order_id: oid }).to("use cached prices")
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
