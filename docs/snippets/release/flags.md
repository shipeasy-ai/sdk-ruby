Evaluate the feature gate `{{FLAG_KEY}}` on a user-bound Client. Assumes
`Shipeasy.configure` ran at startup — see Installation.

### Basic check

```ruby
# construct once per callsite (cheap; binds the user + runs the attributes transform)
flags = Shipeasy::Client.new(current_user)

# get_flag(name, default: false)
#   name    — the gate key (required)
#   default — returned ONLY when the value can't be resolved (client not ready /
#             gate absent); a gate that evaluates to false returns false
if flags.get_flag("{{FLAG_KEY}}", default: false)
  # ship it
end
```

### Why it resolved that way — `get_flag_detail`

```ruby
flags = Shipeasy::Client.new(current_user)

# returns a FlagDetail (.value, .reason); reason ∈ RULE_MATCH / DEFAULT / OFF /
# OVERRIDE / FLAG_NOT_FOUND / CLIENT_NOT_READY
detail = flags.get_flag_detail("{{FLAG_KEY}}")
logger.info("flag={{FLAG_KEY}} value=#{detail.value} reason=#{detail.reason}")
```

### React to flag changes (long-running server)

```ruby
# requires configure(poll: true); fires after a poll fetches NEW data (200, not 304)
unsubscribe = Shipeasy.on_change { reload_local_cache! }
# ... later: unsubscribe.call
```
