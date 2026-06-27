# Kill switches

A kill switch is an operational on/off (and per-key switches) read from the same
cached flags blob as gates. It is **not** user-scoped.

## Bound Client form

```ruby
flags = Shipeasy::Client.new(current_user)

if flags.get_killswitch("payments")
  # the whole "payments" killswitch is KILLED → take the safe path
end
```

## Engine form

```ruby
Shipeasy.engine.get_killswitch("payments")
```

## Semantics

`get_killswitch(name, switch_key = nil)`:

- **Without `switch_key`** — returns `true` when the whole kill switch is killed.
- **With `switch_key`** — returns `true` when that specific per-key switch is on.
- Unknown kill switches / switches return `false`.

```ruby
# Whole switch:
flags.get_killswitch("payments")

# A single named per-key switch:
flags.get_killswitch("payments", "stripe")
```

Kill switches are folded into per-gate evaluation too, so a killed gate reports
reason `OFF` from `get_flag_detail`.
