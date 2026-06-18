# Changelog

## Unreleased

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
