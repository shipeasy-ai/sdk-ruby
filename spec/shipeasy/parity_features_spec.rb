require "spec_helper"
require "tempfile"

# Coverage for the four competitor-parity additions:
#   A. default: on get_flag / get_config
#   B. get_flag_detail + reasons
#   C. on_change listeners
#   D. from_snapshot / from_file offline data source
RSpec.describe "Shipeasy::Engine parity features" do
  # A gate that is fully rolled out (on for everyone) and one that's disabled.
  let(:on_gate)  { { "enabled" => 1, "salt" => "s", "rolloutPct" => 10000 } }
  let(:off_gate) { { "enabled" => 0, "salt" => "s", "rolloutPct" => 10000 } }
  let(:zero_gate) { { "enabled" => 1, "salt" => "s", "rolloutPct" => 0 } }
  let(:user) { { "user_id" => "u_1" } }

  # ---- Feature B: get_flag_detail reasons -------------------------------

  describe "#get_flag_detail" do
    it "OVERRIDE — returns the override value without telemetry" do
      client = Shipeasy::Engine.for_testing
      client.override_flag("g", true)
      detail = client.get_flag_detail("g", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_OVERRIDE)
      expect(detail.value).to eq(true)
    end

    it "CLIENT_NOT_READY — no blob loaded yet" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      detail = client.get_flag_detail("g", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_CLIENT_NOT_READY)
      expect(detail.value).to eq(false)
    end

    it "FLAG_NOT_FOUND — blob present but gate absent" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => {} })
      detail = client.get_flag_detail("missing", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_FLAG_NOT_FOUND)
      expect(detail.value).to eq(false)
    end

    it "OFF — gate present but disabled" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => off_gate } })
      detail = client.get_flag_detail("g", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_OFF)
      expect(detail.value).to eq(false)
    end

    it "OFF — gate killswitched" do
      killed = { "enabled" => 1, "killswitch" => 1, "salt" => "s", "rolloutPct" => 10000 }
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => killed } })
      expect(client.get_flag_detail("g", user).reason).to eq(Shipeasy::Engine::REASON_OFF)
    end

    it "RULE_MATCH — evaluates true" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => on_gate } })
      detail = client.get_flag_detail("g", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_RULE_MATCH)
      expect(detail.value).to eq(true)
    end

    it "DEFAULT — evaluates false (0% rollout)" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => zero_gate } })
      detail = client.get_flag_detail("g", user)
      expect(detail.reason).to eq(Shipeasy::Engine::REASON_DEFAULT)
      expect(detail.value).to eq(false)
    end

    it "emits the gate telemetry beacon exactly once (not on OVERRIDE)" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => on_gate } })
      telemetry = client.instance_variable_get(:@telemetry)
      expect(telemetry).to receive(:emit).with("gate", "g").once
      client.get_flag_detail("g", user)

      # Override path emits nothing.
      client.override_flag("g", false)
      expect(telemetry).not_to receive(:emit)
      client.get_flag_detail("g", user)
    end
  end

  # ---- Feature A: default values ----------------------------------------

  describe "#get_flag default:" do
    it "returns the default only when not-ready" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      expect(client.get_flag("g", user, default: true)).to eq(true)
    end

    it "returns the default only when not-found" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => {} })
      expect(client.get_flag("missing", user, default: true)).to eq(true)
    end

    it "does NOT return the default when the flag evaluates to false (OFF)" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => off_gate } })
      expect(client.get_flag("g", user, default: true)).to eq(false)
    end

    it "does NOT return the default when the flag evaluates to false (DEFAULT/rollout)" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => zero_gate } })
      expect(client.get_flag("g", user, default: true)).to eq(false)
    end

    it "returns the real value when the flag is on" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => { "g" => on_gate } })
      expect(client.get_flag("g", user, default: true)).to eq(true)
    end

    it "default false keeps the legacy two-arg behavior" do
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => {} })
      expect(client.get_flag("missing", user)).to eq(false)
    end
  end

  describe "#get_config default:" do
    it "returns the default when the config key is absent" do
      client = Shipeasy::Engine.from_snapshot(flags: { "configs" => {} })
      expect(client.get_config("missing", default: "fallback")).to eq("fallback")
    end

    it "returns the value (not the default) when present, decode still runs" do
      client = Shipeasy::Engine.from_snapshot(
        flags: { "configs" => { "limits" => { "value" => { "max" => 10 } } } }
      )
      expect(client.get_config("limits", default: {})).to eq({ "max" => 10 })
      expect(client.get_config("limits", ->(v) { v["max"] * 2 }, default: 0)).to eq(20)
    end

    it "absent key with decode + default returns the raw default (decode not run)" do
      client = Shipeasy::Engine.from_snapshot(flags: { "configs" => {} })
      expect(client.get_config("missing", ->(v) { v["x"] }, default: "d")).to eq("d")
    end

    it "default nil preserves legacy behavior" do
      client = Shipeasy::Engine.from_snapshot(flags: { "configs" => {} })
      expect(client.get_config("missing")).to be_nil
    end
  end

  # ---- Feature C: on_change listeners -----------------------------------

  describe "#on_change" do
    # Drive fetch_flags directly with a stubbed HTTP layer so we exercise the
    # real "200 → notify" path without a poll thread or network.
    def http_response(code, body: "{}", etag: nil)
      res = instance_double(Net::HTTPResponse)
      allow(res).to receive(:code).and_return(code)
      allow(res).to receive(:[]) do |h|
        case h
        when "X-Poll-Interval" then "30"
        when "ETag" then etag
        end
      end
      allow(res).to receive(:body).and_return(body)
      allow(res).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess && code == "200" }
      res
    end

    it "fires after a poll fetch returns NEW data (200) and supports unsubscribe" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      fires = 0
      unsubscribe = client.on_change { fires += 1 }

      allow(client).to receive(:http_get).and_return(http_response("200", body: '{"gates":{}}'))
      client.send(:fetch_flags)
      expect(fires).to eq(1)

      client.send(:fetch_flags)
      expect(fires).to eq(2)

      unsubscribe.call
      client.send(:fetch_flags)
      expect(fires).to eq(2) # no further fires after unsubscribe
    end

    it "does NOT fire on a 304 (no new data)" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      fires = 0
      client.on_change { fires += 1 }
      allow(client).to receive(:http_get).and_return(http_response("304"))
      client.send(:fetch_flags)
      expect(fires).to eq(0)
    end

    it "accepts a callable object" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      callable = double("listener")
      expect(callable).to receive(:call).once
      client.on_change(callable)
      allow(client).to receive(:http_get).and_return(http_response("200", body: '{"gates":{}}'))
      client.send(:fetch_flags)
    end

    it "isolates a raising listener (warns, others still run)" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      ran = false
      client.on_change { raise "boom" }
      client.on_change { ran = true }
      allow(client).to receive(:http_get).and_return(http_response("200", body: '{"gates":{}}'))
      allow(client).to receive(:warn)
      client.send(:fetch_flags)
      expect(ran).to eq(true)
    end

    it "never fires in offline/snapshot mode" do
      fires = 0
      client = Shipeasy::Engine.from_snapshot(flags: { "gates" => {} })
      client.on_change { fires += 1 }
      # No poll thread exists; loading another snapshot does not notify.
      client.send(:load_snapshot, { "gates" => {} }, nil)
      expect(fires).to eq(0)
    end
  end

  # ---- Feature D: offline file / snapshot data source -------------------

  describe ".from_snapshot / .from_file" do
    let(:snapshot) do
      {
        "flags" => {
          "gates" => { "g" => { "enabled" => 1, "salt" => "s", "rolloutPct" => 10000 } },
          "configs" => { "color" => { "value" => "blue" } },
        },
        "experiments" => {
          "experiments" => {
            "exp" => {
              "status" => "running",
              "salt" => "x",
              "allocationPct" => 10000,
              "universe" => "u",
              "groups" => [{ "name" => "control", "weight" => 10000, "params" => { "n" => 1 } }],
            },
          },
          "universes" => { "u" => {} },
        },
      }
    end

    it "from_snapshot evaluates the real evaluator with no network" do
      client = Shipeasy::Engine.from_snapshot(
        flags: snapshot["flags"], experiments: snapshot["experiments"]
      )
      expect(client.get_flag("g", user)).to eq(true)
      expect(client.get_config("color")).to eq("blue")
      r = client.get_experiment("exp", user, {})
      expect(r.in_experiment).to eq(true)
      expect(r.group).to eq("control")
    end

    it "from_snapshot honours init/init_once/track as no-ops and never fetches" do
      client = Shipeasy::Engine.from_snapshot(flags: snapshot["flags"])
      expect(client).not_to receive(:http_get)
      expect(client.init).to be_nil
      expect(client.init_once).to be_nil
      expect(client.track("u_1", "evt")).to be_nil
    end

    it "overrides apply on top of the snapshot" do
      client = Shipeasy::Engine.from_snapshot(flags: snapshot["flags"])
      client.override_flag("g", false)
      expect(client.get_flag("g", user)).to eq(false)
    end

    it "from_file reads a JSON snapshot and evaluates it" do
      file = Tempfile.new(["snapshot", ".json"])
      file.write(JSON.generate(snapshot))
      file.flush
      begin
        client = Shipeasy::Engine.from_file(file.path)
        expect(client.get_flag("g", user)).to eq(true)
        expect(client.get_config("color")).to eq("blue")
      ensure
        file.close!
      end
    end
  end
end
