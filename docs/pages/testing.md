# Testing

For unit/integration tests build a client that does **zero network** and returns
exactly the values you seed — no api_key, no fetch, no poll thread, no
telemetry, no metric ingestion.

## `for_testing` + `override_*`

```ruby
require "shipeasy-sdk"

client = Shipeasy::Engine.for_testing
# init / init_once are no-ops here — nothing is ever fetched.

# Flags (boolean)
client.override_flag("new_checkout", true)
client.get_flag("new_checkout", { user_id: "u_1" })          # => true

# Configs (any value; an optional decode proc still runs)
client.override_config("button_color", "blue")
client.get_config("button_color")                            # => "blue"
client.override_config("limits", { "max" => 10 })
client.get_config("limits", ->(v) { v["max"] })              # => 10

# Experiments — returns an in-experiment Eval::ExperimentResult
client.override_experiment("checkout_cta", "treatment", { label: "Buy now" })
r = client.get_experiment("checkout_cta", { user_id: "u_1" }, { label: "default" })
r.in_experiment   # => true
r.group           # => "treatment"
r.params          # => { label: "Buy now" }

# track is a no-op (no thread, no network) — assert call counts without stubbing.
client.track("u_1", "checkout_completed", { revenue: 49.99 })  # => nil

# Reset between examples
client.clear_overrides
```

An override always wins over the fetched blob, so the same
`override_flag` / `override_config` / `override_experiment` / `clear_overrides`
setters also pin a value on a **normal** live engine
(`Shipeasy::Engine.new(...)`) for local development.

## Stubbing the global engine / bound Client

`Shipeasy.engine` and the legacy `Shipeasy.flags` both fetch over the network, so
in tests stub them to a `for_testing` engine. `Shipeasy::Client.new(user)` reads
`Shipeasy.engine`, so stubbing the engine covers the bound-client path too:

```ruby
# RSpec
before do
  test_engine = Shipeasy::Engine.for_testing
  test_engine.override_flag("new_checkout", true)
  allow(Shipeasy).to receive(:engine).and_return(test_engine)
  allow(Shipeasy).to receive(:flags).and_return(test_engine) # legacy path

  # Shipeasy::Client.new(user).get_flag("new_checkout") now => true
end
```

## Offline snapshot (real evaluator, no network)

Reproduce a production decision from a captured blob. The snapshot JSON holds the
raw response bodies of the two SDK endpoints:

```json
{ "flags": <body of /sdk/flags>, "experiments": <body of /sdk/experiments> }
```

```ruby
client = Shipeasy::Engine.from_file("snapshot.json")
# or, from already-parsed blobs:
client = Shipeasy::Engine.from_snapshot(flags: flags_body, experiments: exps_body)

client.get_flag("new_checkout", user)          # real evaluation, no network
client.get_experiment("checkout_cta", user, {})
```

`init` / `init_once` / `track` are no-ops and telemetry is off (it reuses the
`for_testing` plumbing). Local `override_*` setters still apply on top of the
snapshot.
