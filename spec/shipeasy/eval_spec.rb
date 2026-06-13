require "spec_helper"

# The no-unit evaluation rule is a cross-SDK contract: a request with no unit id
# answers a fully-rolled gate as on (no bucketing needed) but a fractional gate
# as off (it needs a stable unit). See experiment-platform/18-identity-bucketing.md.
RSpec.describe Shipeasy::SDK::Eval do
  describe ".eval_gate with no unit id" do
    it "is on for a fully-rolled (100%) gate" do
      gate = { "enabled" => 1, "salt" => "s", "rolloutPct" => 10000 }
      expect(described_class.eval_gate(gate, {})).to be(true)
    end

    it "is off for a fractional gate" do
      gate = { "enabled" => 1, "salt" => "s", "rolloutPct" => 5000 }
      expect(described_class.eval_gate(gate, {})).to be(false)
    end

    it "stays off when disabled even at 100%" do
      gate = { "enabled" => 0, "rolloutPct" => 10000 }
      expect(described_class.eval_gate(gate, {})).to be(false)
    end

    it "stays off when killed even at 100%" do
      gate = { "enabled" => 1, "killswitch" => 1, "rolloutPct" => 10000 }
      expect(described_class.eval_gate(gate, {})).to be(false)
    end

    it "honours targeting rules before the short-circuit" do
      gate = {
        "enabled" => 1, "salt" => "s", "rolloutPct" => 10000,
        "rules" => [{ "attr" => "plan", "op" => "eq", "value" => "pro" }],
      }
      expect(described_class.eval_gate(gate, {})).to be(false)
      expect(described_class.eval_gate(gate, { "plan" => "pro" })).to be(true)
    end
  end

  describe ".eval_gate with a unit id" do
    it "is off for a 0% gate and on for a 100% gate" do
      expect(described_class.eval_gate({ "enabled" => 1, "salt" => "s", "rolloutPct" => 0 }, { "user_id" => "u1" })).to be(false)
      expect(described_class.eval_gate({ "enabled" => 1, "salt" => "s", "rolloutPct" => 10000 }, { "user_id" => "u1" })).to be(true)
    end
  end
end
