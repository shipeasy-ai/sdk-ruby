# Changelog

## 3.3.0 (2026-07-10)

### i18n render-keys-only mode (testing)

- **i18n:** new `render_keys_only` config makes the `i18n_t` view helper return
  the translation **key** verbatim instead of resolving its value (no fetch, no
  interpolation), so specs/snapshots assert against stable data instead of copy
  that changes when a translation is edited. **Defaults on when the native env
  is `"test"`** (`RAILS_ENV` / `RACK_ENV` / `SHIPEASY_ENV` / `APP_ENV`), off
  otherwise. Set `c.render_keys_only = true/false` in `Shipeasy.configure` to
  override. Adds `Shipeasy::SDK::Env.is_test_env` and
  `Shipeasy.config.render_keys_only?`.

## 3.2.0 (2026-07-08)

### Experiment exposure now fires on read, with a peek opt-out

`universe(name).assign` is now **side-effect free** — it picks the experiment and
resolves the params but logs nothing. The single (deduped) exposure fires on the
**first `assignment.get(...)` read** of an enrolled assignment: reading *is* the
exposure. Two behaviours change:

- **`Assignment#get` gains an `exposure:` keyword** —
  `get(field, fallback = nil, exposure: true)`. Pass `exposure: false` to read a
  param *without* logging an exposure (peek for a log line / debug view). The
  default keeps the read-logs-the-exposure behaviour.
- **Exposure dedup is now durable** — still deduped once per process, and now
  also durably per `(unit, experiment, group)` server-side, so re-reads and
  repeat runs never double-count.

### Durable forced-but-gated ID / cohort overrides

The experiment resolver now honours durable **ID overrides** and **cohort/gate
overrides** that are *forced but still gated*: a matched override pins the group
only when the unit passes targeting and isn't held out, and ID overrides beat
cohort overrides. This is consumed via the experiments blob — no new user-facing
SDK API. Running experiments are byte-identical; the new ordering rides
`hash_version: 3`.

## 3.1.1 (2026-07-08)

### Rails generator pins network egress to the environment

`rails generate shipeasy:install` now writes
`c.is_network_enabled = Rails.env.production?` into the generated
`config/initializers/shipeasy.rb`, so a freshly-scaffolded Rails app is fully
active in production and completely quiet in development / test. Set it to `true`
to load flags in development, or remove the line to let the SDK infer production
from `RAILS_ENV`/`RACK_ENV`/`APP_ENV`.

## 3.1.0 (2026-07-08)

### Environment-derived network & telemetry (egress) defaults

The SDK is now **quiet by default outside production**. Two egress controls
default **ON in production and OFF in every other environment**, so an app that
embeds `shipeasy-sdk` makes **no outbound request from a dev machine or CI**
unless it opts in:

- **`is_network_enabled`** (new `configure` option) — the master switch for ALL
  outbound requests: flag/experiment/config fetch, `track`, exposure logging,
  `see()` reports, SDK self-monitoring, **and** telemetry. When off the SDK is
  fully offline: reads answer from your overrides / in-code defaults and nothing
  is sent.
- **`disable_telemetry`** (existing option) — its **default is now
  environment-derived** rather than always-on: telemetry is ON in production and
  OFF outside it. Forced off whenever `is_network_enabled` is off.

"Production" is decided by a new `Shipeasy::SDK::Env.is_production_env` helper
with this precedence:

1. A native runtime env var, checked in order: `SHIPEASY_ENV`, `RAILS_ENV`,
   `RACK_ENV`, `APP_ENV`. `"production"`/`"prod"` (case-insensitive) ⇒ production;
   any other present value ⇒ not production.
2. If none is set, fall back to the SDK's own `env` option (defaults to `"prod"`),
   so a real production deploy stays ON by default.

**Behaviour change / how to restore the old always-on behaviour.** Existing apps
that ran the SDK in a non-production environment and relied on live network/
telemetry will now be offline there. To keep the previous behaviour, either set a
production env var (e.g. `RAILS_ENV=production` / `SHIPEASY_ENV=production`) in
that environment, or opt in explicitly:

