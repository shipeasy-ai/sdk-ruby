# Testing

Use **`Shipeasy.configure_for_testing`** — the test-mode sibling of
[`Shipeasy.configure`](configuration.md). It does **zero network**, needs no api
key, and seeds the values your code under test should see via override arguments.
Then read through the ordinary `Shipeasy::Client.new(user)` — the *same* call
your production code uses.

```ruby
require "shipeasy-sdk"

Shipeasy.configure_for_testing(
  flags:       { "new_checkout" => true },
  configs:     { "billing_copy" => { "title" => "Welcome" } },
  experiments: { "checkout_button" => ["treatment", { "color" => "green" }] },
)

# construct once per callsite (cheap; binds the user)
client = Shipeasy::Client.new({ "user_id" => "u_123" })

client.get_flag("new_checkout")              # => true
client.get_config("billing_copy")            # => { "title" => "Welcome" }

result = client.get_experiment("checkout_button", { "color" => "blue" })
result.in_experiment                         # => true
result.group                                 # => "treatment"
result.params                                # => { "color" => "green" }

# track / log_exposure are no-ops in test mode — safe to call, send nothing
client.track("purchase", { amount: 49 })
```

Override argument shapes:

- `flags` — `{ name => bool }` forced `get_flag` results.
- `configs` — `{ name => value }` forced `get_config` results (a `decode` still applies).
- `experiments` — `{ name => [group, params] }` forced enrolments.

`configure_for_testing` **replaces** any previously-configured engine, so each
test can reconfigure freely (no reset boilerplate, unlike `configure`'s
first-config-wins).

## Quick overrides on the spot

Seeding up front isn't always enough — sometimes you want to flip one value
*mid-test*. The package-level override helpers do exactly that, layered on top of
whatever `configure_for_testing` / `configure_for_offline` (or even a live
`configure`) set up. They win until `clear_overrides`:

```ruby
Shipeasy.configure_for_testing(flags: { "new_checkout" => true })

# …later, in one test, flip values without reconfiguring:
Shipeasy.override_flag("new_checkout", false)               # name, value
Shipeasy.override_config("billing_copy", { "title" => "B" }) # name, value
Shipeasy.override_experiment("checkout_button", "control", { "color" => "blue" })

Shipeasy::Client.new({ "user_id" => "u_1" }).get_flag("new_checkout")  # => false

Shipeasy.clear_overrides   # drop every on-the-spot override
```

| helper | effect |
| --- | --- |
| `Shipeasy.override_flag(name, value)` | force `get_flag(name)` → `value` |
| `Shipeasy.override_config(name, value)` | force `get_config(name)` → `value` |
| `Shipeasy.override_experiment(name, group, params)` | force enrolment in `group` with `params` |
| `Shipeasy.clear_overrides` | drop all of the above |

(These require a prior `configure*` call — they raise `Shipeasy::Error` otherwise.)

`clear_overrides` drops **every** override — including the values you passed to
`configure_for_testing` (which seeds through the same mechanism, and test mode has
no blob underneath). Under `configure_for_offline` it instead reverts to the
snapshot. To get a clean known state, call `configure_for_testing(...)` again.

## Offline snapshot

Use **`Shipeasy.configure_for_offline`** to run fully offline against a real blob
— evaluations run the **real** eval logic (targeting, rollout, bucketing), no
network is touched, and the override args still apply on top:

```ruby
Shipeasy.configure_for_offline(path: "shipeasy-snapshot.json")

client = Shipeasy::Client.new({ "user_id" => "u_123" })
client.get_flag("new_checkout")
```

### A snapshot file that works

A snapshot is
`{ "flags": <body of /sdk/flags>, "experiments": <body of /sdk/experiments> }`.
The shapes are name-keyed maps. Save this as `shipeasy-snapshot.json` — it
evaluates exactly as written:

```json
{
  "flags": {
    "gates": {
      "new_checkout": { "enabled": true, "rolloutPct": 10000, "salt": "new_checkout", "rules": [] },
      "beta_banner":  { "enabled": false, "rolloutPct": 0, "salt": "beta_banner", "rules": [] }
    },
    "configs": {
      "billing_copy": { "value": { "title": "Welcome back", "cta": "Upgrade" } },
      "upload_limits": { "value": { "max_mb": 50 } }
    },
    "killswitches": {
      "payments_circuit_breaker": { "killed": false }
    }
  },
  "experiments": { "experiments": {}, "universes": {} }
}
```

- A gate is `{ "enabled", "rolloutPct" (0–10000, basis points), "salt", "rules": [] }`.
  `rolloutPct: 10000` = 100% on; `0` = off for everyone. Add targeting under `rules`.
- A config is `{ "value": <any JSON> }`; `get_config("billing_copy")` returns that `value`.
- A kill switch is `{ "killed": <bool>, "switches"?: { ... } }`.
- Leave `experiments` as `{ "experiments": {}, "universes": {} }` if you have none
  (or paste a real `/sdk/experiments` body).

```ruby
Shipeasy.configure_for_offline(path: "shipeasy-snapshot.json")
c = Shipeasy::Client.new({ "user_id" => "u_1" })
c.get_flag("new_checkout")                              # => true  (100% rollout)
c.get_flag("beta_banner")                              # => false (0% rollout)
c.get_config("billing_copy")["cta"]                    # => "Upgrade"
c.get_config("upload_limits", ->(v) { v["max_mb"] })   # => 50
c.get_killswitch("payments_circuit_breaker")           # => false
```

You can also pass the same structure inline as `snapshot:` instead of a file,
and layer overrides on top:

```ruby
Shipeasy.configure_for_offline(
  snapshot: { "flags" => { "gates" => {}, "configs" => {} }, "experiments" => {} },
  flags:    { "new_checkout" => true },   # same override args as configure_for_testing
)
```

> **Tip:** to capture a real production snapshot, save the bodies of the
> `GET /sdk/flags` and `GET /sdk/experiments` responses under those two keys.

Both helpers take the same `attributes:` transform as `configure`, so your
user-object mapping is exercised in tests exactly as in production.
