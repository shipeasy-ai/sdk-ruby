# frozen_string_literal: true

# GuideController renders a single "big guide document" page: one card per
# Shipeasy entity, each showing what it is, the SDK call that produces it, and
# its current value.
#
# ──────────────────────────────────────────────────────────────────────────
#  ⚠  THE SDK IS NOT WIRED UP YET.
#
#  Every value below is a hardcoded PLACEHOLDER. The real Shipeasy SDK call for
#  each entity is shown twice:
#    1. as a `# TODO: once shipeasy-sdk is installed` block right next to the
#       placeholder, so you know exactly what to swap in, and
#    2. as a visible code block on the rendered page.
#
#  To make these live: add `gem "shipeasy-sdk"` to the Gemfile, `bundle install`,
#  configure the SDK once at boot, and replace each placeholder with its TODO.
# ──────────────────────────────────────────────────────────────────────────
class GuideController < ApplicationController
  def index
    # Each entry is one card on the page. `:value` is the placeholder the view
    # renders in the value pill; `:call` is the SDK snippet rendered as a code
    # block. Keys/values/calls below mirror the README + the live SDK API.
    @entities = [
      # 1 ─ FEATURE FLAG ───────────────────────────────────────────────────
      {
        kind:        "Feature Flag",
        accent:      "#34d399",
        key:         "new_checkout",
        what:        "A boolean on/off switch with targeting rules + percentage rollout.",
        # TODO: once shipeasy-sdk is installed
        #   on = Shipeasy.flags.get_flag("new_checkout", { user_id: "u_123" })
        #   @flag_on = on
        value:       flag_pill("new_checkout", true),
        call:        %(on = Shipeasy.flags.get_flag("new_checkout", { user_id: "u_123" })),
        meta:        "reason: RULE_MATCH"
      },

      # 2 ─ DYNAMIC CONFIG ─────────────────────────────────────────────────
      {
        kind:        "Dynamic Config",
        accent:      "#60a5fa",
        key:         "billing_copy",
        what:        "A typed JSON blob you change without deploying.",
        # TODO: once shipeasy-sdk is installed
        #   cfg = Shipeasy.flags.get_config("billing_copy")
        #   @billing_copy = cfg
        value:       config_pill({ "headline" => "Welcome back 👋", "cta" => "Upgrade to Pro" }),
        call:        %(cfg = Shipeasy.flags.get_config("billing_copy")),
        meta:        "keys: headline, cta"
      },

      # 3 ─ A/B EXPERIMENT ─────────────────────────────────────────────────
      {
        kind:        "A/B Experiment",
        accent:      "#c084fc",
        key:         "checkout_button",
        what:        "Splits users into variants and measures a metric.",
        # TODO: once shipeasy-sdk is installed
        #   r = Shipeasy.flags.get_experiment(
        #     "checkout_button", { user_id: "u_123" }, { label: "Buy" }
        #   )
        #   @experiment = r
        value:       experiment_pill(in_experiment: true, group: "treatment"),
        call:        %(r = Shipeasy.flags.get_experiment("checkout_button", { user_id: "u_123" }, { label: "Buy" })),
        meta:        %(params: { "color" => "#34d399", "label" => "Buy now" }  ·  in_experiment: true  ·  group: "treatment")
      },

      # 4 ─ KILL SWITCH ────────────────────────────────────────────────────
      {
        kind:        "Kill Switch",
        accent:      "#f87171",
        key:         "payments_paused",
        what:        "An operational off-switch shipped alongside flags — flip it to disable a subsystem during an incident.",
        # TODO: once shipeasy-sdk is installed
        #   boot   = Shipeasy.flags.evaluate({ user_id: "u_123" })
        #   paused = boot["killswitches"]["payments_paused"]
        #   @payments_paused = paused
        value:       killswitch_pill(false),
        call:        %(boot = Shipeasy.flags.evaluate({ user_id: "u_123" })\npaused = boot["killswitches"]["payments_paused"]),
        meta:        "ships in the bootstrap (evaluate) payload"
      },

      # 5 ─ EVENT / METRIC ─────────────────────────────────────────────────
      {
        kind:        "Event / Metric",
        accent:      "#22d3ee",
        key:         "checkout_completed",
        what:        "Fire-and-forget events that power experiment metrics + dashboards.",
        # TODO: once shipeasy-sdk is installed
        #   Shipeasy.flags.track(
        #     "u_123", "checkout_completed", { revenue: 49.99, plan: "pro" }
        #   )
        value:       event_pill("queued"),
        call:        %(Shipeasy.flags.track("u_123", "checkout_completed", { revenue: 49.99, plan: "pro" })),
        meta:        %(last event queued · props: { revenue: 49.99, plan: "pro" })
      },

      # 6 ─ I18N LABEL ─────────────────────────────────────────────────────
      {
        kind:        "i18n Label",
        accent:      "#fbbf24",
        key:         "hero.title",
        what:        "Server-managed copy you translate + publish from the dashboard — no redeploy. (The Ruby SDK exposes Rails view helpers when Rails is loaded.)",
        # TODO: once shipeasy-sdk is installed, in an .erb view:
        #   <%= i18n_t("hero.title", name: "Sam") %>
        #   <%= i18n_head_tags %>   <!-- in <head> -->
        value:       i18n_pill("Ship features, not stress"),
        call:        %(<%= i18n_t("hero.title", name: "Sam") %>\n<%= i18n_head_tags %>  <!-- in <head> -->),
        meta:        "rendered server-side via Rails view helpers"
      },

      # 7 ─ ERROR REPORTING (see) ──────────────────────────────────────────
      {
        kind:        "Error Reporting",
        accent:      "#f87171",
        key:         "see()",
        what:        "Structured error reports that document the product consequence, not just a stack trace.",
        # TODO: once shipeasy-sdk is installed
        #   begin
        #     submit_order(o)
        #   rescue => e
        #     Shipeasy.flags.see(e)
        #             .causes_the("checkout")
        #             .to("use cached prices")
        #             .extras(order_id: o.id)
        #   end
        value:       see_pill("0 issues reported this session"),
        call:        %(begin\n  submit_order(o)\nrescue => e\n  Shipeasy.flags.see(e).causes_the("checkout").to("use cached prices").extras(order_id: o.id)\nend),
        meta:        "report the consequence, not just the stack trace"
      }
    ]
  end

  private

  # ── Placeholder value formatters ──────────────────────────────────────────
  # These exist only so the page reads nicely with hardcoded data. Once the SDK
  # is wired in, the values come from the real calls in the TODO blocks above.

  def flag_pill(_key, on)
    on ? "true" : "false"
  end

  def config_pill(hash)
    hash.map { |k, v| %(#{k}: "#{v}") }.join("  ·  ")
  end

  def experiment_pill(in_experiment:, group:)
    in_experiment ? %(group: "#{group}") : "not enrolled"
  end

  def killswitch_pill(paused)
    paused ? "paused" : "false (payments live)"
  end

  def event_pill(state)
    state
  end

  def i18n_pill(text)
    %("#{text}")
  end

  def see_pill(text)
    text
  end
end
