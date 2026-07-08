require "spec_helper"
require "stringio"

# Contract: the public RUNTIME reads/side-effects never raise into caller code —
# on any internal error they rescue, log, and return the documented safe default.
# Setup/lifecycle calls stay loud (covered elsewhere). Plus the leveled logger
# gated by the `log_level` config option.
RSpec.describe "Fail-safe runtime reads & leveled logging" do
  around do |example|
    # Isolate the module-scoped logger level across examples.
    saved = Shipeasy::Logging.level
    example.run
    Shipeasy::Logging.set_level(saved)
  end

  describe "runtime reads never raise" do
    it "returns the default and does NOT raise when a get_config decode block raises" do
      client = Shipeasy::Engine.for_testing
      client.override_config("theme", { "color" => "red" })
      boom = ->(_v) { raise "decode blew up" }

      result = nil
      expect { result = client.get_config("theme", boom, default: "safe") }.not_to raise_error
      expect(result).to eq("safe")
    end

    it "returns the default when a get_config decode raises on the blob path (no override)" do
      client = Shipeasy::Engine.from_snapshot(
        flags: { "gates" => {}, "configs" => { "theme" => { "value" => { "color" => "red" } } } },
        experiments: { "experiments" => {} },
      )
      boom = ->(_v) { raise "decode blew up" }

      result = nil
      expect { result = client.get_config("theme", boom, default: "fallback") }.not_to raise_error
      expect(result).to eq("fallback")
    end

    it "returns a not-enrolled Assignment (never raises) when the engine assign path blows up" do
      client = Shipeasy::Engine.for_testing
      # Force an internal failure deep in the assign path; safe_run must swallow
      # it and hand back the documented not-enrolled default.
      allow(Shipeasy::SDK::Eval).to receive(:param_defaults_from_schema).and_raise("boom")

      a = nil
      expect { a = client.universe("checkout").assign({ user_id: "u_1" }) }.not_to raise_error
      expect(a.enrolled?).to eq(false)
      expect(a.name).to be_nil
      expect(a.group).to be_nil
    end

    it "guards the bound Client reads too (returns the default, no raise)" do
      Shipeasy.configure_for_testing(configs: { "theme" => { "color" => "red" } })
      client = Shipeasy::Client.new({ "user_id" => "u_1" })
      boom = ->(_v) { raise "decode blew up" }

      result = nil
      expect { result = client.get_config("theme", boom, default: "safe") }.not_to raise_error
      expect(result).to eq("safe")
    ensure
      Shipeasy.reset_config!
    end
  end

  describe "log_level gating" do
    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    it "emits a warn diagnostic at the default :warn level" do
      Shipeasy::Logging.set_level(:warn)
      out = capture_stderr { Shipeasy::Logging.warn("[shipeasy] hello") }
      expect(out).to include("[shipeasy] hello")
    end

    it "mutes everything at :silent" do
      Shipeasy::Logging.set_level(:silent)
      out = capture_stderr do
        Shipeasy::Logging.error("[shipeasy] err")
        Shipeasy::Logging.warn("[shipeasy] warn")
        Shipeasy::Logging.info("[shipeasy] info")
        Shipeasy::Logging.debug("[shipeasy] debug")
      end
      expect(out).to eq("")
    end

    it "suppresses info/debug at the default :warn level but emits error/warn" do
      Shipeasy::Logging.set_level(:warn)
      out = capture_stderr do
        Shipeasy::Logging.error("[shipeasy] err")
        Shipeasy::Logging.warn("[shipeasy] warn")
        Shipeasy::Logging.info("[shipeasy] info")
        Shipeasy::Logging.debug("[shipeasy] debug")
      end
      expect(out).to include("[shipeasy] err")
      expect(out).to include("[shipeasy] warn")
      expect(out).not_to include("[shipeasy] info")
      expect(out).not_to include("[shipeasy] debug")
    end

    it "normalises unknown levels back to :warn and accepts strings" do
      expect(Shipeasy::Logging.normalize("DEBUG")).to eq(:debug)
      expect(Shipeasy::Logging.normalize(:bogus)).to eq(:warn)
      expect(Shipeasy::Logging.normalize(nil)).to eq(:warn)
    end

    it "wires c.log_level from Shipeasy.configure into the logger" do
      Shipeasy.configure { |c| c.api_key = "srv"; c.init = false; c.log_level = :silent }
      expect(Shipeasy::Logging.level).to eq(:silent)
    ensure
      Shipeasy.reset_config!
    end
  end
end
