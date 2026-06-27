Evaluate the feature gate `{{RESOURCE_NAME}}` on a user-bound Client.

> Assumes `Shipeasy.configure` ran at startup — see Installation.

```ruby
# construct once per callsite (cheap; binds the user + runs the attributes transform)
flags = Shipeasy::Client.new(current_user)

# get_flag(name, default: false)
#   name    — the gate key
#   default — returned ONLY when the value can't be resolved (client not ready /
#             gate absent); a gate that evaluates to false returns false
if flags.get_flag("{{RESOURCE_NAME}}", default: false)
  # ship it
end
```
