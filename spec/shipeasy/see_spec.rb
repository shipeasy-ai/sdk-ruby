require "spec_helper"

# Coverage for the see() structured error-reporting grammar (1.6.0). Mirrors the
# Python reference suite (tests/test_see.py).
RSpec.describe "Shipeasy::SDK see()" do
  # Capture the JSON body that would be POSTed to /collect, synchronously.
  # dispatch_see posts inside a Thread.new; we stub `post` to record the parsed
  # body and join the spawned thread(s) so assertions are deterministic.
  def capture_collect(client)
    bodies = []
    allow(client).to receive(:post) do |path, body|
      bodies << [path, JSON.parse(body)]
      nil
    end
    threads = []
    allow(Thread).to receive(:new) do |&blk|
      t = Thread.start(&blk)
      threads << t
      t
    end
    yield
    threads.each(&:join)
    bodies
  end

  def events(bodies)
    bodies.flat_map { |(_path, body)| body["events"] }
  end

  def live_client(**opts)
    Shipeasy::SDK::FlagsClient.new(api_key: "srv_key", disable_telemetry: true, **opts)
  end

  describe "instance #see" do
    it "reports a caught exception as a type:error event" do
      client = live_client
      bodies = capture_collect(client) do
        begin
          raise ArgumentError, "boom"
        rescue ArgumentError => e
          client.see(e).causes_the("checkout").to("use cached prices")
        end
      end
      ev = events(bodies).first
      expect(ev["type"]).to eq("error")
      expect(ev["kind"]).to eq("caught")
      expect(ev["error_type"]).to eq("ArgumentError")
      expect(ev["message"]).to eq("boom")
      expect(ev["subject"]).to eq("checkout")
      expect(ev["outcome"]).to eq("use cached prices")
      expect(ev["side"]).to eq("server")
      expect(ev["sdk_version"]).to eq(Shipeasy::SDK::VERSION)
      expect(ev["env"]).to eq("prod")
      expect(ev).to have_key("stack")
    end

    it "tags the event with the client's configured env" do
      client = live_client(env: "staging")
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).causes_the("y").to("z")
      end
      expect(events(bodies).first["env"]).to eq("staging")
    end

    it "sanitizes extras supplied before to()" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).causes_the("photo upload").extras(
          { "photo_id" => "p1", "size" => 42, "ok" => true, "skip" => nil }
        ).to("be rejected")
      end
      expect(events(bodies).first["extras"]).to eq(
        { "photo_id" => "p1", "size" => 42, "ok" => true }
      )
    end

    it "merges repeated extras (later wins)" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x"))
              .extras(a: 1, b: 2)
              .extras(b: 3, c: 4)
              .to("done")
      end
      expect(events(bodies).first["extras"]).to eq({ "a" => 1, "b" => 3, "c" => 4 })
    end

    it "applies default subject/outcome when the consequence is omitted" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).to("be incomplete")
      end
      ev = events(bodies).first
      expect(ev["subject"]).to eq("app")
    end
  end

  describe "instance #see_violation" do
    it "uses the violation kind and carries no stack" do
      client = live_client
      bodies = capture_collect(client) do
        client.see_violation("large query").causes_the("search results").to("be trimmed")
      end
      ev = events(bodies).first
      expect(ev["kind"]).to eq("violation")
      expect(ev["error_type"]).to eq("large query")
      expect(ev["message"]).to eq("large query")
      expect(ev["subject"]).to eq("search results")
      expect(ev).not_to have_key("stack")
    end
  end

  describe "#control_flow_exception" do
    it "marks the exception expected and reports nothing" do
      client = live_client
      e = ArgumentError.new("not a Foo")
      bodies = capture_collect(client) do
        client.control_flow_exception(e)
              .because("because it wasn't an encoded Foo")
              .extras(tried: "Foo")
      end
      expect(Shipeasy::SDK::See.expected?(e)).to be(true)
      expect(bodies).to be_empty
    end
  end

  describe "terminal contract" do
    it "sends nothing when .to is never called" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).causes_the("checkout") # no .to
      end
      expect(bodies).to be_empty
    end

    it "is idempotent — a second .to does not send again" do
      client = live_client
      bodies = capture_collect(client) do
        chain = client.see(RuntimeError.new("x")).causes_the("checkout")
        chain.to("a")
        chain.to("b")
      end
      expect(events(bodies).length).to eq(1)
    end
  end

  describe "test mode" do
    it "is a no-op (never posts, never spawns a thread)" do
      client = Shipeasy::SDK::FlagsClient.for_testing
      expect(Thread).not_to receive(:new)
      expect(client).not_to receive(:post)
      client.see(RuntimeError.new("x")).causes_the("checkout").to("use cached prices")
    end
  end

  describe "module-level facade" do
    it "routes to the last-constructed client" do
      client = live_client
      Shipeasy::SDK.set_default_client(client)
      bodies = capture_collect(client) do
        Shipeasy::SDK.see(RuntimeError.new("global")).causes_the("dashboard").to("show cached data")
      end
      expect(events(bodies).first["subject"]).to eq("dashboard")
    end

    it "warns and no-ops when called before any client exists" do
      Shipeasy::SDK.set_default_client(nil)
      chain = nil
      expect { chain = Shipeasy::SDK.see(RuntimeError.new("x")) }
        .to output(/before a client was created/).to_stderr
      # The returned chain is fully chainable and silently drops.
      expect(chain.causes_the("checkout").to("use cached prices")).to be_nil
    end

    it "control_flow_exception works without a client" do
      Shipeasy::SDK.set_default_client(nil)
      e = RuntimeError.new("x")
      Shipeasy::SDK.control_flow_exception(e).because("because reasons")
      expect(Shipeasy::SDK::See.expected?(e)).to be(true)
    end
  end

  describe "private attributes" do
    it "strips configured private attributes from see() extras" do
      client = live_client(private_attributes: ["secret"])
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).causes_the("checkout").extras(
          { "secret" => "shh", "ok" => "yes" }
        ).to("use cached prices")
      end
      extras = events(bodies).first["extras"]
      expect(extras).not_to have_key("secret")
      expect(extras["ok"]).to eq("yes")
    end
  end

  describe "Shipeasy::SDK::See.sanitize_extras" do
    it "caps keys at 20 and truncates long string values" do
      big = {}
      30.times { |i| big["k#{i}"] = i }
      big["long"] = "x" * 500
      out = Shipeasy::SDK::See.sanitize_extras(big)
      expect(out.length).to be <= 20
    end

    it "drops nil and non-scalar values" do
      out = Shipeasy::SDK::See.sanitize_extras(
        { "a" => "s", "b" => nil, "c" => [1, 2], "d" => 7, "e" => true }
      )
      expect(out).to eq({ "a" => "s", "d" => 7, "e" => true })
    end

    it "returns nil for an empty or non-hash input" do
      expect(Shipeasy::SDK::See.sanitize_extras({})).to be_nil
      expect(Shipeasy::SDK::See.sanitize_extras(nil)).to be_nil
    end
  end
end