```ruby
Shipeasy.configure do |c|
  c.api_key            = ENV.fetch("SHIPEASY_SERVER_KEY")
  c.is_network_enabled = true   # force the network on regardless of environment
end
```

Explicitly-passed `is_network_enabled` / `disable_telemetry` values always
override the environment-derived default. Test mode (`configure_for_testing` /
`configure_for_offline`) is unchanged — it forces the SDK fully offline as before.

## 3.0.0 (2026-07-08)

### Breaking — experiments are now read by universe, not by name

The whole experiment read surface is replaced. A **universe is a mutual-exclusion
pool**: a unit is enrolled in **at most one** experiment in it, so you ask a
universe for an assignment instead of naming an experiment. `get_experiment` and
`log_exposure` are **removed** from both `Shipeasy::Client` and `Shipeasy::Engine`.

```ruby
# Before (removed):
result = flags.get_experiment("checkout_color", { button_color: "red" })
if result.in_experiment && result.group == "treatment"
  render(result.params[:button_color])
end
flags.log_exposure("checkout_color")

# After — bound Client (user bound at construction, no user arg):
exp = flags.universe("checkout").assign
render(exp.get("button_color", "red"))   # auto-logs a single exposure when enrolled

# After — Engine (advanced; pass the user):
exp = engine.universe("checkout").assign(user)
```

- **`universe(name).assign`** returns an `Shipeasy::SDK::Eval::Assignment`:
  - `#name` — the experiment the unit landed in, or `nil` when not enrolled.
  - `#group` — the assigned variant, or `nil` when not enrolled.
  - `#enrolled?` — boolean (`group` is non-nil).
  - `#get(field, fallback = nil)` — resolves **variant override ?? universe
    default ?? fallback**. Works even when not enrolled (you get the universe
    default), because the universe now owns the param schema + defaults. No more
    `default_params`/`decode`.
- **Auto-exposure.** `assign` logs a single exposure when the unit is enrolled
  (deduped per process). The manual `log_exposure` primitive is gone — reading
  *is* the exposure. Still a no-op in test/offline mode.
- **Mutual exclusion (pooled assignment), per-experiment holdout gates, reserved
  headroom, and universe-default ⊕ variant param merge** are now honoured by
  local eval, matching the edge. The `evaluate` / `bootstrap_script_tag` SSR
  payload gains a top-level `universes` defaults map and a `universe` field per
  experiment.
- The internal `Shipeasy.override_experiment` / `override_experiment` test seams
  are unchanged (still experiment-keyed) and surface through `assign` when the
  experiment exists in the loaded blob.

## 2.5.0 (2026-07-08)

### Added

- **SDK self-monitoring for internal errors.** When the SDK's last-resort guard
  (`Engine#safe_run`, which wraps every public runtime read) swallows an internal
  failure — a bug on Shipeasy's side, not the caller's — it now also reports that
  error to Shipeasy's own project so we can track and fix SDK bugs across every
  app the SDK runs in. This is a dedicated, baked-in destination (a public
  client-key ingest credential), entirely separate from your `see()` reporting:
  internal errors never land in your project or Errors tab. The report carries
  only the error itself plus a stable, deduped consequence (subject = the guarded
  operation, e.g. `get_flag`) and is fire-and-forget on a background thread — it
  can never slow down or break a read. On by default; opt out with
  `c.disable_internal_error_reporting = true` in the `Shipeasy.configure` block.

## 2.4.1 (2026-07-07)

### Fixed

- **Default API host now resolves.** The default `base_url` pointed at the
  unregistered domain `https://edge.shipeasy.dev`, so every `configure` one-shot
  fetch and every `get_flag`/`get_config`/`get_experiment`/`track`/`see()` call
  failed with a DNS error (`getaddrinfo`) unless `base_url` was set explicitly.
  Corrected to the real edge origin `https://api.shipeasy.ai` — the host the
  docs, CLI, and curl snippets already use. Explicit `base_url` overrides are
  unaffected.

## 2.4.0 (2026-07-07)

