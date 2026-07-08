Assign a unit within a universe (a mutual-exclusion pool — the unit lands in <=1
experiment), read the assigned params, then record the conversion event on the
same bound `Client`. Assumes `Shipeasy.configure` ran at startup — see
Installation.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# universe(name).assign → Shipeasy::SDK::Eval::Assignment
#   name          — the UNIVERSE name (not an experiment); the unit lands in <=1 experiment
#   .name         — the experiment the unit landed in, or nil when not enrolled
#   .group        — the assigned variant, or nil when not enrolled
#   .enrolled?    — true iff enrolled (group is non-nil)
#   .get(field, fallback = nil) — variant override ?? universe default ?? fallback
# assign takes no user arg — the user is bound at construction. It auto-logs a
# single deduped exposure when the unit is enrolled.
assignment = flags.universe("{{EXPERIMENT_KEY}}").assign

render_cta(assignment.get("label", "Buy now"))   # always safe — falls back when not enrolled

# track the conversion on the same bound Client (unit derived from the bound user)
#   track(event_name, props = {})
flags.track("{{SUCCESS_EVENT}}", { revenue: 49.99 })
```
