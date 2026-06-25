require "spec_helper"

# Specs for the post-2.0 front door: a process-wide `Shipeasy.configure` that
# registers the single global `Shipeasy::Engine`, plus the lightweight,
# user-bound `Shipeasy::Client` built via its real constructor.
RSpec.describe "Shipeasy.configure + Shipeasy::Client(user)" do
  before do
    Shipeasy.reset_config!
    # Don't let the configure() one-shot fetch actually hit the network in CI.
    allow_any_instance_of(Shipeasy::Engine).to receive(:init_once).and_return(nil)
  end

  after { Shipeasy.reset_config! }

  describe "Shipeasy::Client.new before configure" do
    it "raises loudly" do
      expect { Shipeasy::Client.new("user_id" => "u1") }
        .to raise_error(Shipeasy::Error, /configure/)
    end
  end

  describe "configure then a bound client" do
    it "builds one global engine and evaluates a bound flag with NO user arg" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }

      expect(Shipeasy.engine).to be_a(Shipeasy::Engine)
      Shipeasy.engine.override_flag("new_checkout", true)

      client = Shipeasy::Client.new("user_id" => "u1")
      expect(client.get_flag("new_checkout")).to be(true)
      expect(client.get_flag("missing", default: true)).to be(true)
    end

    it "returns the SAME global engine across multiple Clients (no per-Client fetch)" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      engine = Shipeasy.engine

      c1 = Shipeasy::Client.new("user_id" => "u1")
      c2 = Shipeasy::Client.new("user_id" => "u2")

      expect(c1.instance_variable_get(:@engine)).to equal(engine)
      expect(c2.instance_variable_get(:@engine)).to equal(engine)
    end

    it "forwards get_config / get_killswitch to the engine" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      Shipeasy.engine.override_config("price", 42)

      client = Shipeasy::Client.new("user_id" => "u1")
      expect(client.get_config("price")).to eq(42)
      # Unknown killswitch → false (no blob loaded).
      expect(client.get_killswitch("panic")).to be(false)
    end
  end

  describe "attributes transform" do
    it "defaults to identity — the user object IS the attribute map" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      client = Shipeasy::Client.new("user_id" => "u1", "plan" => "pro")
      expect(client.attributes).to include("user_id" => "u1", "plan" => "pro")
    end

    it "applies the configured transform once at construction" do
      Shipeasy.configure do |c|
        c.api_key    = "srv_key"
        c.attributes = ->(u) { { "user_id" => u[:id], "plan" => u[:plan] } }
      end

      raw_user = { id: "abc", plan: "enterprise" }
      client   = Shipeasy::Client.new(raw_user)

      expect(client.attributes).to include("user_id" => "abc", "plan" => "enterprise")
    end

    it "evaluates against the MAPPED attributes" do
      Shipeasy.configure do |c|
        c.api_key    = "srv_key"
        c.attributes = ->(u) { { "user_id" => u.fetch(:id) } }
      end

      # A gate fully rolled out, but gated to user_id == "vip" via a rule.
      gate = {
        "enabled"    => true,
        "rolloutPct" => 10_000,
        "salt"       => "s",
        "rules"      => [{ "attr" => "user_id", "op" => "eq", "value" => "vip" }],
      }
      Shipeasy.engine.instance_variable_set(:@flags_blob, { "gates" => { "g" => gate } })

      vip   = Shipeasy::Client.new(id: "vip")
      other = Shipeasy::Client.new(id: "nobody")

      expect(vip.get_flag("g")).to be(true)
      expect(other.get_flag("g")).to be(false)
    end

    it "raises if attributes is set to a non-callable" do
      Shipeasy.configure do |c|
        c.api_key    = "srv_key"
        c.attributes = "not callable"
      end
      expect { Shipeasy::Client.new("user_id" => "u1") }
        .to raise_error(Shipeasy::Error, /callable/)
    end
  end

  describe "anon-id enrichment" do
    around do |example|
      Shipeasy::SDK::AnonId.current = "anon-xyz"
      example.run
    ensure
      Shipeasy::SDK::AnonId.current = nil
    end

    it "merges the request-scoped anonymous_id when no unit was supplied" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      client = Shipeasy::Client.new({})
      expect(client.attributes["anonymous_id"]).to eq("anon-xyz")
    end

    it "does NOT override a caller-supplied user_id" do
      Shipeasy.configure { |c| c.api_key = "srv_key" }
      client = Shipeasy::Client.new("user_id" => "real")
      expect(client.attributes["user_id"]).to eq("real")
      expect(client.attributes["anonymous_id"]).to be_nil
    end
  end
end
