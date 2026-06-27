Emit the i18n loader + head tags for profile `{{PROFILE}}` so the browser
hydrates translations on first paint (Rails view helpers auto-mount).

> Assumes `Shipeasy.configure` ran at startup with `c.public_key` + `c.profile`
> set — see Installation.

```erb
<%# i18n_head_tags(profile: nil, chunk: nil) — emits the inline data + loader tag.
    profile/chunk default to the configured values; pass them to override. %>
<%= i18n_head_tags(profile: "{{PROFILE}}") %>
```

Outside Rails, build the loader tag from the engine with the **public** client
key (never the server key):

```ruby
# i18n_script_tag(client_key, profile: "en:prod", base_url: nil)
#   client_key — the PUBLIC client key
#   profile    — locale profile to load
#   base_url   — CDN override (defaults to https://cdn.shipeasy.ai)
tag = Shipeasy.engine.i18n_script_tag(ENV.fetch("SHIPEASY_CLIENT_KEY"), profile: "{{PROFILE}}")
```
