require "spec_helper"

# Coverage for the three competitor-parity additions in 1.5.0:
#   A. private_attributes — stripped from outbound track() props
#   B. log_exposure — manual server-side exposure logging
#   C. sticky bucketing — StickyBucketStore + InMemoryStickyStore
RSpec.describe "Shipeasy::Engine parity features (round 2)" do
  # Capture the JSON body that would be POSTed to /collect, synchronously.
  # track/log_exposure post inside a Thread.new; we stub `post` to record the
  # parsed body and join the spawned thread so the assertion is deterministic.
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

  # ---- Feature A: private attributes ------------------------------------

  describe "private_attributes (track stripping)" do
    it "strips listed keys from the outbound track properties" do
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, private_attributes: %w[email ssn]
      )
      bodies = capture_collect(client) do
        client.track("u_1", "purchase", { "email" => "a@b.com", "ssn" => "123", "plan" => "pro" })
      end
      props = bodies.first[1]["events"][0]["properties"]
      expect(props).to eq({ "plan" => "pro" })
    end

    it "strips symbol-keyed private attributes too" do
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, private_attributes: ["email"]
      )
      bodies = capture_collect(client) do
        client.track("u_1", "purchase", { email: "a@b.com", plan: "pro" })
      end
      props = bodies.first[1]["events"][0]["properties"]
      expect(props).to eq({ "plan" => "pro" })
    end

    it "leaves props untouched when no private_attributes are configured" do
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      bodies = capture_collect(client) do
        client.track("u_1", "purchase", { "email" => "a@b.com" })
      end
      expect(bodies.first[1]["events"][0]["properties"]).to eq({ "email" => "a@b.com" })
    end

    it "omits the properties key entirely when stripping empties the bag" do
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, private_attributes: ["email"]
      )
      bodies = capture_collect(client) do
        client.track("u_1", "purchase", { "email" => "a@b.com" })
      end
      expect(bodies.first[1]["events"][0]).not_to have_key("properties")
    end
  end

  # ---- Feature B: manual exposure ---------------------------------------

  describe "#log_exposure" do
    let(:running_exp) do
      {
        "experiments" => {
          "exp" => {
            "status" => "running",
            "salt" => "x",
            "allocationPct" => 10000,
            "universe" => "u",
            "groups" => [{ "name" => "control", "weight" => 10000, "params" => {} }],
          },
        },
        "universes" => { "u" => {} },
      }
    end

    # log_exposure needs a LIVE (non-test) client so it actually posts; seed its
    # blobs directly (load_snapshot) without going through from_snapshot (which
    # is test_mode and short-circuits log_exposure to a no-op).
    def live_client_with(exps)
      client = Shipeasy::Engine.new(api_key: "k", disable_telemetry: true)
      client.send(:load_snapshot, {}, exps)
      client
    end

    it "POSTs one exposure event when the user is enrolled" do
      client = live_client_with(running_exp)
      bodies = capture_collect(client) { client.log_exposure("u_1", "exp") }
      expect(bodies.length).to eq(1)
      path, body = bodies.first
      expect(path).to eq("/collect")
      ev = body["events"][0]
      expect(ev["type"]).to eq("exposure")
      expect(ev["experiment"]).to eq("exp")
      expect(ev["group"]).to eq("control")
      expect(ev["user_id"]).to eq("u_1")
      expect(ev["ts"]).to be_a(Integer)
    end

    it "accepts a user hash and resolves the user_id" do
      client = live_client_with(running_exp)
      bodies = capture_collect(client) { client.log_exposure({ "user_id" => "u_9" }, "exp") }
      expect(bodies.first[1]["events"][0]["user_id"]).to eq("u_9")
    end

    it "is a no-op when the user is not enrolled (experiment not running)" do
      stopped = running_exp.dup
      stopped["experiments"]["exp"] = running_exp["experiments"]["exp"].merge("status" => "stopped")
      client = live_client_with(stopped)
      bodies = capture_collect(client) { client.log_exposure("u_1", "exp") }
      expect(bodies).to be_empty
    end

    it "is a no-op in test mode" do
      client = Shipeasy::Engine.for_testing
      expect(client).not_to receive(:post)
      expect(client.log_exposure("u_1", "exp")).to be_nil
    end
  end

  # ---- Feature C: sticky bucketing --------------------------------------

  describe "sticky bucketing" do
    # An experiment with two groups so a re-pick under different allocation
    # could plausibly differ — the sticky store must pin the first assignment.
    let(:exps) do
      {
        "experiments" => {
          "exp" => {
            "status" => "running",
            "salt" => "saltvalue123",
            "allocationPct" => 10000,
            "universe" => "u",
            "groups" => [
              { "name" => "control", "weight" => 5000, "params" => { "v" => 0 } },
              { "name" => "treatment", "weight" => 5000, "params" => { "v" => 1 } },
            ],
          },
        },
        "universes" => { "u" => {} },
      }
    end
    let(:user) { { "user_id" => "u_42" } }
    let(:salt8) { "saltvalu" } # "saltvalue123"[0,8]

    describe "Shipeasy::SDK::InMemoryStickyStore" do
      it "round-trips get/set" do
        store = Shipeasy::SDK::InMemoryStickyStore.new
        expect(store.get("u_1")).to be_nil
        store.set("u_1", "exp", { "g" => "control", "s" => "abcd1234" })
        expect(store.get("u_1")).to eq({ "exp" => { "g" => "control", "s" => "abcd1234" } })
      end

      it "can be seeded" do
        store = Shipeasy::SDK::InMemoryStickyStore.new(
          "u_1" => { "exp" => { "g" => "treatment", "s" => "ssssssss" } }
        )
        expect(store.get("u_1")["exp"]["g"]).to eq("treatment")
      end
    end

    it "absent store ⇒ deterministic (no persistence)" do
      client = Shipeasy::Engine.from_snapshot(experiments: exps)
      first  = client.get_experiment("exp", user, {}).group
      second = client.get_experiment("exp", user, {}).group
      expect(first).to eq(second) # deterministic regardless
    end

    it "persists the fresh pick into the store" do
      store = Shipeasy::SDK::InMemoryStickyStore.new
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, sticky_store: store
      )
      client.send(:load_snapshot, {}, exps)
      result = client.get_experiment("exp", user, {})
      entry = store.get("u_42")["exp"]
      expect(entry["g"]).to eq(result.group)
      expect(entry["s"]).to eq(salt8)
    end

    it "returns the stored group (skips allocation) when salt prefix matches" do
      # Seed the store with treatment for a unit that, deterministically, would
      # bucket to control — then drop allocation to 0 so a re-pick would be
      # not_in. Sticky must keep it enrolled in treatment.
      seeded = Shipeasy::SDK::InMemoryStickyStore.new(
        "u_42" => { "exp" => { "g" => "treatment", "s" => salt8 } }
      )
      shrunk = exps.dup
      shrunk["experiments"]["exp"] = exps["experiments"]["exp"].merge("allocationPct" => 0)
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, sticky_store: seeded
      )
      client.send(:load_snapshot, {}, shrunk)
      result = client.get_experiment("exp", user, {})
      expect(result.in_experiment).to eq(true)
      expect(result.group).to eq("treatment")
      expect(result.params).to eq({ "v" => 1 })
    end

    it "re-buckets and overwrites on a salt-prefix mismatch" do
      stale = Shipeasy::SDK::InMemoryStickyStore.new(
        "u_42" => { "exp" => { "g" => "treatment", "s" => "OLDSALT8" } }
      )
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, sticky_store: stale
      )
      client.send(:load_snapshot, {}, exps)
      result = client.get_experiment("exp", user, {})
      # Overwritten with the current salt prefix.
      expect(stale.get("u_42")["exp"]["s"]).to eq(salt8)
      expect(stale.get("u_42")["exp"]["g"]).to eq(result.group)
    end

    it "re-buckets when the stored group no longer exists in the experiment" do
      gone = Shipeasy::SDK::InMemoryStickyStore.new(
        "u_42" => { "exp" => { "g" => "removed_group", "s" => salt8 } }
      )
      client = Shipeasy::Engine.new(
        api_key: "k", disable_telemetry: true, sticky_store: gone
      )
      client.send(:load_snapshot, {}, exps)
      result = client.get_experiment("exp", user, {})
      expect(%w[control treatment]).to include(result.group)
      expect(gone.get("u_42")["exp"]["g"]).to eq(result.group)
    end
  end
end
