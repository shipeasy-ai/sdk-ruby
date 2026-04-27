# shipeasy-sdk (Ruby)

Ruby gem for the [Shipeasy](https://shipeasy.ai) hosted service. Server-side
gate evaluation, runtime configs, experiments, and metric ingestion.

> Source-available under the [Shipeasy-SAL 1.0](./LICENSE).

## Install

```ruby
# Gemfile
gem "shipeasy-sdk"
```

## Quickstart

```ruby
require "shipeasy-sdk"

client = Shipeasy::SDK.new_client(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
client.init   # fetches gates + experiments and starts the background poll thread

user = { user_id: "usr_123", plan: "pro", country: "US" }

if client.get_flag("new_checkout", user)
  # ship it
end

color  = client.get_config("button_color")
result = client.get_experiment("checkout_cta", user, { label: "Buy now" })
client.track("usr_123", "checkout_completed", { revenue: 49.99 })

client.destroy   # stops the poll thread on shutdown
```

`init_once` is a safe no-op if already initialized — convenient inside
Rails middleware.

## Evaluation details

- **Gates** — rules matched in order; rollout bucket =
  `murmur3("#{salt}:#{uid}") % 10000 < rollout_pct`.
- **Experiments** — `status == "running"`, optional targeting gate,
  universe holdout range, allocation bucket, then group assignment by
  weight.
- **MurmurHash3** — pure-Ruby x86_32 variant, seed 0.
- **ETag caching** — each poll sends `If-None-Match`; a 304 skips the
  JSON parse.
- **Poll interval** — defaults to 30 s; overridden by the
  `X-Poll-Interval` header from the flags endpoint.

## Configuration

| Parameter  | Default                     | Description                         |
| ---------- | --------------------------- | ----------------------------------- |
| `api_key`  | (required)                  | SDK key from the Shipeasy dashboard |
| `base_url` | `https://cdn.shipeasy.ai`   | Override for local dev / staging    |

## Documentation

[docs.shipeasy.ai](https://docs.shipeasy.ai)

## License

[Shipeasy-SAL 1.0](./LICENSE) — source-available, non-commercial-use,
permitted as a Shipeasy client.
