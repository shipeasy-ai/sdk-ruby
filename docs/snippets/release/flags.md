Configure once, then evaluate `{{RESOURCE_NAME}}` on a user-bound Client.

```ruby
Shipeasy.configure { |c| c.api_key = ENV.fetch("SHIPEASY_SERVER_KEY") }

flags = Shipeasy::Client.new(current_user)
if flags.get_flag("{{RESOURCE_NAME}}")
  # ship it
end
```
