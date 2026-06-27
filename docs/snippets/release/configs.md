Read the dynamic config `{{CONFIG_KEY}}` with a fallback default.

> Assumes `Shipeasy.configure` ran at startup — see Installation.

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# get_config(name, decode = nil, default: nil)
#   name    — the config key
#   decode  — optional proc run on a present value, e.g. ->(v) { v["max"] }
#   default — returned only when the config key is absent
value = flags.get_config("{{CONFIG_KEY}}", default: "blue")
```
