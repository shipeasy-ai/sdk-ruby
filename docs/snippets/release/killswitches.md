Read the kill switch `{{KILLSWITCH_KEY}}` (true = killed). Assumes
`Shipeasy.configure` ran at startup — see Installation.

### Whole switch

```ruby
# construct once per callsite (cheap; binds the user)
flags = Shipeasy::Client.new(current_user)

# get_killswitch(name, switch_key = nil)
#   name       — the kill switch key (required)
#   switch_key — optional named per-key switch to read
if flags.get_killswitch("{{KILLSWITCH_KEY}}")
  # killed → take the safe path
end
```

### A named per-key switch

```ruby
flags = Shipeasy::Client.new(current_user)

provider = "stripe"   # pass the thing you're about to do as the switch key

# A configured switch returns its own boolean; an unconfigured key falls back to
# the kill switch's top-level value.
if flags.get_killswitch("{{KILLSWITCH_KEY}}", provider)
  use_backup_processor
end
```
