Render a translated label in a Rails view with the `i18n_t` helper.

> Assumes `Shipeasy.configure` ran at startup — see Installation.

```erb
<%= i18n_head_tags %>

<%# i18n_t(key, variables = {}, profile: nil, chunk: nil)
      key       — the translation key
      variables — interpolation values for the string
      profile   — locale profile override (defaults to the configured profile)
      chunk     — optional key namespace/chunk override %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```
