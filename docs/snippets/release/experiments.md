Get the assignment for `{{EXPERIMENT_KEY}}`, log exposure, and track the
`{{SUCCESS_EVENT}}` conversion — all on the bound Client. Assumes
`Shipeasy.configure` ran at startup — see Installation.

### Read the assignment

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# get_experiment(name, default_params, decode = nil)
#   name           — the experiment key (required)
#   default_params — params returned when NOT enrolled (the control shape)
#   decode         — optional proc run on the resolved params
result = flags.get_experiment("{{EXPERIMENT_KEY}}", { label: "Buy now" })

if result.in_experiment && result.group == "treatment"
  render_cta(result.params[:label])
end
```

### Log exposure + track the conversion

```ruby
flags = Shipeasy::Client.new(current_user)

# call when you actually present the treatment (no user arg — bound)
flags.log_exposure("{{EXPERIMENT_KEY}}")

# track the conversion on the same bound Client (unit derived from the bound user)
#   track(event_name, props = {})
flags.track("{{SUCCESS_EVENT}}", { revenue: 49.99 })
```
