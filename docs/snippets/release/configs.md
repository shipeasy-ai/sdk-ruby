Read the dynamic config `{{RESOURCE_NAME}}` with a fallback default.

```ruby
flags = Shipeasy::Client.new(current_user)
value = flags.get_config("{{RESOURCE_NAME}}", default: "blue")
```
