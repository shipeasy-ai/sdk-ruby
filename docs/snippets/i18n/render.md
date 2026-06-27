Render a translated label in a Rails view with the `i18n_t` helper.

```erb
<%= i18n_head_tags %>
<h1><%= i18n_t("hero.title", name: current_user.name) %></h1>
```
