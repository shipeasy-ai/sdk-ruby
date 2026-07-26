Emit the i18n loader + head tags for profile `{{PROFILE}}` so the browser
hydrates translations on first paint (Rails view helpers auto-mount).

> Assumes `Shipeasy.configure` ran at startup with `c.public_key` + `c.profile`
> set — see Installation.

```erb
<%# i18n_head_tags(profile: nil) — emits the inline data + loader tag.
    profile defaults to the configured value; pass it to override. %>
<%= i18n_head_tags(profile: "{{PROFILE}}") %>
```

The package-level tag helpers work anywhere (Rails or not) and take every
argument from `Shipeasy.configure` — so the bare call is the normal one. They
carry the **public** client key, never the server key:

```erb
<%# Loader tag only — no arguments needed, and already html_safe. %>
<%= Shipeasy.i18n_script_tag %>
```

```ruby
# i18n_script_tag(client_key = nil, profile: nil, base_url: nil)
#   client_key — the PUBLIC client key (default: config.public_key)
#   profile    — locale profile to load (default: config.profile)
#   base_url   — CDN override           (default: config.cdn_base_url,
#                                        i.e. https://cdn.shipeasy.ai)
# Pass an argument only to override the configured value for this one tag.
tag = Shipeasy.i18n_script_tag(ENV.fetch("SHIPEASY_CLIENT_KEY"), profile: "{{PROFILE}}")
```
