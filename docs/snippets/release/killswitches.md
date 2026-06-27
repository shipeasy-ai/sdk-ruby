Check the kill switch `{{RESOURCE_NAME}}` (true = killed).

```ruby
flags = Shipeasy::Client.new(current_user)
if flags.get_killswitch("{{RESOURCE_NAME}}")
  # killed → take the safe path
end
```
