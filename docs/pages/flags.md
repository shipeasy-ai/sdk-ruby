# Feature flags — `get_flag`

A flag (gate) evaluates to a boolean for a given user. After
[`Shipeasy.configure`](configuration.md) has run once at boot, bind a user with
`Shipeasy::Client.new(user)` and read with **no user argument**.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

if flags.get_flag("new_checkout")
  # ship it
end
```

## Default / fallback behaviour

`get_flag(name, default: false)` returns `default` **only when the value cannot
be evaluated** — never when the gate simply resolves off:

```ruby
# default is returned only if Shipeasy isn't ready yet OR the gate isn't in the
# blob. A gate that evaluates to false (disabled, killed, or outside its rollout)
# returns false, NOT the default.
flags.get_flag("new_checkout", default: true)
```

## Evaluation detail — `get_flag_detail`

`get_flag_detail` returns a `FlagDetail` struct (`.value`, `.reason`) so you can
log *why* a flag resolved the way it did. `get_flag` is built on top of it.

```ruby
detail = flags.get_flag_detail("new_checkout")
detail.value    # => true / false
detail.reason   # => "RULE_MATCH" / "DEFAULT" / "OFF" / ...
```

| reason | meaning |
| --- | --- |
| `OVERRIDE` | a [`configure_for_testing`](testing.md) / `override_flag` override forced the value |
| `CLIENT_NOT_READY` | the first fetch hasn't completed yet → `value` false |
| `FLAG_NOT_FOUND` | no gate by that name in the blob → `value` false |
| `OFF` | the gate exists but is disabled or killswitched → `value` false |
| `RULE_MATCH` | evaluated **on** (targeting + rollout) |
| `DEFAULT` | evaluated **off** (fell through) |

`get_flag` delegates to `get_flag_detail` and returns `.value`, substituting
`default` for the `CLIENT_NOT_READY` / `FLAG_NOT_FOUND` cases. The `gate` usage
beacon fires exactly once per `get_flag_detail` call (never on the `OVERRIDE`
short-circuit).

## Change listeners

When you run a long-lived server with `configure(poll: true)`, register a
callback fired after a background poll fetches **new** data (a 200, not a 304).
It accepts a block or any callable and returns an unsubscribe proc:

```ruby
unsubscribe = Shipeasy.on_change { reload_local_cache! }
# ... later
unsubscribe.call
```

## Rollout bucketing

A fractional rollout buckets on the unit id:
`murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`. For logged-out traffic the
shared `__se_anon_id` cookie supplies a stable unit — see [advanced](advanced.md).
A request with no unit still resolves a fully-rolled (100%) gate as on; only
fractional gates need an id.