- **Fail-safe runtime reads + a `log_level` config option.** The public runtime
  reads and side-effect calls — `get_flag` / `get_flag_detail` / `get_config` /
  `get_experiment` / `get_killswitch` / `track` / `log_exposure` (on both
  `Shipeasy::Client` and the `Engine`) — now **never raise** into caller code.
  On any internal error they rescue, log a diagnostic, and return the documented
  safe default (`get_flag`/`get_config` → your `default`; `get_experiment` → a
  not-enrolled `control` result with your `default_params`; `get_killswitch` →
  `false`; `track`/`log_exposure` → `nil`). This closes gaps where a user
  `decode` block in `get_config`, or a synchronous `JSON.generate` in
  `track`/`log_exposure`, could raise before the background thread. Setup and
  lifecycle calls (`Client.new` before `configure`, a non-callable `attributes`,
  `configure_for_offline` with no source, `Engine.from_file` on a bad path,
  `on_change` with no callable, …) still raise loudly — those are boot-time
  misconfiguration.
- New **`c.log_level`** on `Shipeasy.configure` (default `:warn`; also
  `:silent`, `:error`, `:info`, `:debug` — strings accepted and downcased,
  unknown falls back to `:warn`). It tunes the SDK's stderr diagnostics through
  a small leveled logger (`Shipeasy::Logging`); `:silent` mutes them entirely.
  Ordering: `silent < error < warn < info < debug` (a message at level L is
  emitted iff the configured level is at least as verbose as L). Logging is
  best-effort and never raises.

## 2.3.1 (2026-06-29)

- **Admin API client regenerated from the canonical OpenAPI spec (2.0.0).** The
  2.3.0 client was generated from a stale 1.0.0 subset; this regenerates it from
  the full spec, adding the connectors, errors, keys, drafts, profiles and
  api-keys endpoints. `Shipeasy::Admin::Client` readers now track the spec tags:
  `flags`, `configs`, `killswitch`, `experiments`, `universes`, `attributes`,
  `metrics`, `events`, `ops`, `alerts`, `projects`, `profiles`, `keys`, `drafts`,
  `errors`, `connectors`, `api_keys` (renamed from `gates`/`killswitches`/
  `alert_rules`, plus the new groups).

## 2.3.0 (2026-06-29)

- **Optional Admin API client** — a new opt-in `Shipeasy::Admin::Client` for
  *administering* resources (create gates, start experiments, manage configs/
  killswitches/universes/metrics/events, …) from server code. It is a raw client
  **generated from the Shipeasy OpenAPI spec** (1:1 with the REST API — id-based,
  basis-points, snake_case; no name→id or percent→bp ergonomics, which stay in
  the CLI/MCP).
  - Off by default: the `shipeasy-sdk` entrypoint never loads it, and its HTTP
    dependency (`faraday`) is optional. Opt in with `gem "faraday"` +
    `require "shipeasy/admin"` (mirrors the OpenFeature provider gating).
  - `Shipeasy::Admin::Client.new(api_key:, project_id:)` wires bearer auth +
    `X-Project-Id` scoping (base URL defaults to `https://shipeasy.ai`); resource
    groups are reached as `admin.gates`, `admin.experiments`, … (gates, configs,
    killswitches, experiments, universes, metrics, events, alert_rules, attributes,
    projects, ops, i18n).
  - Regenerate after a contract change: refresh `admin/openapi.json` then run
    `bash scripts/gen_admin.sh` (only the generated `lib/shipeasy_admin*` tree is
    rewritten; the `Client` shim is preserved). Generator pinned via `openapitools.json`.

## 2.2.0 (2026-06-28)

**Rails generator — `rails generate shipeasy:install`.** Scaffolds Shipeasy into
a Rails app the Rails way instead of pasting an initializer from the docs.

- **`rails generate shipeasy:install`** writes `config/initializers/shipeasy.rb`
  with the single `Shipeasy.configure` call (server key from the environment,
  background poll on by default), then prints the keys / Rails-credentials next
  steps. The gem's Railties already mount the anon-id Rack middleware and the
  i18n view helpers, so the generator only creates what the app must own.
- **`--i18n`** also sets the public client key in the initializer and injects
  `<%= i18n_head_tags %>` into `app/views/layouts/application.html.erb` (before
  `</head>`; idempotent, skips cleanly when the layout is missing or already
  wired).
