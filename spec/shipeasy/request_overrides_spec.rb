require "spec_helper"
require "rack"

# Signed DevTools override cookie (`se_ov`) on server reads — shipeasy ops #714.
# The fixture strings are the cross-impl vectors shared with sdk-ts / core.
RSpec.describe "request-scoped signed overrides" do
  OV_KEY    = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA".freeze
  OV_KEY_ID = "k1".freeze
  OV_COOKIE = "eyJ2IjoxLCJwaWQiOiJwcm9qX2ZpeHR1cmUiLCJrZXlJZCI6ImsxIiwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIiwiZXhwIjo0MTAyNDQ0ODAwLCJvdiI6eyJnYXRlcyI6eyJsb2JieV9ob2xkIjp0cnVlLCJvbGRfbmF2IjpmYWxzZX0sImNvbmZpZ3MiOnsiYmFubmVyIjp7InRleHQiOiJoaSJ9fSwiZXhwcyI6eyJjaGVja291dF9leHAiOiJ0cmVhdG1lbnQifX19.8qd-pHu1e96Th-jcu4BZOhLmZjwhKrgn-uI8IWBr5Og".freeze
  OV_EXPIRED = "eyJ2IjoxLCJwaWQiOiJwcm9qX2ZpeHR1cmUiLCJrZXlJZCI6ImsxIiwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIiwiZXhwIjoxMDAwLCJvdiI6eyJnYXRlcyI6eyJsb2JieV9ob2xkIjp0cnVlLCJvbGRfbmF2IjpmYWxzZX0sImNvbmZpZ3MiOnsiYmFubmVyIjp7InRleHQiOiJoaSJ9fSwiZXhwcyI6eyJjaGVja291dF9leHAiOiJ0cmVhdG1lbnQifX19.fZEp7eGjZSdi5EvTB-5NZLbZpVXbcWbIaEYRmPvPbd8".freeze
  OV_TAMPERED = "eyJ2IjoxLCJwaWQiOiJwcm9qX2ZpeHR1cmUiLCJrZXlJZCI6ImsxIiwibm9uY2UiOiJmaXh0dXJlLW5vbmNlIiwiZXhwIjo0MTAyNDQ0ODAwLCJvdiI6eyJnYXRlcyI6eyJsb2JieV9ob2xkIjp0cnVlLCJvbGRfbmF2IjpmYWxzZX0sImNvbmZpZ3MiOnsiYmFubmVyIjp7InRleHQiOiJoaSJ9fSwiZXhwcyI6eyJjaGVja291dF9leHAiOiJ0cmVhdG1lbnQifX19.8qd-pHu1e96Th-jcu4BZOhLmZjwhKrgn-uI8IWBr5AA".freeze

  let(:verifier) { Shipeasy::SDK::OverrideCookie }
  let(:user)     { { "user_id" => "u_1" } }

  def flags_blob(with_key: true)
    blob = {
      "gates" => {
        "lobby_hold" => { "enabled" => true, "rolloutPct" => 0, "salt" => "lobby_hold", "rules" => [] },
        "old_nav"    => { "enabled" => true, "rolloutPct" => 10_000, "salt" => "old_nav", "rules" => [] },
      },
      "configs" => { "banner" => { "value" => { "text" => "orig" } } },
      "killswitches" => { "ks_checkout" => { "killed" => false } },
    }
    if with_key
      blob["overrideKey"]   = OV_KEY
      blob["overrideKeyId"] = OV_KEY_ID
    end
    blob
  end

  def exps_blob
    {
      "universes" => { "checkout" => { "param_schema" => [{ "name" => "cta", "type" => "string", "default" => "Buy" }] } },
      "experiments" => {
        "checkout_exp" => {
          "universe" => "checkout", "status" => "running", "allocationPct" => 0, "salt" => "c",
          "groups" => [
            { "name" => "control", "weight" => 5000, "params" => {} },
            { "name" => "treatment", "weight" => 5000, "params" => { "cta" => "Go" } },
          ],
        },
      },
    }
  end

  before { Shipeasy.reset_config! }
  after  { Shipeasy.reset_config! }

  describe Shipeasy::SDK::OverrideCookie do
    it "verifies the cross-impl fixture" do
      ov = verifier.verify(OV_COOKIE, OV_KEY, OV_KEY_ID)
      expect(ov["gates"]).to eq("lobby_hold" => true, "old_nav" => false)
      expect(ov["configs"]).to eq("banner" => { "text" => "hi" })
      expect(ov["exps"]).to eq("checkout_exp" => "treatment")
    end

    it "rejects expired, tampered, wrong keyId, wrong key and missing key" do
      expect(verifier.verify(OV_EXPIRED, OV_KEY, OV_KEY_ID)).to be_nil
      expect(verifier.verify(OV_TAMPERED, OV_KEY, OV_KEY_ID)).to be_nil
      expect(verifier.verify(OV_COOKIE, OV_KEY, "k2")).to be_nil
      expect(verifier.verify(OV_COOKIE, verifier.b64u_encode("x" * 32), OV_KEY_ID)).to be_nil
      expect(verifier.verify(OV_COOKIE, nil, OV_KEY_ID)).to be_nil
      expect(verifier.verify(OV_COOKIE, OV_KEY, nil)).to be_nil
    end

    it "rejects malformed values without raising" do
      ["", "nodot", ".sig", "a.b.c", "!!!.???", "e30.e30"].each do |bad|
        expect(verifier.verify(bad, OV_KEY, OV_KEY_ID)).to be_nil
      end
    end

    it "honours now: for expiry" do
      expect(verifier.verify(OV_COOKIE, OV_KEY, OV_KEY_ID, now: 4_102_444_800)).to be_nil
      expect(verifier.verify(OV_COOKIE, OV_KEY, OV_KEY_ID, now: 4_102_444_799)).not_to be_nil
    end

    it "extracts a bare value or a Cookie header, URL-decoding" do
      expect(verifier.extract(OV_COOKIE)).to eq(OV_COOKIE)
      expect(verifier.extract("a=1; se_ov=#{OV_COOKIE}; b=2")).to eq(OV_COOKIE)
      expect(verifier.extract("se_ov=a%2Eb")).to eq("a.b")
      expect(verifier.extract("a=1; b=2")).to be_nil
      expect(verifier.extract("nodot")).to be_nil
      # an unrelated single cookie is a header, not a bare value
      expect(verifier.extract("theme=a.b")).to be_nil
      expect(verifier.extract("theme=a.b", "se_ov_dev")).to be_nil
      expect(verifier.extract(nil)).to be_nil
      expect(verifier.extract("")).to be_nil
    end
  end

  context "with an engine that was served an override key" do
    before do
      Shipeasy.configure_for_offline(snapshot: { "flags" => flags_blob, "experiments" => exps_blob })
    end

    let(:header) { "a=1; se_ov=#{OV_COOKIE}" }

    it "is a no-op outside a request scope" do
      c = Shipeasy::Client.new(user)
      expect(c.get_flag("lobby_hold")).to be(false)
      expect(c.get_flag_detail("old_nav").reason).to eq("RULE_MATCH")
      expect(Shipeasy::SDK::RequestOverrides.current).to be_nil
    end

    it "overrides gates, configs, kill switches and experiments inside with_request_overrides, then clears" do
      Shipeasy.with_request_overrides(header) do
        c = Shipeasy::Client.new(user)
        expect(c.get_flag("lobby_hold")).to be(true)
        detail = c.get_flag_detail("lobby_hold")
        expect(detail.value).to be(true)
        expect(detail.reason).to eq("OVERRIDE")
        expect(c.get_flag("old_nav")).to be(false)
        expect(c.get_config("banner")).to eq("text" => "hi")
        expect(c.get_config("banner", ->(v) { v["text"].upcase })).to eq("HI")
        a = c.universe("checkout").assign
        expect(a.group).to eq("treatment")
        expect(a.get("cta")).to eq("Go")
      end
      c = Shipeasy::Client.new(user)
      expect(c.get_flag("lobby_hold")).to be(false)
      expect(c.get_flag("old_nav")).to be(true)
      expect(c.get_config("banner")).to eq("text" => "orig")
      expect(Shipeasy::SDK::RequestOverrides.current).to be_nil
    end

    it "applies gate overrides to whole kill switches only" do
      cookie_ov = { "gates" => { "ks_checkout" => true }, "configs" => {}, "exps" => {} }
      Shipeasy::SDK::RequestOverrides.scope(cookie_ov) do
        c = Shipeasy::Client.new(user)
        expect(c.get_killswitch("ks_checkout")).to be(true)
        expect(c.get_killswitch("ks_checkout", "some_key")).to be(false)
      end
      expect(Shipeasy::Client.new(user).get_killswitch("ks_checkout")).to be(false)
    end

    it "lets a programmatic override beat the signed cookie" do
      Shipeasy.override_flag("lobby_hold", false)
      Shipeasy.override_config("banner", { "text" => "prog" })
      Shipeasy.with_request_overrides(header) do
        c = Shipeasy::Client.new(user)
        expect(c.get_flag("lobby_hold")).to be(false)
        expect(c.get_config("banner")).to eq("text" => "prog")
      end
    end

    it "returns the block value and clears even when the block raises" do
      expect(Shipeasy.with_request_overrides(header) { 42 }).to eq(42)
      expect { Shipeasy.with_request_overrides(header) { raise "boom" } }.to raise_error("boom")
      expect(Shipeasy::SDK::RequestOverrides.current).to be_nil
    end

    it "ignores bad cookies" do
      [OV_EXPIRED, OV_TAMPERED, "garbage"].each do |bad|
        Shipeasy.with_request_overrides("se_ov=#{bad}") do
          expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
        end
      end
    end

    it "does not bleed between concurrent requests" do
      ready = Queue.new
      go    = Queue.new
      other = nil
      t = Thread.new do
        ready << true
        go.pop
        other = Shipeasy::SDK::RequestOverrides.current
      end
      ready.pop
      Shipeasy.with_request_overrides(header) { go << true; t.join }
      expect(other).to be_nil
    end

    it "is visible inside child fibers (e.g. GraphQL::Dataloader)", if: Shipeasy::SDK::RequestOverrides::FIBER_STORAGE do
      Shipeasy.with_request_overrides(header) do
        flag = Fiber.new { Shipeasy::Client.new(user).get_flag("lobby_hold") }.resume
        expect(flag).to be(true)
      end
    end

    describe Shipeasy::SDK::RackMiddleware do
      def run(cookie, app_seen)
        app = lambda do |_env|
          app_seen[:flag]  = Shipeasy::Client.new(user).get_flag("lobby_hold")
          app_seen[:inner] = Shipeasy::SDK::RequestOverrides.current
          [200, {}, ["ok"]]
        end
        env = cookie ? { "HTTP_COOKIE" => cookie } : {}
        described_class.new(app).call(env)
      end

      it "scopes the verified overrides to the request and clears afterwards" do
        seen = {}
        run("__se_anon_id=abc; se_ov=#{OV_COOKIE}", seen)
        expect(seen[:flag]).to be(true)
        expect(seen[:inner]["gates"]).to include("lobby_hold" => true)
        expect(Shipeasy::SDK::RequestOverrides.current).to be_nil
      end

      it "clears when the app raises" do
        app = ->(_env) { raise "kaboom" }
        env = { "HTTP_COOKIE" => "se_ov=#{OV_COOKIE}" }
        expect { described_class.new(app).call(env) }.to raise_error("kaboom")
        expect(Shipeasy::SDK::RequestOverrides.current).to be_nil
      end

      it "does nothing without a cookie or with a tampered one" do
        seen = {}
        run(nil, seen)
        expect(seen[:flag]).to be(false)
        expect(seen[:inner]).to be_nil
        run("se_ov=#{OV_TAMPERED}", seen)
        expect(seen[:flag]).to be(false)
      end
    end
  end

  context "when the platform served no override key (fail closed)" do
    it "never trusts the cookie" do
      Shipeasy.configure_for_offline(snapshot: { "flags" => flags_blob(with_key: false), "experiments" => exps_blob })
      Shipeasy.with_request_overrides("se_ov=#{OV_COOKIE}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
    end
  end

  describe "unsigned se_ov_dev cookie (dev_overrides)" do
    DEV_COOKIE = "eyJnYXRlcyI6eyJsb2JieV9ob2xkIjp0cnVlLCJvbGRfbmF2IjpmYWxzZX0sImNvbmZpZ3MiOnsiYmFubmVyIjp7InRleHQiOiJoaSJ9fSwiZXhwcyI6eyJjaGVja291dF9leHAiOiJ0cmVhdG1lbnQifX0".freeze
    let(:dev_header) { "a=1; se_ov_dev=#{DEV_COOKIE}" }

    it "decodes the cross-impl vector, bare or in a (URL-encoded) Cookie header" do
      ov = verifier.decode_dev(DEV_COOKIE)
      expect(ov["gates"]).to eq("lobby_hold" => true, "old_nav" => false)
      expect(ov["configs"]).to eq("banner" => { "text" => "hi" })
      expect(ov["exps"]).to eq("checkout_exp" => "treatment")
      expect(verifier.extract(dev_header, "se_ov_dev")).to eq(DEV_COOKIE)
      expect(verifier.extract(DEV_COOKIE, "se_ov_dev")).to eq(DEV_COOKIE)
      expect(verifier.extract("se_ov_dev=#{DEV_COOKIE.sub("eyJn", "eyJn")}", "se_ov_dev")).to eq(DEV_COOKIE)
      expect(verifier.decode_dev("!!!")).to be_nil
      expect(verifier.decode_dev(verifier.b64u_encode("[1]"))).to be_nil
    end

    def configure_offline(dev)
      Shipeasy.config.dev_overrides = dev
      Shipeasy.configure_for_offline(snapshot: { "flags" => flags_blob, "experiments" => exps_blob })
    end

    it "is ignored when the option is off" do
      configure_offline(false)
      Shipeasy.with_request_overrides(dev_header) do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
    end

    it "is honored with the option on in a non-production (test-mode) engine" do
      configure_offline(true)
      Shipeasy.with_request_overrides(dev_header) do
        c = Shipeasy::Client.new(user)
        expect(c.get_flag_detail("lobby_hold").reason).to eq("OVERRIDE")
        expect(c.get_flag("lobby_hold")).to be(true)
        expect(c.get_flag("old_nav")).to be(false)
        expect(c.get_config("banner")).to eq("text" => "hi")
        expect(c.universe("checkout").assign.group).to eq("treatment")
      end
      expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
    end

    it "is honored through the Rack middleware" do
      configure_offline(true)
      seen = nil
      app = ->(_e) { seen = Shipeasy::Client.new(user).get_flag("lobby_hold"); [200, {}, []] }
      Shipeasy::SDK::RackMiddleware.new(app).call("HTTP_COOKIE" => "se_ov_dev=#{DEV_COOKIE}")
      expect(seen).to be(true)
    end

    it "is ignored (with one warning) in a production process" do
      allow(Shipeasy::Logging).to receive(:warn)
      Shipeasy.configure do |c|
        c.api_key = "k"
        c.init = false
        c.is_network_enabled = false
        c.dev_overrides = true
      end
      expect(Shipeasy.engine.dev_overrides_active?).to be(false)
      Shipeasy.with_request_overrides(dev_header) do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
      expect(Shipeasy::Logging).to have_received(:warn).with(/dev_overrides.*production/).once
    end

    it "is active on a non-production process with the option" do
      old = ENV["SHIPEASY_ENV"]
      ENV["SHIPEASY_ENV"] = "development"
      Shipeasy.configure do |c|
        c.api_key = "k"
        c.init = false
        c.dev_overrides = true
      end
      expect(Shipeasy.engine.dev_overrides_active?).to be(true)
      Shipeasy.override_flag("old_nav", false)
      Shipeasy.with_request_overrides(dev_header) do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(true)
      end
    ensure
      ENV["SHIPEASY_ENV"] = old
    end

    it "lets the signed cookie beat the dev cookie per name, and programmatic beat both" do
      configure_offline(true)
      dev = verifier.b64u_encode('{"gates":{"lobby_hold":false,"extra":true}}')
      Shipeasy.with_request_overrides("se_ov=#{OV_COOKIE}; se_ov_dev=#{dev}") do
        c = Shipeasy::Client.new(user)
        expect(c.get_flag("lobby_hold")).to be(true)  # signed true beats dev false
        expect(c.get_flag_detail("extra").value).to be(true) # dev-only name still applies
      end
      Shipeasy.override_flag("lobby_hold", false)
      Shipeasy.with_request_overrides("se_ov=#{OV_COOKIE}; se_ov_dev=#{DEV_COOKIE}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
    end
  end

  describe "X-Shipeasy-Overrides header fallback" do
    let(:dev_value) { "eyJnYXRlcyI6eyJsb2JieV9ob2xkIjp0cnVlLCJvbGRfbmF2IjpmYWxzZX0sImNvbmZpZ3MiOnsiYmFubmVyIjp7InRleHQiOiJoaSJ9fSwiZXhwcyI6eyJjaGVja291dF9leHAiOiJ0cmVhdG1lbnQifX0" }

    def setup_engine(dev)
      Shipeasy.config.dev_overrides = dev
      Shipeasy.configure_for_offline(snapshot: { "flags" => flags_blob, "experiments" => exps_blob })
    end

    it "applies a header-only signed cookie (scope helper and Rack)" do
      setup_engine(false)
      Shipeasy.with_request_overrides(nil, overrides_header: "se_ov=#{OV_COOKIE}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(true)
      end
      seen = nil
      app = ->(_e) { seen = Shipeasy::Client.new(user).get_flag("lobby_hold"); [200, {}, []] }
      Shipeasy::SDK::RackMiddleware.new(app).call("HTTP_X_SHIPEASY_OVERRIDES" => "se_ov=#{OV_COOKIE}")
      expect(seen).to be(true)
    end

    it "falls back to the header when the Cookie header holds only an unrelated cookie" do
      setup_engine(false)
      Shipeasy.with_request_overrides("theme=a.b", overrides_header: "se_ov=#{OV_COOKIE}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(true)
      end
    end

    it "rejects a tampered header-only signed cookie" do
      setup_engine(false)
      Shipeasy.with_request_overrides(nil, overrides_header: "se_ov=#{OV_TAMPERED}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
    end

    it "applies a header-only dev cookie only under the guards" do
      hdr = "se_ov_dev=#{dev_value}"
      setup_engine(false)
      Shipeasy.with_request_overrides(nil, overrides_header: hdr) do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
      setup_engine(true)
      Shipeasy.with_request_overrides(nil, overrides_header: hdr) do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(true)
      end
    end

    it "never parses the header's dev cookie when the guard is off" do
      setup_engine(false)
      expect(Shipeasy::SDK::OverrideCookie).not_to receive(:decode_dev)
      Shipeasy.with_request_overrides(nil, overrides_header: "se_ov_dev=#{dev_value}") { :x }
    end

    it "lets the Cookie header beat the custom header for the same name" do
      setup_engine(true)
      cookie_dev = verifier.b64u_encode('{"gates":{"lobby_hold":false}}')
      Shipeasy.with_request_overrides("se_ov_dev=#{cookie_dev}", overrides_header: "se_ov_dev=#{dev_value}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(false)
      end
      # different names: each source fills what the other lacks
      Shipeasy.with_request_overrides("se_ov_dev=#{cookie_dev}", overrides_header: "se_ov=#{OV_COOKIE}") do
        expect(Shipeasy::Client.new(user).get_flag("lobby_hold")).to be(true) # signed beats dev
      end
    end
  end

  it "just yields when no engine is configured" do
    expect(Shipeasy.with_request_overrides("se_ov=#{OV_COOKIE}") { :ok }).to eq(:ok)
  end

  it "is mounted by the Railtie that already inserts RackMiddleware" do
    src = File.read(File.expand_path("../../lib/shipeasy/sdk/railtie.rb", __dir__))
    expect(src).to include("Shipeasy::SDK::RackMiddleware")
  end
end
