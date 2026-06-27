Track a metric/conversion event from the bound Client. Metrics in the dashboard
are computed from these events. Assumes `Shipeasy.configure` ran at startup —
see Installation.

### Track an event

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# track(event_name, props = {})
#   event_name — the event your metric is built on (required)
#   props      — optional payload; numeric/string fields you can sum/filter on
#                in a metric (private attributes are stripped before egress)
flags.track("{{EVENT_NAME}}", { amount: 49, currency: "usd" })
```

Fire-and-forget (never blocks your response) and a no-op under
`configure_for_testing` / `configure_for_offline`. The unit is the bound user
(`user_id`, else `anonymous_id`); with no unit the call is a no-op.

### Track without properties

```ruby
flags = Shipeasy::Client.new(current_user)

flags.track("{{EVENT_NAME}}")   # props are optional
```
