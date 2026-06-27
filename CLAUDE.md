# CLAUDE.md — shipeasy Ruby SDK

Guidance for AI agents (and humans) working in this repository.

## What this is

`shipeasy-sdk` — the **server** SDK for [Shipeasy](https://shipeasy.ai): feature
flags, dynamic configs, kill switches, A/B experiments, metric tracking, `see()`
error reporting, and Rails i18n view helpers. Server-key only; never embed in a
browser. Source under `lib/`, tests under `spec/` (run with `rspec`).

## The documented public surface (this is a contract)

Users are taught exactly **two** things, and the docs must never drift from them:

1. **`Shipeasy.configure { |c| … }`** — and its siblings
   `Shipeasy.configure_for_testing` / `Shipeasy.configure_for_offline` — for setup.
2. **`Shipeasy::Client.new(user)`** — the cheap, user-bound handle for *all* reads
   (`get_flag` / `get_flag_detail` / `get_config` / `get_killswitch` /
   `get_experiment` / `log_exposure` / `track`).

Plus the package-level helpers that let users avoid the heavyweight object:
`Shipeasy.override_flag/override_config/override_experiment/clear_overrides`,
`Shipeasy.on_change`, `Shipeasy.i18n_script_tag`, `Shipeasy.bootstrap_script_tag`,
and the `Shipeasy.see` family (`see` / `see_violation` / `control_flow_exception`).

**The `Shipeasy::Engine` class is an internal detail. Do NOT document it.** It
stays public for advanced/back-compat use (and `Shipeasy.engine` / the legacy
`Shipeasy.flags` still work), but no page, snippet, skill, or the README should
tell a user to construct or call an `Engine`. New user-facing capability that
today only exists on the `Engine` should get a `configure`-style or package-level
affordance, then be documented through that.

## HARD RULE: change the SDK → update the docs in the SAME change

`docs/` is the published, user-facing source of truth (rendered at
<https://shipeasy-ai.github.io/sdk-ruby/> and ingested by the Shipeasy CLI/MCP
`docs` tooling and the central docs portal). If you change the SDK's **public API
or behaviour**, you MUST update the docs in the same commit:

- New/changed/removed public method, argument, default, or return shape → update
  the relevant `docs/pages/*.md`, the matching `docs/snippets/**`, and
  `docs/skill/SKILL.md`.
- New page / snippet / placeholder → also update `docs/manifest.json`.
- See [`docs/CLAUDE.md`](docs/CLAUDE.md) for the docs structure and conventions.

**`README.md` is generated — do not hand-edit it.** It is assembled from the
docs by `scripts/gen_readme.rb` (install + quickstart pulled from the pages, a
documentation table, and the testing section). After editing `docs/`, run:

```sh
ruby scripts/gen_readme.rb     # or: rake readme
```

CI (`.github/workflows/test.yml`, the `readme` job) re-runs it and fails if
`README.md` is out of date, so commit the regenerated file. A code change that
lands without its doc update is incomplete — when in doubt, grep `docs/` for the
symbol you touched.

## Versioning & release

- Bump the version in `lib/shipeasy/sdk/version.rb` (it is reported on every
  `see()` event) and add a `CHANGELOG.md` entry.
- Publishing is **release-gated**: a GitHub release on `shipeasy-ai/sdk-ruby`
  fires `.github/workflows/publish.yml` (RubyGems Trusted Publishing). A
  version-bumped push to `main` is **not** the release — cut a release. Never
  `gem push` locally.

## Checks before you commit

- `rspec` (fast; the suite is hermetic — no network). CI runs it on Ruby
  3.0–3.4 via `.github/workflows/test.yml`; the README shows the status badge.
  The OpenFeature provider spec self-skips when `openfeature-sdk` (Ruby ≥ 3.4)
  is unavailable.
- New public behaviour ships with a spec.
- Docs updated per the hard rule above; `docs/manifest.json` stays valid JSON and
  every path it lists exists.
- `ruby scripts/gen_readme.rb` and commit the result (CI checks it's in sync).

## The bundled agent skill

`docs/skill/SKILL.md` is shipped inside the gem and installed by the opt-in
`shipeasy-skill` command (`bin/shipeasy-skill`, `lib/shipeasy/sdk/skill.rb`):
`shipeasy-skill install` copies it to `.claude/skills/shipeasy-ruby/SKILL.md`,
`shipeasy-skill print` writes it to stdout. There is no install-time hook (gems
don't run code on install). Keep `docs/skill/SKILL.md` in `spec.files` so it's
packaged.
