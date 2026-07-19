require "spec_helper"

# Gatekeeper `stack` evaluation.
#
# Regression guard for the bug where eval_gate read only the flat
# `rules` + `rolloutPct` columns and ignored a modern gate's ordered `stack`.
# The canonical model is the stack (mirrors @shipeasy/core evalGatekeeper + the
# edge worker); the flat columns are a lossy approximation that can invert the
# result — a whitelist condition at 100% followed by a 0% public rollout
# flattens to `rolloutPct: 0`, which the flat path wrongly reads as "never".
RSpec.describe Shipeasy::SDK::Eval do
  P = "e976b15e-3ccc-44d3-821d-87f06d5a0e43".freeze

  # The exact shape the KV rebuild ships for a whitelist gatekeeper: a condition
  # (no explicit rolloutPct => 100%) that whitelists a project, then a locked 0%
  # public rollout. The flat columns are the lossy approximation.
  def whitelist_gate
    {
      "enabled" => 1,
      "salt" => "caf3a1ae",
      # Lossy flat approximation — must NOT be what decides the result.
      "rules" => [{ "attr" => "project_id", "op" => "in", "value" => [P] }],
      "rolloutPct" => 0,
      "stack" => [
        {
          "id" => "gq578snc",
          "type" => "condition",
          "pass" => "all",
          "rules" => [{ "attr" => "project_id", "op" => "in", "value" => [P] }],
        },
        { "id" => "gu0uein4", "type" => "rollout", "rolloutPct" => 0, "bucketBy" => "user_id", "salt" => "public" },
      ],
    }
  end

  describe ".eval_gate with a gatekeeper stack" do
    it "passes a whitelisted caller even though the flat rolloutPct is 0" do
      user = { "user_id" => "cdewqzx@gmail.com", "project_id" => P }
      # The regression: the flat path reads "matches whitelist AND 0% bucket" =
      # false. The stack short-circuits on the 100% condition => true.
      expect(described_class.eval_gate(whitelist_gate, user)).to be(true)
    end

    it "hides a non-whitelisted caller (condition misses, public rollout is 0%)" do
      user = { "user_id" => "someone@else.com", "project_id" => "other-project" }
      expect(described_class.eval_gate(whitelist_gate, user)).to be(false)
    end

    it "passes a whitelisted caller with no identity (100% condition needs no unit)" do
      expect(described_class.eval_gate(whitelist_gate, { "project_id" => P })).to be(true)
    end

    it "a matching condition still gates on its own rollout %" do
      gate = {
        "enabled" => 1, "salt" => "s", "rules" => [], "rolloutPct" => 0,
        "stack" => [
          {
            "id" => "c1", "type" => "condition", "pass" => "all",
            "rules" => [{ "attr" => "project_id", "op" => "in", "value" => [P] }],
            "rolloutPct" => 0, # matched but 0% => never
          },
        ],
      }
      expect(described_class.eval_gate(gate, { "user_id" => "u1", "project_id" => P })).to be(false)
    end

    it "supports pass: 'any' conditions" do
      gate = {
        "enabled" => 1, "salt" => "s", "rules" => [], "rolloutPct" => 0,
        "stack" => [
          {
            "id" => "c1", "type" => "condition", "pass" => "any",
            "rules" => [
              { "attr" => "plan", "op" => "eq", "value" => "pro" },
              { "attr" => "project_id", "op" => "in", "value" => [P] },
            ],
          },
        ],
      }
      # plan misses but project_id matches => one branch => pass.
      expect(described_class.eval_gate(gate, { "user_id" => "u", "plan" => "free", "project_id" => P })).to be(true)
      expect(described_class.eval_gate(gate, { "user_id" => "u", "plan" => "free", "project_id" => "x" })).to be(false)
    end

    it "falls through to a later rollout entry as a catch-all" do
      gate = {
        "enabled" => 1, "salt" => "s", "rules" => [], "rolloutPct" => 0,
        "stack" => [
          {
            "id" => "c1", "type" => "condition", "pass" => "all",
            "rules" => [{ "attr" => "project_id", "op" => "in", "value" => [P] }],
          },
          { "id" => "public", "type" => "rollout", "rolloutPct" => 10000 }, # everyone else: 100%
        ],
      }
      expect(described_class.eval_gate(gate, { "user_id" => "u", "project_id" => "not-whitelisted" })).to be(true)
    end

    it "a disabled or killed stacked gate is off" do
      user = { "user_id" => "u", "project_id" => P }
      expect(described_class.eval_gate(whitelist_gate.merge("enabled" => 0), user)).to be(false)
      expect(described_class.eval_gate(whitelist_gate.merge("killswitch" => 1), user)).to be(false)
    end

    it "a stack-less gate still uses the legacy flat path" do
      on  = { "enabled" => 1, "salt" => "s", "rules" => [], "rolloutPct" => 10000 }
      off = { "enabled" => 1, "salt" => "s", "rules" => [], "rolloutPct" => 0 }
      expect(described_class.eval_gate(on, { "user_id" => "u" })).to be(true)
      expect(described_class.eval_gate(off, { "user_id" => "u" })).to be(false)
    end
  end
end
