# A/B experiments — `get_experiment` + `track`

After [`Shipeasy.configure`](configuration.md), an experiment is **end-to-end
through the bound `Shipeasy::Client.new(user)`** — read the assignment, log
exposure, and track the conversion, all on the same handle, with no user
argument.

## Reading an experiment

`get_experiment(name, default_params, decode = nil)` returns an
`Eval::ExperimentResult` with three fields:

- `result.in_experiment` — `true` if the user is enrolled (not in the holdout /
  outside allocation).
- `result.group` — the assigned variation group (e.g. `"control"` /
  `"treatment"`).
- `result.params` — the variant params; falls back to `default_params` when the
  user isn't enrolled (or the experiment is absent).

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

result = flags.get_experiment("checkout_cta", { label: "Buy now" })

if result.in_experiment && result.group == "treatment"
  render_cta(result.params[:label])
end
```

An optional `decode` proc projects the params for an enrolled user (a decode
failure falls back to `control` + `default_params`).

## Logging exposure — `log_exposure`

The server is stateless and never auto-logs exposure. Call `log_exposure` at the
point you actually present the treatment (parity with the browser's
auto-exposure). The bound `Client` derives the user from the same bound
attributes — no user argument:

```ruby
result = flags.get_experiment("checkout_cta", { label: "Buy now" })
flags.log_exposure("checkout_cta")   # at the decision point
```

It re-evaluates and, if the bound user is enrolled, POSTs a single `exposure`
event; otherwise it's a no-op (also a no-op under
[`configure_for_testing` / `configure_for_offline`](testing.md)).

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
