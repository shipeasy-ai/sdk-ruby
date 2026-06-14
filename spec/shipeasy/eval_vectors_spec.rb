require "spec_helper"
require "json"

# Cross-language eval-parity golden-vector test.
#
# packages/core is the canonical source of truth for bucketing. Its fixture
# (spec/fixtures/eval-vectors.json — copied byte-identically from
# packages/core/src/eval/__fixtures__/eval-vectors.json) is reproduced here by
# THIS SDK's own murmur3 + gate/experiment evaluation. If the Ruby
# implementation ever drifts from the platform (hash bug, wrong key format,
# off-by-one rollout/allocation/group boundary), this suite goes red before the
# gem can publish. See experiment-platform/18-identity-bucketing.md.
#
# Note on adapting the fixture to this SDK's API:
# - Core's evalExperiment takes (experiment, user, flags, holdoutRange) where
#   `flags` is a map of already-evaluated booleans and `holdoutRange` is passed
#   directly. This SDK's eval_experiment(exp, flags_blob, exps_blob, user)
#   re-derives those from KV-shaped blobs: it re-evaluates the targeting gate
#   out of flags_blob["gates"] and reads holdout_range off the universe in
#   exps_blob["universes"]. So we synthesise those blobs from the fixture: a
#   gate that deterministically evaluates to the fixture's flag boolean, and a
#   universe carrying the fixture's holdoutRange.
RSpec.describe "eval-parity golden vectors" do
  fixture_path = File.expand_path("../fixtures/eval-vectors.json", __dir__)
  FIXTURE = JSON.parse(File.read(fixture_path)).freeze

  # A gate definition that eval_gate evaluates to exactly `value` for a unit
  # that has an identity (every experiment vector with a targeting gate carries
  # a user_id). enabled:false → always false; enabled + 100% rollout → true.
  def gate_for(value)
    if value
      { "enabled" => true, "rules" => [], "rolloutPct" => 10_000, "salt" => "parity_targeting" }
    else
      { "enabled" => false, "rules" => [], "rolloutPct" => 10_000, "salt" => "parity_targeting" }
    end
  end

  describe "murmur3 hash" do
    FIXTURE.fetch("hash").each do |vec|
      it "Murmur3.hash32(#{vec['input'].inspect}) == #{vec['hash']}" do
        expect(Shipeasy::SDK::Murmur3.hash32(vec["input"], 0)).to eq(vec["hash"])
      end
    end
  end

  describe "gate decisions" do
    FIXTURE.fetch("gate").each do |vec|
      it vec.fetch("note") do
        expect(Shipeasy::SDK::Eval.eval_gate(vec.fetch("gate"), vec.fetch("user")))
          .to be(vec.fetch("pass"))
      end
    end
  end

  describe "experiment decisions" do
    FIXTURE.fetch("experiment").each do |vec|
      it vec.fetch("note") do
        exp           = vec.fetch("experiment")
        user          = vec.fetch("user")
        flags         = vec.fetch("flags")
        holdout_range = vec.fetch("holdoutRange")
        expected      = vec.fetch("result")

        flags_blob = {
          "gates" => flags.each_with_object({}) { |(name, value), h| h[name] = gate_for(value) },
        }
        exps_blob = {
          "universes" => {
            exp.fetch("universe") => { "holdout_range" => holdout_range },
          },
        }

        assignment = Shipeasy::SDK::Eval.eval_experiment(exp, flags_blob, exps_blob, user)

        if expected.fetch("inExperiment")
          expect(assignment.in_experiment).to be(true)
          expect(assignment.group).to eq(expected.fetch("group"))
        else
          expect(assignment.in_experiment).to be(false)
        end
      end
    end
  end
end
