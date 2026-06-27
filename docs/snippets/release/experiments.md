Get the assignment for `{{RESOURCE_NAME}}` and track the `{{SUCCESS_EVENT}}` conversion.

```ruby
flags  = Shipeasy::Client.new(current_user)
result = flags.get_experiment("{{RESOURCE_NAME}}", { label: "Buy now" })

if result.in_experiment && result.group == "treatment"
  render_cta(result.params[:label])
end

Shipeasy.engine.track(current_user.id.to_s, "{{SUCCESS_EVENT}}", { revenue: 49.99 })
```