- **`--no-poll`** generates a serverless one-shot-fetch initializer instead of
  the background poll.
- Generator templates (`initializer.rb.tt`, `USAGE`) are now packaged in the gem
  (`lib/generators/**/*`) so the generator works from the installed gem.

## 2.1.0 (2026-06-27)

**Uniform SDK DX standard (experiment-platform doc 23) — parity with the Python
reference. The documented surface is now exactly `Shipeasy.configure` (+ test/
offline siblings) and the bound `Shipeasy::Client.new(user)`; the `Engine` stays
public but is undocumented.** All changes are additive and backward compatible.

- **`Shipeasy.configure_for_testing(flags:, configs:, experiments:, attributes:)`**
  — a no-network, no-api-key sibling of `configure` that seeds overrides and
  registers the global engine so `Shipeasy::Client.new(user)` reads them.
  **Replaces** any prior config (so a suite can reconfigure between cases).
- **`Shipeasy.configure_for_offline(snapshot:|path:, flags:, configs:,
  experiments:, attributes:)`** — evaluates the **real** rules from an in-memory
  snapshot or a JSON file, overrides layered on top. Also replaces prior config.
- **`c.poll` / `c.init` configure options.** `c.poll = true` starts the
  background poll from `configure` (no more `Shipeasy.engine.init`); the default
  (one-shot fetch, no thread) is serverless-friendly.
- **Advanced `configure` options threaded into the global engine** — `c.env`,
  `c.disable_telemetry`, `c.telemetry_url`, `c.private_attributes`,
  `c.sticky_store` — so private attributes / sticky bucketing / env tagging no
  longer require constructing an `Engine` by hand.
- **Package-level helpers** so callers never name the `Engine`:
  `Shipeasy.override_flag/override_config/override_experiment/clear_overrides`,
  `Shipeasy.on_change`, `Shipeasy.i18n_script_tag`, `Shipeasy.bootstrap_script_tag`,
  and `Shipeasy.see` / `see_violation` / `control_flow_exception` (delegating to
  the configured global / last-constructed default client).
- **`get_killswitch(name, switch_key)` now falls back to the top-level value**
  when `switch_key` isn't a configured named switch (matching the cross-SDK
  contract), instead of returning `false`.
- **OpenFeature provider global form.** `Shipeasy::OpenFeature::Provider.new`
  (no argument) resolves the engine configured via `Shipeasy.configure`, so the
  provider is constructed after `configure(...)`, never from an `Engine` handle.
- **`Engine.for_testing` is now READY against an empty blob** (matching the other
  SDKs): a missing gate resolves `FLAG_NOT_FOUND` instead of `CLIENT_NOT_READY`.
  `get_flag` results are unchanged (a missing gate still returns the default).
- **OpenFeature `track` now folds the evaluation-context attributes** (minus the
  identity keys) into the metric properties, with the tracking-event details
  merged on top. (These two fixes also let the OpenFeature suite run green on the
  new Ruby 3.4 CI row, where the optional `openfeature-sdk` is installed.)
- **`shipeasy-skill` command** (`bin/shipeasy-skill`) — opt-in installer that
  copies the bundled `docs/skill/SKILL.md` into `.claude/skills/shipeasy-ruby/`
  (`install [--dir] [--force]` / `print`). The skill is shipped inside the gem.
- **README is now generated** from `docs/` by `scripts/gen_readme.rb` (`rake
  readme`); CI's `readme` job fails on drift. The test matrix covers Ruby
  3.0–3.4 and the README carries a Tests status badge.
- **Docs rewritten Engine-free** around `configure` + `Client`, with new
  `metrics/track` + `ops/see` snippet groups, specific placeholders, and a
  validated offline snapshot example. Added repo-root + `docs/` `CLAUDE.md`.

## 2.0.0 (2026-06-25)

**BREAKING: new `Shipeasy.configure` + `Shipeasy::Client.new(user)` front door.**

