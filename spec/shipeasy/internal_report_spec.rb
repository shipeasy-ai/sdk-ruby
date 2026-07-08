require "spec_helper"

# Self-monitoring channel: when the SDK swallows an internal ("on our end")
# error via Engine#safe_run, it also ships a structured see event to Shipeasy's
# OWN project — a baked-in destination + public client key, distinct from the
# consumer's see() path. These specs pin the wire shape, the enable gating, the
# dedup, and the no-raise guarantee.
RSpec.describe "Shipeasy::SDK::InternalReport" do
  IR = Shipeasy::SDK::InternalReport

  # A real-looking client key to exercise the send path (the baked default is an
  # inert placeholder until the real key is minted).
  FAKE_KEY = "sdk_client_testfakekey00000000000000000000".freeze

  # Capture the POSTs the channel would make. The channel posts inside a
  # Thread.new via Net::HTTP; we stub `send_event` (the isolated transport) to
  # record the key + parsed body synchronously so assertions are deterministic.
  def capture_sends
    sends = []
    allow(IR).to receive(:send_event) do |key, body|
      sends << { key: key, body: JSON.parse(body) }
      nil
    end
    yield
    sends
  end

  def events(sends)
    sends.flat_map { |s| s[:body]["events"] }
  end

  before do
    IR.reset_for_test!
    IR.set_ingest_key_for_test(FAKE_KEY)
  end

  after do
    IR.reset_for_test!
  end

  describe "destination + wire shape" do
    it "posts to the baked-in Shipeasy ingest with the public client key" do
      IR.set_context(side: "server", sdk_version: "9.9.9")
      sends = capture_sends { IR.report("flags.get", TypeError.new("cannot read foo")) }

      expect(sends.length).to eq(1)
      expect(sends[0][:key]).to eq(FAKE_KEY)
      # The baked-in destination is the api.shipeasy.ai /collect ingest.
      expect(IR::INGEST_URL).to eq("https://api.shipeasy.ai/collect")
    end

    it "builds a stable consequence: subject=label, fixed outcome, sdk marker" do
      IR.set_context(side: "server", sdk_version: "9.9.9")
      sends = capture_sends { IR.report("Client.getExperiment", RuntimeError.new("boom")) }

      ev = events(sends).first
      expect(ev["type"]).to eq("error")
      expect(ev["kind"]).to eq("caught")
      expect(ev["subject"]).to eq("Client.getExperiment")
      expect(ev["outcome"]).to eq("returned a safe default")
      expect(ev["error_type"]).to eq("RuntimeError")
      expect(ev["message"]).to eq("boom")
      expect(ev["side"]).to eq("server")
      expect(ev["sdk_version"]).to eq("9.9.9")
      expect(ev["extras"]["sdk"]).to eq("ruby")
    end

    it "does NOT attach a consumer env or url (only the SDK-side context)" do
      IR.set_context(side: "server", sdk_version: "9.9.9")
      sends = capture_sends { IR.report("flags.ks", RuntimeError.new("x")) }

      ev = events(sends).first
      expect(ev).not_to have_key("env")
      expect(ev).not_to have_key("url")
    end
  end

  describe "enable gating" do
    it "is a no-op before a context is set" do
      IR.reset_for_test!
      IR.set_ingest_key_for_test(FAKE_KEY)
      sends = capture_sends { IR.report("flags.get", RuntimeError.new("boom")) }
      expect(sends).to be_empty
    end

    it "is a no-op when disabled (enabled: false)" do
      IR.set_context(side: "server", sdk_version: "9.9.9", enabled: false)
      sends = capture_sends { IR.report("flags.get", RuntimeError.new("boom")) }
      expect(sends).to be_empty
    end

    it "stays inert while the ingest key is the unprovisioned placeholder" do
      IR.set_ingest_key_for_test(IR::PLACEHOLDER_KEY)
      IR.set_context(side: "server", sdk_version: "9.9.9")
      sends = capture_sends { IR.report("flags.get", RuntimeError.new("boom")) }
      expect(sends).to be_empty
    end
  end

  describe "resilience" do
    it "dedupes identical internal errors within the window to one send" do
      IR.set_context(side: "server", sdk_version: "9.9.9")
      # Same error object => same top stack frame => one fingerprint (mirrors a
      # hot loop re-raising from the same line).
      err = RuntimeError.new("same")
      sends = capture_sends do
        IR.report("flags.get", err)
        IR.report("flags.get", err)
      end
      expect(sends.length).to eq(1)
    end

    it "never raises even when the transport itself raises" do
      allow(IR).to receive(:send_event).and_raise("network down")
      IR.set_context(side: "server", sdk_version: "9.9.9")
      expect { IR.report("flags.get", RuntimeError.new("boom")) }.not_to raise_error
    end
  end

  describe "Engine#safe_run integration" do
    # Drive a real (network-disabled) live engine so its central safe_run guard
    # fires and reports the swallowed internal error. safe_run is private, so we
    # invoke it through `send`.
    def live_engine
      Shipeasy::Engine.new(api_key: "srv_key", disable_telemetry: true)
    end

    it "reports the swallowed internal error and still returns the fallback" do
      engine = live_engine
      # Engine#initialize set the context; keep it enabled and swap in a real key.
      IR.set_ingest_key_for_test(FAKE_KEY)
      allow(Shipeasy::Logging).to receive(:error)

      out = nil
      sends = capture_sends do
        out = engine.send(:safe_run, "get_config('new_checkout')", "fallback") do
          raise "internal invariant"
        end
      end

      expect(out).to eq("fallback")
      expect(sends.length).to eq(1)
      ev = events(sends).first
      # The variable resource name is stripped so the subject is stable.
      expect(ev["subject"]).to eq("get_config")
      expect(ev["message"]).to eq("internal invariant")
    end

    it "does not report when safe_run's body succeeds" do
      engine = live_engine
      IR.set_ingest_key_for_test(FAKE_KEY)

      out = nil
      sends = capture_sends do
        out = engine.send(:safe_run, "get_flag('x')", false) { true }
      end

      expect(out).to eq(true)
      expect(sends).to be_empty
    end

    it "is inert in test mode (configure_for_testing builds a no-network engine)" do
      Shipeasy.configure_for_testing(flags: { "x" => true })
      IR.set_ingest_key_for_test(FAKE_KEY)
      engine = Shipeasy.engine

      sends = capture_sends do
        engine.send(:safe_run, "get_flag('x')", false) { raise "boom" }
      end
      expect(sends).to be_empty
    ensure
      Shipeasy.reset_config!
    end
  end
end
