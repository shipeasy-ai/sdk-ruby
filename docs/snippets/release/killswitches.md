Check the kill switch `{{RESOURCE_NAME}}` (true = killed).

> Assumes `Shipeasy.configure` ran at startup — see Installation.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# get_killswitch(name, switch_key = nil)
#   name       — the kill switch key
#   switch_key — optional named per-key override switch to read
if flags.get_killswitch("{{RESOURCE_NAME}}")
  # killed → take the safe path
end
```
