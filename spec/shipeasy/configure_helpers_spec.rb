require "spec_helper"

# Specs for the package-level configure() family + helpers (doc 23 §1):
# configure_for_testing / configure_for_offline (replace-not-first-wins),
# configure(poll:), the package-level override_* / clear_overrides / on_change /
# SSR-tag / see helpers — all delegating to the global engine so callers never
# name the Engine.
RSpec.describe "Shipeasy package-level configure family" do
  before { Shipeasy.reset_config! }
  after  { Shipeasy.reset_config! }

  describe ".configure_for_testing" do
    it "seeds flags/configs/experiments read through a bound Client (no network)" do
      Shipeasy.configure_for_testing(
        flags:       { "new_checkout" => true },
        configs:     { "billing_copy" => { "title" => "Welcome" } },
        experiments: { "checkout_button" => ["treatment", { "color" => "green" }] },
      )

      client = Shipeasy::Client.new("user_id" => "u_1")
      expect(client.get_flag("new_checkout")).to be(true)
      expect(client.get_config("billing_copy")).to eq("title" => "Welcome")

      r = client.get_experiment("checkout_button", { "color" => "blue" })
      expect(r.in_experiment).to be(true)
      expect(r.group).to eq("treatment")
      expect(r.params).to eq("color" => "green")
    end

    it "is no-network: track / log_exposure are no-ops in test mode" do
      Shipeasy.configure_for_testing(flags: {})
      client = Shipeasy::Client.new("user_id" => "u_1")
      expect(Thread).not_to receive(:new)
      expect(client.track("purchase", { "amount" => 49 })).to be_nil
      expect(client.log_exposure("checkout_button")).to be_nil
    end

    it "REPLACES the prior config (unlike first-config-wins configure)" do
      Shipeasy.configure_for_testing(flags: { "f" => true })
      expect(Shipeasy::Client.new("user_id" => "u").get_flag("f")).to be(true)

      Shipeasy.configure_for_testing(flags: { "f" => false })
      expect(Shipeasy::Client.new("user_id" => "u").get_flag("f")).to be(false)
    end

    it "applies the attributes transform" do
      Shipeasy.configure_for_testing(
        flags:      { "g" => true },
        attributes: ->(u) { { "user_id" => u[:id] } },
      )
      client = Shipeasy::Client.new(id: "abc")
      expect(client.attributes).to include("user_id" => "abc")
    end
  end

  describe ".configure_for_offline" do
    let(:snapshot) do
      {
        "flags" => {
          "gates" => {
            "new_checkout" => { "enabled" => true, "rolloutPct" => 10_000, "salt" => "new_checkout", "rules" => [] },
            "beta_banner"  => { "enabled" => false, "rolloutPct" => 0, "salt" => "beta_banner", "rules" => [] },
          },
          "configs" => { "billing_copy" => { "value" => { "cta" => "Upgrade" } } },
          "killswitches" => {
            "payments_circuit_breaker" => { "killed" => false, "switches" => { "stripe" => true, "paypal" => false } },
          },
        },
        "experiments" => { "experiments" => {}, "universes" => {} },
      }
    end

    it "evaluates the REAL rules from an in-memory snapshot" do
      Shipeasy.configure_for_offline(snapshot: snapshot)
      c = Shipeasy::Client.new("user_id" => "u_1")

      expect(c.get_flag("new_checkout")).to be(true)   # 100% rollout
      expect(c.get_flag("beta_banner")).to be(false)   # 0% rollout
      expect(c.get_config("billing_copy")).to eq("cta" => "Upgrade")
    end

    it "honours named killswitches and falls back to the top-level value" do
      Shipeasy.configure_for_offline(snapshot: snapshot)
      c = Shipeasy::Client.new("user_id" => "u_1")

      expect(c.get_killswitch("payments_circuit_breaker")).to be(false)          # top-level
      expect(c.get_killswitch("payments_circuit_breaker", "stripe")).to be(true) # named
      expect(c.get_killswitch("payments_circuit_breaker", "paypal")).to be(false)
      expect(c.get_killswitch("payments_circuit_breaker", "other")).to be(false) # falls back
    end

    it "layers overrides on top of the snapshot" do
      Shipeasy.configure_for_offline(snapshot: snapshot, flags: { "new_checkout" => false })
      expect(Shipeasy::Client.new("user_id" => "u_1").get_flag("new_checkout")).to be(false)
    end

    it "loads from a JSON file via path:" do
      require "json"
      require "tempfile"
      file = Tempfile.new(["snapshot", ".json"])
      file.write(JSON.generate(snapshot))
      file.flush
      Shipeasy.configure_for_offline(path: file.path)
      expect(Shipeasy::Client.new("user_id" => "u_1").get_flag("new_checkout")).to be(true)
    ensure
      file&.close!
    end

    it "raises without a source" do
      expect { Shipeasy.configure_for_offline }.to raise_error(Shipeasy::Error, /snapshot.*path/)
    end
  end

  describe "package-level override helpers" do
    it "flip values on the spot and clear_overrides drops the seed in test mode" do
      Shipeasy.configure_for_testing(flags: { "new_checkout" => true })

      Shipeasy.override_flag("new_checkout", false)
      Shipeasy.override_config("billing_copy", { "title" => "B" })
      Shipeasy.override_experiment("checkout_button", "control", { "color" => "blue" })

      c = Shipeasy::Client.new("user_id" => "u_1")
      expect(c.get_flag("new_checkout")).to be(false)
      expect(c.get_config("billing_copy")).to eq("title" => "B")
      expect(c.get_experiment("checkout_button", {}).group).to eq("control")

      Shipeasy.clear_overrides
      # test mode has no blob underneath → the seed is gone too
      expect(Shipeasy::Client.new("user_id" => "u_1").get_flag("new_checkout")).to be(false)
    end

    it "raise a helpful error before any configure*" do
      expect { Shipeasy.override_flag("a", true) }
        .to raise_error(Shipeasy::Error, /override_flag.*configure/m)
      expect { Shipeasy.clear_overrides }
        .to raise_error(Shipeasy::Error, /clear_overrides.*configure/m)
    end
  end

  describe "package-level SSR tag helpers" do
    before { Shipeasy.configure_for_testing(flags: {}) }

    it "i18n_script_tag carries the public client key" do
      tag = Shipeasy.i18n_script_tag("sdk_client_abc", profile: "en:prod")
      expect(tag).to include("sdk_client_abc")
      expect(tag).to include("i18n/loader.js")
    end

    it "bootstrap_script_tag embeds no key" do
      tag = Shipeasy.bootstrap_script_tag({ "user_id" => "u_1" })
      expect(tag).to include("data-se-bootstrap")
      expect(tag).not_to include("sdk_server")
    end
  end

  describe "package-level see()" do
    it "is a no-op chain in test mode (never sends)" do
      Shipeasy.configure_for_testing(flags: {})
      expect(Thread).not_to receive(:new)
      Shipeasy.see(StandardError.new("boom")).causes_the("checkout").to("fallback")
      Shipeasy.see_violation("bad_state").causes_the("x").to("y")
    end

    it "delegates to the module-level facade (last-constructed client)" do
      Shipeasy.configure_for_testing(flags: {})
      expect(Shipeasy::SDK).to receive(:see).with(an_instance_of(StandardError))
      Shipeasy.see(StandardError.new("boom"))
    end
  end

  describe "configure(poll:)" do
    it "starts the background poll (engine.init), not the one-shot fetch" do
      expect_any_instance_of(Shipeasy::Engine).to receive(:init)
      expect_any_instance_of(Shipeasy::Engine).not_to receive(:init_once)
      Shipeasy.configure { |c| c.api_key = "srv_key"; c.poll = true }
      # let the fire-and-forget thread run
      sleep 0.05
    end

    it "default does the one-shot fetch (engine.init_once)" do
      expect_any_instance_of(Shipeasy::Engine).to receive(:init_once)
      expect_any_instance_of(Shipeasy::Engine).not_to receive(:init)
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      sleep 0.05
    end
  end

  describe "configure() advanced options" do
    it "threads env / private_attributes / sticky_store into the global engine" do
      allow_any_instance_of(Shipeasy::Engine).to receive(:init_once).and_return(nil)
      store = Shipeasy::SDK::InMemoryStickyStore.new
      Shipeasy.configure do |c|
        c.api_key            = "srv_key"
        c.env                = "staging"
        c.private_attributes = ["email"]
        c.sticky_store       = store
      end
      engine = Shipeasy.engine
      expect(engine.instance_variable_get(:@env)).to eq("staging")
      expect(engine.instance_variable_get(:@private_attributes)).to eq(["email"])
      expect(engine.instance_variable_get(:@sticky_store)).to equal(store)
    end
  end
end
