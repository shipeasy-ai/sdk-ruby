require "spec_helper"

# Universe-first assignment (the mutual-exclusion pool model, doc 20 §B).
#
# `engine.universe(name).assign(user)` returns an Eval::Assignment: the <=1
# experiment the unit landed in within the universe, its variant, and resolved
# params (variant override ?? universe default ?? fallback). These specs lock the
# merge (§B2), the not-enrolled defaults path, pooled mutual exclusion (§B4),
# reserved headroom (§B5), and the holdout gate (§B3). They seed the blobs
# directly (no network), mirroring src/__tests__/universe-assign.test.ts.
RSpec.describe "Shipeasy::Engine#universe(name).assign — universe-first assignment" do
  MOD = 10_000

  def universe_seg(universe, uid)
    Shipeasy::SDK::Murmur3.hash32("#{universe}:#{uid}", 0) % MOD
  end

  # A no-network engine (test mode, so auto-exposure is a no-op) seeded with the
  # given flags + experiments blobs — the same way from_snapshot builds one.
  def make_engine(flags: {}, exps: {})
    client = Shipeasy::Engine.for_testing
    client.send(:load_snapshot, flags, exps)
    client
  end

  describe "param merge (§B2)" do
    # A universe owns button_color=red, size=1. The one running experiment's
    # assigned variant overrides only button_color.
    def build
      make_engine(
        exps: {
          "universes" => {
            "u" => {
              "holdout_range" => nil,
              "param_schema" => [
                { "name" => "button_color", "type" => "string", "default" => "red" },
                { "name" => "size", "type" => "int", "default" => 1 },
              ],
            },
          },
          "experiments" => {
            "exp" => {
              "universe" => "u",
              "allocationPct" => 10_000,
              "salt" => "s",
              "status" => "running",
              "groups" => [{ "name" => "treatment", "weight" => 10_000, "params" => { "button_color" => "blue" } }],
            },
          },
        },
      )
    end

    it "variant override wins, unset params inherit the universe default, unknown fields fall back" do
      a = build.universe("u").assign({ "user_id" => "u1" })
      expect(a.enrolled?).to be(true)
      expect(a.group).to eq("treatment")
      # Overridden by the variant.
      expect(a.get("button_color")).to eq("blue")
      # Not overridden → inherited from the universe default.
      expect(a.get("size")).to eq(1)
      # Absent everywhere → the caller's fallback.
      expect(a.get("missing", "fb")).to eq("fb")
    end
  end

  describe "not enrolled still gets universe defaults" do
    it "allocationPct 0 → not enrolled, group nil, but universe default resolves" do
      engine = make_engine(
        exps: {
          "universes" => {
            "u" => {
              "holdout_range" => nil,
              "param_schema" => [{ "name" => "button_color", "type" => "string", "default" => "red" }],
            },
          },
          "experiments" => {
            "exp" => {
              "universe" => "u",
              "allocationPct" => 0, # nobody allocated
              "salt" => "s",
              "status" => "running",
              "groups" => [{ "name" => "treatment", "weight" => 10_000, "params" => { "button_color" => "blue" } }],
            },
          },
        },
      )
      a = engine.universe("u").assign({ "user_id" => "u1" })
      expect(a.enrolled?).to be(false)
      expect(a.name).to be_nil
      expect(a.group).to be_nil
      # Not enrolled → universe default, not the variant override.
      expect(a.get("button_color")).to eq("red")
    end
  end

  describe "pooled mutual exclusion (§B4)" do
    # Two experiments in ONE universe, hashVersion 2, disjoint pool slices:
    #   A = [0, 4000), B = [4000, 8000). Segment >= 8000 is unallocated headroom.
    let(:engine) do
      make_engine(
        exps: {
          "universes" => { "u" => { "holdout_range" => nil } },
          "experiments" => {
            "expA" => {
              "universe" => "u", "hashVersion" => 2, "poolOffsetBp" => 0, "poolSizeBp" => 4000,
              "allocationPct" => 10_000, "salt" => "sA", "status" => "running",
              "groups" => [{ "name" => "A", "weight" => 10_000, "params" => {} }],
            },
            "expB" => {
              "universe" => "u", "hashVersion" => 2, "poolOffsetBp" => 4000, "poolSizeBp" => 4000,
              "allocationPct" => 10_000, "salt" => "sB", "status" => "running",
              "groups" => [{ "name" => "B", "weight" => 10_000, "params" => {} }],
            },
          },
        },
      )
    end

    it "no unit lands in both; each slice + the free tail all get some units" do
      in_a = 0
      in_b = 0
      neither = 0
      400.times do |i|
        uid = "u#{i}"
        a = engine.universe("u").assign({ "user_id" => uid })
        # assign returns <=1 experiment, so double-enrolment is impossible by
        # design; cross-check the landing against the unit's own universe segment.
        seg = universe_seg("u", uid)
        case a.name
        when "expA"
          in_a += 1
          expect(seg).to be < 4000
        when "expB"
          in_b += 1
          expect(seg).to be >= 4000
          expect(seg).to be < 8000
        else
          neither += 1
          expect(a.enrolled?).to be(false)
          expect(seg).to be >= 8000
        end
      end
      # The partition is real: all three buckets are populated over 400 users.
      expect(in_a).to be > 0
      expect(in_b).to be > 0
      expect(neither).to be > 0
      expect(in_a + in_b + neither).to eq(400)
    end
  end

  describe "reserved headroom (§B5)" do
    # 100% allocation, groups summing to 5000 with reservedHeadroomBp 5000: units
    # whose group hash falls in the reserved tail are left not-enrolled.
    let(:engine) do
      make_engine(
        exps: {
          "universes" => { "u" => { "holdout_range" => nil } },
          "experiments" => {
            "exp" => {
              "universe" => "u", "allocationPct" => 10_000, "reservedHeadroomBp" => 5000,
              "salt" => "s", "status" => "running",
              "groups" => [{ "name" => "control", "weight" => 5000, "params" => {} }],
            },
          },
        },
      )
    end

    it "a chunk of fully-allocated users still land in the reserved (not-enrolled) tail" do
      enrolled = 0
      reserved = 0
      400.times do |i|
        a = engine.universe("u").assign({ "user_id" => "u#{i}" })
        a.enrolled? ? (enrolled += 1) : (reserved += 1)
      end
      # Both populated: allocation is 100% yet the reserved tail carves out ~half.
      expect(enrolled).to be > 0
      expect(reserved).to be > 0
    end
  end

  describe "holdoutGate (§B3)" do
    it "a unit for whom the holdout gate passes is held out (not enrolled)" do
      engine = make_engine(
        flags: {
          "gates" => {
            # enabled, 100% rollout, no rules → passes for every identified unit.
            "hg" => { "rules" => [], "rolloutPct" => 10_000, "salt" => "hg", "enabled" => 1 },
          },
        },
        exps: {
          "universes" => { "u" => { "holdout_range" => nil } },
          "experiments" => {
            "exp" => {
              "universe" => "u", "holdoutGate" => "hg", "allocationPct" => 10_000,
              "salt" => "s", "status" => "running",
              "groups" => [{ "name" => "treatment", "weight" => 10_000, "params" => {} }],
            },
          },
        },
      )
      a = engine.universe("u").assign({ "user_id" => "u1" })
      expect(a.enrolled?).to be(false)
      expect(a.group).to be_nil
    end
  end

  describe "evaluate() bootstrap payload" do
    it "carries a per-experiment universe field and a top-level universes defaults map" do
      engine = make_engine(
        exps: {
          "universes" => {
            "u" => { "param_schema" => [{ "name" => "color", "type" => "string", "default" => "red" }] },
          },
          "experiments" => {
            "exp" => {
              "universe" => "u", "allocationPct" => 10_000, "salt" => "s", "status" => "running",
              "groups" => [{ "name" => "treatment", "weight" => 10_000, "params" => { "color" => "blue" } }],
            },
          },
        },
      )
      p = engine.evaluate({ "user_id" => "u1" })
      expect(p["experiments"]["exp"]["universe"]).to eq("u")
      expect(p["experiments"]["exp"]["inExperiment"]).to be(true)
      # Enrolled params are merged (universe default ⊕ variant).
      expect(p["experiments"]["exp"]["params"]).to eq("color" => "blue")
      # Top-level universes map exposes the defaults.
      expect(p["universes"]["u"]["defaults"]).to eq("color" => "red")
    end
  end
end
