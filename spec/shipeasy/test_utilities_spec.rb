require "spec_helper"

RSpec.describe "Shipeasy::Engine test utilities" do
  describe ".for_testing" do
    it "builds a usable client without a key, network, or init" do
      client = Shipeasy::Engine.for_testing
      # No init/fetch, no overrides set: a missing gate is simply off, with no
      # network call (the suite would hang/raise on a real HTTP attempt).
      expect(client.get_flag("anything", { user_id: "u_1" })).to eq(false)
      expect(client.get_config("anything")).to be_nil
    end

    it "treats init and init_once as no-ops (never fetches)" do
      client = Shipeasy::Engine.for_testing
      expect(client.init).to be_nil
      expect(client.init_once).to be_nil
      # Still answers from overrides only.
      client.override_flag("on", true)
      expect(client.get_flag("on", {})).to eq(true)
    end

    it "makes track a no-op (no thread, no network)" do
      client = Shipeasy::Engine.for_testing
      expect(Thread).not_to receive(:new)
      expect(client.track("u_1", "checkout_completed", { revenue: 49.99 })).to be_nil
    end
  end

  describe "#override_flag" do
    it "returns the overridden boolean from get_flag" do
      client = Shipeasy::Engine.for_testing
      client.override_flag("new_checkout", true)
      expect(client.get_flag("new_checkout", { user_id: "u_1" })).to eq(true)

      client.override_flag("new_checkout", false)
      expect(client.get_flag("new_checkout", { user_id: "u_1" })).to eq(false)
    end

    it "coerces truthy/falsey values to a boolean" do
      client = Shipeasy::Engine.for_testing
      client.override_flag("a", "yes")
      client.override_flag("b", nil)
      expect(client.get_flag("a", {})).to eq(true)
      expect(client.get_flag("b", {})).to eq(false)
    end
  end

  describe "#override_config" do
    it "returns the overridden value from get_config" do
      client = Shipeasy::Engine.for_testing
      client.override_config("button_color", "blue")
      expect(client.get_config("button_color")).to eq("blue")
    end

    it "honors a decode proc on the overridden value" do
      client = Shipeasy::Engine.for_testing
      client.override_config("limits", { "max" => 10 })
      decoded = client.get_config("limits", ->(v) { v["max"] * 2 })
      expect(decoded).to eq(20)
    end
  end

  describe "#override_experiment" do
    # An override surfaces through assign() when the experiment exists (mapped to
    # its universe) in the loaded blob — the override still wins its classify.
    def client_with_running_exp
      client = Shipeasy::Engine.for_testing
      client.send(:load_snapshot, {}, {
        "universes" => { "checkout" => {} },
        "experiments" => {
          "checkout_cta" => {
            "universe" => "checkout", "status" => "running", "salt" => "s",
            "allocationPct" => 10000,
            "groups" => [{ "name" => "control", "weight" => 10000, "params" => {} }],
          },
        },
      })
      client
    end

    it "returns an in-experiment Assignment from universe().assign" do
      client = client_with_running_exp
      client.override_experiment("checkout_cta", "treatment", { label: "Buy now" })

      a = client.universe("checkout").assign({ user_id: "u_1" })
      expect(a).to be_a(Shipeasy::SDK::Eval::Assignment)
      expect(a.enrolled?).to eq(true)
      expect(a.name).to eq("checkout_cta")
      expect(a.group).to eq("treatment")
      expect(a.get("label")).to eq("Buy now")
    end
  end

  describe "#clear_overrides" do
    it "resets all overrides" do
      client = Shipeasy::Engine.for_testing
      client.send(:load_snapshot, {}, {
        "universes" => { "u" => {} },
        "experiments" => {
          "e" => {
            "universe" => "u", "status" => "running", "salt" => "s",
            "allocationPct" => 0,
            "groups" => [{ "name" => "treatment", "weight" => 10000, "params" => { "a" => 1 } }],
          },
        },
      })
      client.override_flag("f", true)
      client.override_config("c", "x")
      client.override_experiment("e", "treatment", { a: 1 })

      client.clear_overrides

      expect(client.get_flag("f", {})).to eq(false)
      expect(client.get_config("c")).to be_nil
      # override gone → the experiment's real (0% allocation) classify runs → not enrolled
      a = client.universe("u").assign({ user_id: "u_1" })
      expect(a.enrolled?).to eq(false)
    end
  end

  describe "overrides on a normal client" do
    it "wins over the fetched blob without any network access" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      client.override_flag("g", true)
      # No init() called, so no blob fetched; the override answers directly.
      expect(client.get_flag("g", { user_id: "u_1" })).to eq(true)
    end
  end
end
