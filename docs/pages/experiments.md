# A/B experiments — `universe(name).assign` + `track`

Experiments are read by **universe**. A universe is a mutual-exclusion pool: a
unit lands in **at most one** experiment in it. `assign` picks that experiment
(if any) and returns the assigned group plus its resolved parameters — it's
side-effect free. The exposure fires on the **first `get` read**, so reading a
param *is* the exposure. You read parameters with `assign.get(field, fallback)`
and record a conversion with `track` — all on the same bound
[`Shipeasy::Client.new(user)`](configuration.md), with no user argument.

## Assigning within a universe

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# Ask the UNIVERSE, not the experiment: the unit lands in <=1 experiment in it.
assignment = flags.universe("checkout").assign

# Read a param: variant override ?? universe default ?? your fallback.
if assignment.get("button_color", "red") == "green"
  render_green_cta
end
```

On the server the user is bound at construction, so `assign` takes no argument.
`assign` itself logs nothing; the single (deduped) exposure fires on the first
`get` read.

## The `Assignment` handle

`universe(name).assign` returns a `Shipeasy::SDK::Eval::Assignment` — never
raises:

- `assignment.name` — the experiment the unit landed in, or `nil` when not
  enrolled.
- `assignment.group` — the assigned variation group (e.g. `"control"` /
  `"treatment"`), or `nil` when not enrolled.
- `assignment.enrolled?` — `true` iff enrolled (`group` is non-nil).
- `assignment.get(field, fallback = nil, exposure: true)` — resolves **variant
  override ?? universe default ?? fallback**. Works even when not enrolled (you
  get the universe default), so reading a param is always safe. The first read
  logs the exposure; pass `exposure: false` to peek at a param *without* logging
  one.

```ruby
assignment = flags.universe("checkout").assign
if assignment.enrolled?
  # assignment.group is the variant, e.g. "treatment"
end
label = assignment.get("primary_label", "Sign up")   # never raises
```

When the unit isn't enrolled (targeting / holdout / allocation), `enrolled?` is
`false`, `name` and `group` are `nil`, and `get(field, fallback)` returns the
universe default if there is one, else your `fallback` (and, not being enrolled,
logs no exposure).

## Tracking conversion events — `track`

Record a conversion/metric event for the experiment's success metric on the same
bound `Client`, deriving the unit from the bound attributes (`user_id` else
`anonymous_id`):

```ruby
flags.track("{{SUCCESS_EVENT}}", { revenue: 49.99 })
```

- `event_name` — your success-metric event, e.g. `{{SUCCESS_EVENT}}`.
- `props` — optional event payload (any [private attributes](advanced.md) you
  configured are stripped before the event leaves the process).

`track` is fire-and-forget and a no-op in test/offline mode. If the bound
attributes carry no `user_id` or `anonymous_id`, the call is a no-op.

## Exposure logging

The exposure fires on the **first `get` read** of an enrolled assignment, not at
`assign` time — reading *is* the exposure. It's a single (deduped) event:
deduped per process and durably per `(unit, experiment, group)` server-side, so
re-reads and repeat runs don't double-count. It's fire-and-forget and a no-op
under [`configure_for_testing` / `configure_for_offline`](testing.md).

Pass `exposure: false` to peek at a param without logging one:

```ruby
# read for a log line / debug view — does NOT enroll the unit's exposure
color = assignment.get("button_color", "red", exposure: false)
```
