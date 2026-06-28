# Shipeasy · Ruby Entity Guide (example)

A tiny **Ruby on Rails 7** app with a single page that reads like a guide
document: one styled card per Shipeasy entity, each showing what the entity is,
the SDK call that produces it, and its current value.

It boots with `bin/rails server` and renders with **no external services and no
network calls**.

## ⚠ The SDK is not wired up yet

This example deliberately does **not** depend on the `shipeasy-sdk` gem. Every
value on the page is a **hardcoded placeholder** set in
[`app/controllers/guide_controller.rb`](app/controllers/guide_controller.rb).

For each entity the controller shows the **real** SDK call as a
`# TODO: once shipeasy-sdk is installed` block, and the page renders that same
call as a visible code block. The top of the page carries the banner:

> ⚠ SDK not wired yet — every value below is a placeholder. Install
> `shipeasy-sdk` and replace the TODOs to make them live.

## Run it

```bash
cd examples/guide
bundle install
bin/rails server
```

Then open <http://localhost:3000>.

> Requires Ruby `>= 3.1` (Rails 7.1). If you only have an old system Ruby,
> install a newer one with `rbenv`/`rvm`/`asdf` first.

## The entities shown

1. **Feature flag** — a boolean on/off switch with targeting + rollout.
2. **Dynamic config** — a typed JSON blob you change without deploying.
3. **A/B experiment** — splits users into variants and measures a metric.
4. **Kill switch** — an operational off-switch (ships in the bootstrap payload).
5. **Event / metric** — fire-and-forget events that power metrics + dashboards.
6. **i18n label** — server-managed copy, rendered via Rails view helpers.
7. **Error reporting (`see()`)** — structured reports of the product consequence.

## Next step: make it live

1. Add the gem to the [`Gemfile`](Gemfile):

   ```ruby
   gem "shipeasy-sdk"
   ```

   then `bundle install`.

2. Configure the SDK once at boot with your **server** key.

3. In `app/controllers/guide_controller.rb`, replace each placeholder value with
   its `# TODO` block — e.g. swap the hardcoded `new_checkout = true` for:

   ```ruby
   on = Shipeasy.flags.get_flag("new_checkout", { user_id: "u_123" })
   ```

4. For the i18n label, use the Rails view helpers in the `.erb` view:

   ```erb
   <%= i18n_t("hero.title", name: "Sam") %>
   <%= i18n_head_tags %>   <!-- in <head> -->
   ```

## Tests

A Rails integration test under [`test/`](test/) shows the SDK's **testing**
setup end-to-end: it mocks every value Shipeasy returns with
[`Shipeasy.configure_for_testing`](../../docs/pages/testing.md) (zero network,
no API key), then `get "/"` dispatches the root route in-process and asserts the
mocked values appear in the rendered HTML.

```bash
cd examples/guide
bundle install                 # resolves shipeasy-sdk from ../../ (the local gem)
bin/rails test                 # or: ruby -Itest test/integration/guide_page_test.rb
```

> The value assertions are **expected to fail** until the controller is wired to
> the SDK — it currently renders hardcoded placeholders, so the mocked values do
> not yet appear in the HTML. The infrastructure assertions (route boots,
> renders HTML) and the `Shipeasy::Client` read-through pass today. Wiring the
> `# TODO` blocks in `app/controllers/guide_controller.rb` is what turns the
> value assertions green. Requires Ruby `>= 3.1` (Rails 7.1).

Docs: <https://docs.shipeasy.ai>
