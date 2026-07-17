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
    Shipeasy::Engine.new(api_key: "srv_key", disable_telemetry: true, **opts)
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
      client = Shipeasy::Engine.for_testing
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
      # The returned chain is fully chainable and silently drops — including a
      # trailing `.extras` after `.to`, which must never raise.
      expect do
        chain.causes_the("checkout").to("use cached prices").extras(order_id: 1)
      end.not_to raise_error
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

  describe "backtrace cleaning" do
    # An exception carrying a hand-built backtrace mixing app + gem frames, so we
    # can assert exactly which frames survive cleaning.
    def exc_with_backtrace(frames)
      e = RuntimeError.new("boom")
      e.set_backtrace(frames)
      e
    end

    APP_AND_GEM = [
      "app/models/order.rb:10:in `charge'",
      "/gems/activerecord-7.1/lib/foo.rb:99:in `run'",
      "app/controllers/checkout_controller.rb:5:in `create'",
    ].freeze

    describe "Shipeasy::SDK::See.build_event with a cleaner" do
      it "passes the raw backtrace through the framework cleaner" do
        # A stand-in for Rails.backtrace_cleaner.clean: drop /gems/ frames. We do
        # NOT reimplement this rule in the SDK — the callable comes from the host.
        cleaner = ->(bt) { bt.reject { |f| f.include?("/gems/") } }
        ev = Shipeasy::SDK::See.build_event(
          exc_with_backtrace(APP_AND_GEM), "checkout", "use cached prices", nil,
          sdk_version: "test", env: "prod", backtrace_cleaner: cleaner
        )
        expect(ev["stack"]).to include("order.rb")
        expect(ev["stack"]).to include("checkout_controller.rb")
        expect(ev["stack"]).not_to include("/gems/")
      end

      it "sends the raw backtrace when no cleaner is supplied" do
        ev = Shipeasy::SDK::See.build_event(
          exc_with_backtrace(APP_AND_GEM), "checkout", "x", nil,
          sdk_version: "test", env: "prod"
        )
        expect(ev["stack"]).to include("/gems/")
      end

      it "falls back to the raw backtrace when the cleaner strips every frame" do
        cleaner = ->(_bt) { [] }
        ev = Shipeasy::SDK::See.build_event(
          exc_with_backtrace(APP_AND_GEM), "checkout", "x", nil,
          sdk_version: "test", env: "prod", backtrace_cleaner: cleaner
        )
        # A stack that lives entirely in framework code must not lose ALL signal.
        expect(ev["stack"]).to include("order.rb")
        expect(ev["stack"]).to include("/gems/")
      end

      it "falls back to the raw backtrace when the cleaner raises" do
        cleaner = ->(_bt) { raise "cleaner blew up" }
        ev = Shipeasy::SDK::See.build_event(
          exc_with_backtrace(APP_AND_GEM), "checkout", "x", nil,
          sdk_version: "test", env: "prod", backtrace_cleaner: cleaner
        )
        expect(ev["stack"]).to include("order.rb")
      end
    end

    describe "engine dispatch under Rails" do
      # A minimal stand-in for the Rails app object exposing backtrace_cleaner.
      def fake_rails(cleaner)
        cleaner_obj = Object.new
        cleaner_obj.define_singleton_method(:clean) { |bt| cleaner.call(bt) }
        rails = Object.new
        rails.define_singleton_method(:backtrace_cleaner) { cleaner_obj }
        rails
      end

      it "cleans see() stacks via Rails.backtrace_cleaner by default" do
        stub_const("Rails", fake_rails(->(bt) { bt.reject { |f| f.include?("/gems/") } }))
        client = live_client
        bodies = capture_collect(client) do
          client.see(exc_with_backtrace(APP_AND_GEM)).causes_the("checkout").to("use cached prices")
        end
        expect(events(bodies).first["stack"]).not_to include("/gems/")
      end

      it "sends the raw backtrace when clean_backtrace: false, even under Rails" do
        stub_const("Rails", fake_rails(->(bt) { bt.reject { |f| f.include?("/gems/") } }))
        client = live_client(clean_backtrace: false)
        bodies = capture_collect(client) do
          client.see(exc_with_backtrace(APP_AND_GEM)).causes_the("checkout").to("x")
        end
        expect(events(bodies).first["stack"]).to include("/gems/")
      end
    end
  end

  describe "inline extras on .to" do
    it "accepts extras as the trailing arg to .to(outcome, extras)" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x")).causes_the("checkout").to(
          "use cached prices", { order_id: "o1", ok: true }
        )
      end
      expect(events(bodies).first["extras"]).to eq({ "order_id" => "o1", "ok" => true })
    end

    it "merges inline .to extras over a prior .extras (later wins)" do
      client = live_client
      bodies = capture_collect(client) do
        client.see(RuntimeError.new("x"))
              .extras(a: 1, b: 2)
              .to("done", { b: 3, c: 4 })
      end
      expect(events(bodies).first["extras"]).to eq({ "a" => 1, "b" => 3, "c" => 4 })
    end
  end

  describe "trailing .extras after .to" do
    it "is ignored with a warning and does NOT send a second report" do
      client = live_client
      bodies = nil
      expect do
        bodies = capture_collect(client) do
          client.see(RuntimeError.new("x")).causes_the("checkout")
                .to("use cached prices").extras(order_id: "late")
        end
      end.to output(/called after \.to/).to_stderr
      evs = events(bodies)
      expect(evs.length).to eq(1)
      expect(evs.first["extras"]).to be_nil
    end

    it "never raises into the caller (the report already shipped)" do
      client = live_client
      capture_collect(client) do
        expect do
          client.see(RuntimeError.new("x")).to("be incomplete").extras(a: 1).extras(b: 2)
        end.not_to raise_error
      end
    end
  end

  describe "ambient per-request extras (Shipeasy.add_extras)" do
    after { Shipeasy::SDK::See::Context.clear }

    it "merges buffered extras into a later see() report" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(order_id: "o9", tenant: "acme")
        client.see(RuntimeError.new("x")).causes_the("checkout").to("use cached prices")
      end
      expect(events(bodies).first["extras"]).to eq({ "order_id" => "o9", "tenant" => "acme" })
    end

    it "accumulates across scattered add_extras calls" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(order_id: "o9")
        Shipeasy::SDK.add_extras(step: "charge")
        client.see(RuntimeError.new("x")).to("fail")
      end
      expect(events(bodies).first["extras"]).to eq({ "order_id" => "o9", "step" => "charge" })
    end

    it "attaches to EVERY report in scope, not just the first" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(route: "/checkout")
        client.see(RuntimeError.new("a")).to("fail a")
        client.see(RuntimeError.new("b")).to("fail b")
      end
      evs = events(bodies)
      expect(evs.length).to eq(2)
      expect(evs[0]["extras"]).to eq({ "route" => "/checkout" })
      expect(evs[1]["extras"]).to eq({ "route" => "/checkout" })
    end

    it "lets a chained .extras override an ambient key of the same name" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(order_id: "ambient", tenant: "acme")
        client.see(RuntimeError.new("x")).extras(order_id: "local").to("fail")
      end
      expect(events(bodies).first["extras"]).to eq({ "order_id" => "local", "tenant" => "acme" })
    end

    it "strips configured private attributes from ambient extras too" do
      client = live_client(private_attributes: ["secret"])
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(secret: "shh", ok: "yes")
        client.see(RuntimeError.new("x")).to("fail")
      end
      extras = events(bodies).first["extras"]
      expect(extras).not_to have_key("secret")
      expect(extras["ok"]).to eq("yes")
    end

    it "clear_extras drops the buffer so later reports carry nothing" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras(order_id: "o9")
        Shipeasy::SDK.clear_extras
        client.see(RuntimeError.new("x")).to("fail")
      end
      expect(events(bodies).first).not_to have_key("extras")
    end

    it "accepts a hash argument as well as keywords" do
      client = live_client
      bodies = capture_collect(client) do
        Shipeasy::SDK.add_extras({ "a" => 1 })
        client.see(RuntimeError.new("x")).to("fail")
      end
      expect(events(bodies).first["extras"]).to eq({ "a" => 1 })
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
