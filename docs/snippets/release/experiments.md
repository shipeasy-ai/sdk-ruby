Get the assignment for `{{RESOURCE_NAME}}` and track the `{{SUCCESS_EVENT}}` conversion.

> Assumes `Shipeasy.configure` ran at startup — see Installation.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# get_experiment(name, default_params, decode = nil)
#   name           — the experiment key
#   default_params — params returned when NOT enrolled (the control shape)
#   decode         — optional proc run on the resolved params
result = flags.get_experiment("{{RESOURCE_NAME}}", { label: "Buy now" })

if result.in_experiment && result.group == "treatment"
  render_cta(result.params[:label])
end

# track the conversion on the bound Client (id derived from the bound user)
#   track(event_name, props = {})
flags.track("{{SUCCESS_EVENT}}", { revenue: 49.99 })
```