- **Rename `Shipeasy::SDK::FlagsClient` → `Shipeasy::Engine`.** The
  heavyweight class (owns the api key, HTTP transport, blob cache, poll timer,
  `init`/`init_once`, local overrides, `track`, `see()`/default-client wiring)
  is now a clean top-level `Shipeasy::Engine`. Its public surface is otherwise
  unchanged — `for_testing` / `from_snapshot` / `from_file`, `override_*`,
  `on_change`, `track`, `log_exposure`, `evaluate`, `bootstrap_script_tag`,
  `i18n_script_tag`, `see`/`see_violation`/`control_flow_exception` all keep the
  same signatures. `Shipeasy::SDK.new_client` and `Shipeasy.flags` now return an
  `Engine`. Update any direct `Shipeasy::SDK::FlagsClient` references (including
  the `REASON_*` constants and `FlagDetail`, which moved to `Shipeasy::Engine`).

- **New `Shipeasy::Client` — a lightweight, user-bound handle built via its
  real constructor.** `Shipeasy::Client.new(user)`:
  - reads the api key from the global config (NO key argument),
  - runs the configured `attributes` transform on `user` **once at
    construction**, then applies the existing `__se_anon_id` request-context
    merge, and stores the resulting attribute hash,
  - exposes `get_flag(name, default:)`, `get_flag_detail(name)`,
    `get_config(name, decode, default:)`, `get_experiment(name, default_params,
    decode)`, `get_killswitch(name, switch_key)` — all with **NO user
    argument** — forwarding to the single global engine.
  - is cheap: it never opens its own connection, fetches, or polls.

  The end-state call is literally `Shipeasy::Client.new(user).get_flag("name")`.
  Constructing a `Client` before `Shipeasy.configure` raises `Shipeasy::Error`.

- **`Shipeasy.configure { |c| … }` now also accepts `c.attributes`** — a
  callable mapping your own user object (any shape) to the Shipeasy attribute
  hash (default = identity). On `configure`, the gem builds and registers the
  ONE global engine (`Shipeasy.engine`, first-config-wins) from `api_key` /
  `base_url` and kicks off its one-shot fetch fire-and-forget, so a bound
  `Client` resolves against real rules with no explicit `init` call.

- **New `Shipeasy::Engine#get_killswitch(name, switch_key = nil)`** — reads a
  killswitch from the cached blob (whole-switch `killed`, or a named per-key
  `switches` entry). Surfaced on `Shipeasy::Client` too.

Migration: `Shipeasy.flags.get_flag(name, user)` still works (the legacy
singleton is retained). New code should prefer
`Shipeasy.configure { |c| c.api_key = …; c.attributes = ->(u){ … } }` then
`Shipeasy::Client.new(user).get_flag("name")`.

## 1.7.0 (2026-06-20)

- **SSR bootstrap script-tag helpers.** New `FlagsClient#evaluate(user)`
  batch-evaluate (every gate/config/experiment → a `{ "flags", "configs",
  "experiments", "killswitches" }` payload) plus `bootstrap_script_tag` and a
  framework-agnostic `i18n_script_tag`, which emit the cross-platform declarative
  `<script>` tags carrying the SSR payload as `data-*` attributes. The static
  `se-bootstrap.js` loader hydrates `window.__SE_BOOTSTRAP` and writes the
  `__se_anon_id` cookie so the browser buckets identically to the server. **No
  SDK key is embedded** in the bootstrap tag. The Rails
  `Shipeasy::I18n::ViewHelpers#i18n_script_tag` view helper is unchanged.

