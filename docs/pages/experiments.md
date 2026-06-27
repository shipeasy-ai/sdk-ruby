# A/B experiments

Server-side experiment assignment + conversion tracking, evaluated locally.

## Get the assignment

### Bound Client form

`get_experiment(name, default_params, decode = nil)` — user bound at construction:

```ruby
flags = Shipeasy::Client.new(current_user)

result = flags.get_experiment("checkout_cta", { label: "Buy now" })
```

### Engine form

`get_experiment(name, user, default_params, decode = nil)`:

```ruby
Shipeasy.engine.get_experiment("checkout_cta", user, { label: "Buy now" })
```

## ExperimentResult shape

Returns an `Eval::ExperimentResult` with:

- `result.in_experiment` — `true` if the user is enrolled (not in the holdout / outside allocation).
- `result.group` — the assigned group name (e.g. `"control"` / `"treatment"`).
- `result.params` — the variant params. Falls back to `default_params` when the
  user is not enrolled (or the experiment is absent).

```ruby
result = flags.get_experiment("checkout_cta", { label: "Buy now" })

if result.in_experiment && result.group == "treatment"
  render_cta(result.params[:label])
end
```

An optional `decode` proc projects the params for an enrolled user (a decode
failure falls back to `control` + `default_params`).

## Track a conversion ({{SUCCESS_EVENT}})

Conversions are recorded via the engine's `track` (fire-and-forget):

```ruby
Shipeasy.engine.track(current_user.id.to_s, "{{SUCCESS_EVENT}}", { revenue: 49.99 })
```

`track(user_id, event_name, props = {})` posts a metric event. Props are
sanitized and respect the configured private-attribute list (see
[advanced](advanced.md)).

## Exposure

The server is stateless and never auto-logs an exposure. When you actually
present the treatment, call `log_exposure` to emit the exposure event — see
[advanced](advanced.md#manual-exposure).
