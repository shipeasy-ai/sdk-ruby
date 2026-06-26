# frozen_string_literal: true

require "spec_helper"

# The OpenFeature provider depends on the optional `openfeature-sdk` gem, which
# requires Ruby >= 3.4. When it (or a compatible Ruby) is unavailable, the
# require below fails and the whole describe block is skipped — the provider
# still ships, just unverified in that environment.
openfeature_available =
  begin
    require "open_feature/sdk"
    require "shipeasy/sdk/openfeature"
    true
  rescue LoadError
    false
  end

RSpec.describe "Shipeasy::OpenFeature::Provider", if: openfeature_available do
  let(:client) { Shipeasy::Engine.for_testing }
  let(:provider) { Shipeasy::OpenFeature::Provider.new(client) }

  def ctx(targeting_key: nil, **attrs)
    fields = attrs
    fields = fields.merge(targeting_key: targeting_key) unless targeting_key.nil?
    OpenFeature::SDK::EvaluationContext.new(**fields)
  end

  # Resolved lazily inside examples (not at describe-body load time) so the
  # constant lookups never fire when openfeature-sdk is absent and the block is
  # only being collected, not run.
  def reason
    OpenFeature::SDK::Provider::Reason
  end

  def error_code
    OpenFeature::SDK::Provider::ErrorCode
  end

  describe "#metadata" do
    it "reports the name shipeasy" do
      expect(provider.metadata.name).to eq("shipeasy")
    end
  end

  describe "#fetch_boolean_value" do
    it "resolves an enabled flag (override) as TARGETING_MATCH" do
      client.override_flag("new_checkout", true)
      res = provider.fetch_boolean_value(
        flag_key: "new_checkout", default_value: false,
        evaluation_context: ctx(targeting_key: "u_1"),
      )
      # An OVERRIDE maps to STATIC per the reason contract.
      expect(res.value).to eq(true)
      expect(res.reason).to eq(reason::STATIC)
      expect(res.error_code).to be_nil
    end

    it "maps a missing flag to ERROR + FLAG_NOT_FOUND, returning the default" do
      res = provider.fetch_boolean_value(
        flag_key: "does_not_exist", default_value: false,
        evaluation_context: ctx(targeting_key: "u_1"),
      )
      expect(res.value).to eq(false)
      expect(res.reason).to eq(reason::ERROR)
      expect(res.error_code).to eq(error_code::FLAG_NOT_FOUND)
    end

    it "maps a not-ready client to ERROR + PROVIDER_NOT_READY" do
      # A live client with no init() and no blob → CLIENT_NOT_READY.
      bare = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      res = Shipeasy::OpenFeature::Provider.new(bare).fetch_boolean_value(
        flag_key: "x", default_value: false, evaluation_context: ctx(targeting_key: "u_1"),
      )
      expect(res.value).to eq(false)
      expect(res.reason).to eq(reason::ERROR)
      expect(res.error_code).to eq(error_code::PROVIDER_NOT_READY)
    end

    it "maps RULE_MATCH to TARGETING_MATCH and DEFAULT to DEFAULT via a snapshot" do
      # A 100%-rolled gate evaluates RULE_MATCH; a 0%-rolled gate DEFAULT.
      flags = {
        "gates" => {
          # rolloutPct is in basis points (10000 = 100%, 0 = 0%).
          "fully_on"  => { "enabled" => true, "rules" => [], "rolloutPct" => 10000, "salt" => "s1" },
          "fully_off" => { "enabled" => true, "rules" => [], "rolloutPct" => 0, "salt" => "s2" },
        },
        "configs" => {},
      }
      snap = Shipeasy::Engine.from_snapshot(flags: flags, experiments: nil)
      p = Shipeasy::OpenFeature::Provider.new(snap)

      on = p.fetch_boolean_value(flag_key: "fully_on", default_value: false,
                                 evaluation_context: ctx(targeting_key: "u_1"))
      expect(on.value).to eq(true)
      expect(on.reason).to eq(reason::TARGETING_MATCH)

      off = p.fetch_boolean_value(flag_key: "fully_off", default_value: false,
                                  evaluation_context: ctx(targeting_key: "u_1"))
      expect(off.value).to eq(false)
      expect(off.reason).to eq(reason::DEFAULT)
    end

    it "builds the user from the targeting key (→ user_id) and attributes" do
      captured = nil
      allow(client).to receive(:get_flag_detail) do |name, user|
        captured = user
        Shipeasy::Engine::FlagDetail.new(value: true, reason: "RULE_MATCH")
      end
      provider.fetch_boolean_value(
        flag_key: "f", default_value: false,
        evaluation_context: ctx(targeting_key: "u_42", plan: "pro"),
      )
      expect(captured["user_id"]).to eq("u_42")
      expect(captured["plan"]).to eq("pro")
      expect(captured).not_to have_key("targeting_key")
    end
  end

  describe "#track" do
    it "forwards to engine#track using targeting_key as user_id" do
      expect(client).to receive(:track).with("u_1", "checkout_completed", { "plan" => "pro" })
      provider.track("checkout_completed",
                     evaluation_context: ctx(targeting_key: "u_1", plan: "pro"))
    end

    it "handles the new OpenFeature TrackingEventDetails object" do
      # Mock the TrackingEventDetails object since we don't have openfeature-sdk loaded here
      details = double("TrackingEventDetails", value: 99.99, fields: { "currency" => "USD" })
      expect(client).to receive(:track).with("u_1", "purchase", { "currency" => "USD", "value" => 99.99 })

      provider.track("purchase",
                     evaluation_context: ctx(targeting_key: "u_1"),
                     tracking_event_details: details)
    end

    it "handles a plain hash as tracking_event_details (backward compatibility / flexibility)" do
      expect(client).to receive(:track).with("u_1", "purchase", { "plan" => "pro" })
      provider.track("purchase",
                     evaluation_context: ctx(targeting_key: "u_1"),
                     tracking_event_details: { "plan" => "pro" })
    end

    it "no-ops when no user_id or targeting_key is present" do
      expect(client).not_to receive(:track)
      provider.track("event", evaluation_context: ctx(plan: "pro"))
    end
  end

  describe "config resolution" do
    it "resolves a string config as TARGETING_MATCH" do
      client.override_config("button_color", "blue")
      res = provider.fetch_string_value(flag_key: "button_color", default_value: "red")
      expect(res.value).to eq("blue")
      expect(res.reason).to eq(reason::TARGETING_MATCH)
    end

    it "resolves an integer config" do
      client.override_config("max_items", 10)
      res = provider.fetch_integer_value(flag_key: "max_items", default_value: 1)
      expect(res.value).to eq(10)
      expect(res.reason).to eq(reason::TARGETING_MATCH)
    end

    it "resolves a float/number config" do
      client.override_config("rate", 0.5)
      expect(provider.fetch_float_value(flag_key: "rate", default_value: 0.0).value).to eq(0.5)
      expect(provider.fetch_number_value(flag_key: "rate", default_value: 0.0).value).to eq(0.5)
    end

    it "resolves an object config" do
      client.override_config("theme", { "bg" => "dark" })
      res = provider.fetch_object_value(flag_key: "theme", default_value: {})
      expect(res.value).to eq({ "bg" => "dark" })
      expect(res.reason).to eq(reason::TARGETING_MATCH)
    end

    it "returns the default with reason DEFAULT when the config is absent" do
      res = provider.fetch_string_value(flag_key: "missing", default_value: "fallback")
      expect(res.value).to eq("fallback")
      expect(res.reason).to eq(reason::DEFAULT)
      expect(res.error_code).to be_nil
    end

    it "returns the default with TYPE_MISMATCH on a wrong-type value" do
      client.override_config("button_color", 123) # number, requested as string
      res = provider.fetch_string_value(flag_key: "button_color", default_value: "red")
      expect(res.value).to eq("red")
      expect(res.reason).to eq(reason::ERROR)
      expect(res.error_code).to eq(error_code::TYPE_MISMATCH)
    end

    it "treats a boolean as a type mismatch for number requests" do
      client.override_config("flagish", true)
      res = provider.fetch_number_value(flag_key: "flagish", default_value: 0)
      expect(res.value).to eq(0)
      expect(res.error_code).to eq(error_code::TYPE_MISMATCH)
    end
  end
end