- **OpenFeature provider.** Added `Shipeasy::OpenFeature::Provider`, an adapter
  that plugs `FlagsClient` into the CNCF OpenFeature Ruby API (`openfeature-sdk`
  gem, module `OpenFeature::SDK::Provider`). Metadata name is `"shipeasy"`.
  `fetch_boolean_value` maps onto a gate via `get_flag_detail` — building the
  user from the evaluation context (`targeting_key` → `user_id`, other fields →
  user attributes) — and translates the Shipeasy reason to OpenFeature:
  `RULE_MATCH → TARGETING_MATCH`, `DEFAULT → DEFAULT`, `OFF → DISABLED`,
  `OVERRIDE → STATIC`, `FLAG_NOT_FOUND → ERROR`/`FLAG_NOT_FOUND`,
  `CLIENT_NOT_READY → ERROR`/`PROVIDER_NOT_READY`, returning the default on any
  error reason. `fetch_string/number/integer/float/object_value` route to
  `get_config`: absent key → default with `DEFAULT`; present but wrong type →
  default with `TYPE_MISMATCH`; present and well-typed → value with
  `TARGETING_MATCH`. `init`/`shutdown` and `track` are bridged to the client.
  The provider lives in `lib/shipeasy/sdk/openfeature.rb` and is **not** loaded
  by the main entrypoint — it `require`s `open_feature/sdk` lazily, so
  `openfeature-sdk` stays an optional (development-only) dependency that apps add
  to their own Gemfile. (`openfeature-sdk` requires Ruby >= 3.4.)

## 1.6.0

- **`see()` structured error reporting.** New error-reporting grammar mirroring
  `@shipeasy/sdk`. Every handled exception documents its product *consequence*,
  not just its stack. Available both as instance methods on `FlagsClient` and as
  a module-level facade backed by the last-constructed client:

  ```ruby
  begin
    charge_card(order)
  rescue => e
    Shipeasy::SDK.see(e).causes_the("checkout").extras(order_id: id).to("use cached prices")
  end

  # non-exception problem (stable fingerprint name, variable data in extras):
  client.see_violation("large query").causes_the("search results").to("be trimmed")

  # expected control flow — marks the exception and reports NOTHING:
  Shipeasy::SDK.control_flow_exception(e).because("because it wasn't an encoded Foo")
  ```

  `.to(outcome)` is the terminal: it builds the wire event and fire-and-forgets a
  POST to `/collect` (in a background `Thread`, exactly like `track`), and is
  idempotent. `causes_the` and `extras` are chainable setters callable in any
  order before `.to`; `extras` merges on repeat. The event is the cross-SDK
  shape `{ type: "error", kind, error_type, message, stack?, subject, outcome,
  extras?, side: "server", env?, sdk_version, ts }`. Extras are sanitized (≤20
  keys, ≤200-char string values, nil dropped, only String/Numeric/boolean kept)
  and the client's `private_attributes` are stripped. A per-process spam limiter
  (30s dedup, 25-send cap) bounds network chatter. No-op in test/offline mode
  (`for_testing`/`from_file`/`from_snapshot`); a module-level `see()` before any
  client warns and no-ops instead of raising. `sdk_version` is now sent on these
  events. The client also stores its `env` so reports are environment-tagged.

## 1.5.0 (2026-06-18)

- **Private attributes.** `FlagsClient.new(..., private_attributes: [...])` takes
  an array of attribute names (LD/Statsig `privateAttributes`) that are usable for
  local targeting but stripped from every outbound `track()` properties bag before
  it is POSTed to `/collect`. String and symbol keys are both matched. When the
  strip empties the bag, the `properties` key is omitted entirely. No
  `private_attributes` = previous behavior.
- **Manual exposure (server).** Added `log_exposure(user_or_user_id,
  experiment_name)`. The server is stateless and never auto-logs exposures, so
  call this when you actually present a treatment. It re-evaluates the experiment
  (a bare user_id string is wrapped as `{ "user_id" => id }`) and, if the user is
  enrolled, POSTs one `{type:"exposure", experiment:, group:, user_id:, ts:}`
  event to `/collect`. No-op in test mode or when the user isn't enrolled.
- **Sticky bucketing (server).** New `sticky_store:` option taking a duck-typed
  store — `get(unit) -> { exp => {"g"=>group, "s"=>salt8} }` or nil, and
  `set(unit, exp, entry)`. Threaded into experiment eval after the holdout, before
  allocation: when a stored entry for `(unit, exp)` has `s == salt[0,8]`, the
  allocation gate is skipped and the stored group is returned without a re-pick
  (so shrinking allocation keeps an enrolled unit in). A salt-prefix mismatch or a
  vanished stored group re-buckets and overwrites; a fresh pick is persisted via
  `set`. `unit` is the `pick_identifier`-resolved id. A built-in
  `Shipeasy::SDK::InMemoryStickyStore` (optionally seeded) is provided. Absent
  store ⇒ deterministic behavior (fully backward compatible).
