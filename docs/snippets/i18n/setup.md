Wire i18n with the public client key + profile `{{PROFILE}}` in `configure` (Rails view helpers auto-mount).

```ruby
Shipeasy.configure do |c|
  c.api_key    = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.public_key = ENV.fetch("SHIPEASY_CLIENT_KEY")
  c.profile    = "{{PROFILE}}"
end
```
