require "spec_helper"

# Environment-derived network + telemetry (egress) defaults.
#
# The suite-wide spec_helper sets SHIPEASY_ENV=production so ordinary specs keep
# their real-network behaviour. These tests deliberately override the native env
# vars around each case to exercise the dev/prod branching in isolation.
RSpec.describe "environment-derived egress defaults" do
  # Swap the process env for the block, restoring every touched var after.
  def with_env(vars)
    saved = {}
    vars.each do |k, v|
      saved[k] = ENV[k]
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  # Clear EVERY native var the detector reads, so a case starts from "unset".
  NATIVE = Shipeasy::SDK::Env::NATIVE_ENV_VARS
  def with_clean_env(extra = {})
    with_env(NATIVE.each_with_object({}) { |k, h| h[k] = nil }.merge(extra)) { yield }
  end

  describe "Shipeasy::SDK::Env.is_production_env" do
    it "treats production/prod (case-insensitive) as production via SHIPEASY_ENV" do
      %w[production prod PRODUCTION Prod].each do |val|
        with_clean_env("SHIPEASY_ENV" => val) do
          expect(Shipeasy::SDK::Env.is_production_env("dev")).to be(true)
        end
      end
    end

    it "treats any other present value as NOT production" do
      %w[development staging test qa ci].each do |val|
        with_clean_env("SHIPEASY_ENV" => val) do
          # even with a configured env of prod, a present native var wins
          expect(Shipeasy::SDK::Env.is_production_env("prod")).to be(false)
        end
      end
    end

    it "honours the precedence SHIPEASY_ENV > RAILS_ENV > RACK_ENV > APP_ENV" do
      with_clean_env("RAILS_ENV" => "production", "RACK_ENV" => "development") do
        expect(Shipeasy::SDK::Env.is_production_env).to be(true) # RAILS_ENV wins over RACK_ENV
      end
      with_clean_env("SHIPEASY_ENV" => "development", "RAILS_ENV" => "production") do
        expect(Shipeasy::SDK::Env.is_production_env).to be(false) # SHIPEASY_ENV wins over RAILS_ENV
      end
      with_clean_env("RACK_ENV" => "production") do
        expect(Shipeasy::SDK::Env.is_production_env).to be(true)
      end
      with_clean_env("APP_ENV" => "production") do
        expect(Shipeasy::SDK::Env.is_production_env).to be(true)
      end
    end

    it "falls back to the configured env option when no native var is set" do
      with_clean_env do
        expect(Shipeasy::SDK::Env.is_production_env).to be(true)          # default "prod"
        expect(Shipeasy::SDK::Env.is_production_env("prod")).to be(true)
        expect(Shipeasy::SDK::Env.is_production_env("PROD")).to be(true)
        expect(Shipeasy::SDK::Env.is_production_env("dev")).to be(false)
        expect(Shipeasy::SDK::Env.is_production_env("staging")).to be(false)
      end
    end

    it "ignores an empty/whitespace native var and falls through" do
      with_clean_env("SHIPEASY_ENV" => "  ") do
        expect(Shipeasy::SDK::Env.is_production_env("dev")).to be(false)  # falls to configured env
      end
    end
  end

  describe "the master network switch" do
    # Intercept the two low-level transport calls so a fired request is
    # observable without real network.
    def spy_engine(**opts)
      engine = Shipeasy::Engine.new(api_key: "srv", base_url: "https://e.x", **opts)
      calls = []
      # A 304 response short-circuits fetch_* cleanly (no body parse needed) — we
      # only care THAT the request fired, recorded in +calls+.
      not_modified = instance_double("Net::HTTPNotModified", code: "304")
      allow(not_modified).to receive(:[]).and_return(nil)
      allow(engine).to receive(:http_get) { |path, *| calls << [:get, path]; not_modified }
      allow(engine).to receive(:post)     { |path, *| calls << [:post, path]; nil }
      [engine, calls]
    end

    it "is OFFLINE by default outside production — init makes no request" do
      with_clean_env("SHIPEASY_ENV" => "development") do
        engine, calls = spy_engine
        engine.init_once
        engine.track("u1", "purchase")
        expect(calls).to be_empty
      end
    end

    it "is ON by default in production — init fetches the blobs" do
      with_clean_env("SHIPEASY_ENV" => "production") do
        engine, calls = spy_engine
        engine.init_once
        expect(calls.map(&:last)).to include("/sdk/flags", "/sdk/experiments")
      end
    end

    it "an explicit is_network_enabled: true overrides the dev default (goes online)" do
      with_clean_env("SHIPEASY_ENV" => "development") do
        engine, calls = spy_engine(is_network_enabled: true)
        engine.init_once
        expect(calls.map(&:last)).to include("/sdk/flags", "/sdk/experiments")
      end
    end

    it "an explicit is_network_enabled: false overrides the prod default (stays offline)" do
      with_clean_env("SHIPEASY_ENV" => "production") do
        engine, calls = spy_engine(is_network_enabled: false)
        engine.init_once
        engine.track("u1", "purchase")
        expect(calls).to be_empty
      end
    end

    it "reads still resolve from overrides while offline" do
      with_clean_env("SHIPEASY_ENV" => "development") do
        engine, = spy_engine
        engine.override_flag("new_checkout", true)
        expect(engine.get_flag("new_checkout", {})).to be(true)
      end
    end
  end

  describe "telemetry follows the same environment-derived default" do
    let(:sent) { [] }

    before do
      allow_any_instance_of(Shipeasy::SDK::Telemetry).to receive(:dispatch) { |_, url| sent << url }
    end

    it "fires no beacon in dev even when the network is explicitly enabled" do
      with_clean_env("SHIPEASY_ENV" => "development") do
        engine = Shipeasy::Engine.new(
          api_key: "srv", base_url: "https://e.x", telemetry_url: "https://e.x",
          is_network_enabled: true,
        )
        engine.get_flag("g", {})
        engine.get_config("c")
        expect(sent).to be_empty
      end
    end

    it "fires a beacon in production by default" do
      with_clean_env("SHIPEASY_ENV" => "production") do
        engine = Shipeasy::Engine.new(
          api_key: "srv", base_url: "https://e.x", telemetry_url: "https://e.x",
        )
        engine.get_flag("g", {})
        expect(sent).not_to be_empty
      end
    end

    it "an explicit disable_telemetry: false forces it on even in dev (network on)" do
      with_clean_env("SHIPEASY_ENV" => "development") do
        engine = Shipeasy::Engine.new(
          api_key: "srv", base_url: "https://e.x", telemetry_url: "https://e.x",
          is_network_enabled: true, disable_telemetry: false,
        )
        engine.get_flag("g", {})
        expect(sent).not_to be_empty
      end
    end

    it "the master network switch forces telemetry off regardless of disable_telemetry" do
      with_clean_env("SHIPEASY_ENV" => "production") do
        engine = Shipeasy::Engine.new(
          api_key: "srv", base_url: "https://e.x", telemetry_url: "https://e.x",
          is_network_enabled: false, disable_telemetry: false,
        )
        engine.get_flag("g", {})
        expect(sent).to be_empty
      end
    end
  end
end