- **Per-experiment `bucketBy`.** Experiment evaluation now honors an optional
  `bucketBy` attribute (read from the experiment's JSON `bucketBy` field). When
  set and the user carries that attribute as a non-empty string (or any number,
  stringified), all three experiment hashes — holdout, allocation, and group —
  bucket on that value instead of the unit id, so a whole company/org lands on
  one variant. When the attribute is absent it falls back to `user_id`, then
  `anonymous_id` (matching gate bucketing). No `bucketBy` = previous behavior.
  Mirrors the canonical `packages/core` `pickIdentifier`.

## 1.4.0 (2026-06-18)

- **Default values on `get_flag` / `get_config`.** Both getters now take an
  optional `default:` keyword returned only when the value cannot be resolved —
  for `get_flag`, when the client isn't ready or the gate is missing (never when
  a flag evaluates to `false`); for `get_config`, when the config key is absent.
  A `decode` proc still runs on a present config value. Backward compatible:
  `default` is `false` / `nil` respectively, matching the old behavior.
- **Flag evaluation detail.** Added `get_flag_detail(name, user)` returning a
  `FlagDetail` struct (`.value`, `.reason`) plus `REASON_*` constants
  (`CLIENT_NOT_READY`, `FLAG_NOT_FOUND`, `OFF`, `OVERRIDE`, `RULE_MATCH`,
  `DEFAULT`). The reason is computed at the boundary without touching the
  canonical evaluator. `get_flag` is re-implemented on top of it. The `gate`
  usage beacon fires exactly once per call (never on the `OVERRIDE`
  short-circuit).
- **Change listeners.** Added `on_change { ... }` (also accepts a callable),
  returning an unsubscribe proc. Listeners fire after a background poll fetches
  new flag/config data (HTTP 200, not 304); they never fire in test/offline
  mode. A raising listener is isolated (warned, not propagated).
- **Offline file/snapshot data source.** Added `FlagsClient.from_file(path)` and
  `FlagsClient.from_snapshot(flags:, experiments:)`. Loads a captured snapshot
  (`{ "flags": …, "experiments": … }`) into a no-network client (reuses the
  `for_testing` plumbing: telemetry off, `init`/`init_once`/`track` no-ops) that
  runs the real evaluator against the snapshot. Local `override_*` apply on top.
- **Local-override test utility.** Added `FlagsClient.for_testing`, a factory
  that returns a no-network, immediately-usable client (telemetry disabled,
  `init`/`init_once`/`track` are no-ops, no api_key required), plus Statsig-style
  override setters usable on any client: `override_flag(name, value)`,
  `override_config(name, value)`, `override_experiment(name, group, params)`, and
  `clear_overrides`. An override wins over the fetched blob in the matching
  getter; `override_experiment` makes `get_experiment` return an in-experiment
  `Eval::ExperimentResult`. Existing behavior is unchanged when no overrides are
  set and the client is not in test mode.

## 1.3.0

- **Anonymous bucketing (`__se_anon_id`).** Added `Shipeasy::SDK::RackMiddleware`,
  a Rack middleware that mints the shared `__se_anon_id` first-party cookie for
  any request without one and exposes it via `request.env["shipeasy.anon_id"]`.
  In Rails it is auto-mounted by a Railtie; gate/experiment evaluations with no
  explicit `user_id`/`anonymous_id` now default to the cookie id, so anonymous
  visitors bucket consistently across server renders and the browser with no
  per-call wiring. Implements the cross-SDK contract in
  `18-identity-bucketing.md`.
- **Eval fix (no-unit gate rule).** A request with no `user_id`/`anonymous_id`
  now resolves a fully-rolled (100%) gate as **on** instead of always off; a
  fractional gate is still off until a stable unit exists. Brings Ruby in line
  with the TypeScript reference SDK. Targeting rules are still evaluated first.

## 1.2.0

- Prior release (feature gates, configs, experiments, metrics, Rails i18n
  helpers).
