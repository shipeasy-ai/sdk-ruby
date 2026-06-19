# Changelog

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
