# Feature flags (gates)

Boolean feature gates with targeting + rollout, evaluated locally against the
cached blob.

## Bound Client form (preferred)

The user is bound at construction, so `get_flag` takes **no user argument**:

```ruby
flags = Shipeasy::Client.new(current_user)

if flags.get_flag("new_checkout")
  # ship it
end
```

## Low-level Engine form

The engine getter takes the user explicitly:

```ruby
Shipeasy.engine.get_flag("new_checkout", { "user_id" => "u_1", "plan" => "pro" })
```

## Default / fallback behaviour

`get_flag` accepts an optional `default:` returned **only when the value cannot
be resolved** — never when a gate genuinely evaluates to `false`:

```ruby
flags.get_flag("new_checkout", default: true)            # bound Client
Shipeasy.engine.get_flag("new_checkout", user, default: true)
```

The default is returned only when the client isn't ready yet (no blob fetched)
or the gate doesn't exist. A gate that is disabled, killed, or outside its
rollout returns `false`, **not** the default.

## Evaluation detail + reason

`get_flag_detail` returns a `FlagDetail` struct with `.value` and `.reason`.
`get_flag` is built on top of it.

```ruby
detail = flags.get_flag_detail("new_checkout")           # bound Client
detail.value    # => true / false
detail.reason   # => "RULE_MATCH" / "DEFAULT" / "OFF" / ...

# Engine form:
Shipeasy.engine.get_flag_detail("new_checkout", user)
```

| Reason             | Meaning |
| ------------------ | ------- |
| `OVERRIDE`         | answered by a local `override_flag` (no telemetry) |
| `CLIENT_NOT_READY` | no flag blob fetched/loaded yet |
| `FLAG_NOT_FOUND`   | blob present, but this gate isn't in it |
| `OFF`              | gate present but disabled or killswitched |
| `RULE_MATCH`       | evaluated to `true` |
| `DEFAULT`          | evaluated to `false` (rollout/rule) |

The `gate` usage beacon fires exactly once per `get_flag_detail` call (never on
the `OVERRIDE` short-circuit).

## Rollout bucketing

A fractional rollout buckets on the unit id:
`murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`. For logged-out traffic the
shared `__se_anon_id` cookie supplies a stable unit — see [advanced](advanced.md).
A request with no unit still resolves a fully-rolled (100%) gate as on; only
fractional gates need an id.
