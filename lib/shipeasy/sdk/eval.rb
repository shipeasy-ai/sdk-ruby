require_relative "murmur3"

module Shipeasy
  module SDK
    module Eval
      def self.murmur3(key)
        Murmur3.hash32(key, 0)
      end

      def self.enabled?(v)
        v == 1 || v == true
      end

      def self.to_num(v)
        case v
        when Numeric then v.finite? ? v : nil
        when String
          n = Float(v) rescue nil
          n&.finite? ? n : nil
        end
      end

      def self.match_rule(rule, user)
        attr  = rule["attr"] || rule[:attr]
        op    = rule["op"]   || rule[:op]
        value = rule["value"] || rule[:value]
        actual = user[attr] || user[attr.to_sym]

        case op
        when "eq"       then actual == value
        when "neq"      then actual != value
        when "in"       then Array(value).include?(actual)
        when "not_in"   then !Array(value).include?(actual)
        when "contains"
          if actual.is_a?(String) && value.is_a?(String)
            actual.include?(value)
          elsif actual.is_a?(Array)
            actual.include?(value)
          else
            false
          end
        when "regex"
          actual.is_a?(String) && value.is_a?(String) &&
            Regexp.new(value).match?(actual) rescue false
        when "gt", "gte", "lt", "lte"
          a = to_num(actual)
          b = to_num(value)
          return false if a.nil? || b.nil?
          case op
          when "gt"  then a > b
          when "gte" then a >= b
          when "lt"  then a < b
          when "lte" then a <= b
          end
        else
          false
        end
      end

      def self.eval_gate(gate, user)
        return false if enabled?(gate["killswitch"])
        return false unless enabled?(gate["enabled"])

        (gate["rules"] || []).each do |rule|
          return false unless match_rule(rule, user)
        end

        uid = user["user_id"] || user[:user_id] || user["anonymous_id"] || user[:anonymous_id]
        return false unless uid

        salt = gate["salt"] || gate[:salt]
        murmur3("#{salt}:#{uid}") % 10000 < (gate["rolloutPct"] || gate[:rolloutPct] || 0)
      end

      ExperimentResult = Struct.new(:in_experiment, :group, :params, keyword_init: true)

      def self.eval_experiment(exp, flags_blob, exps_blob, user)
        not_in = ExperimentResult.new(in_experiment: false, group: "control", params: nil)

        return not_in unless exp && exp["status"] == "running"

        targeting_gate = exp["targetingGate"]
        if targeting_gate && !targeting_gate.empty?
          gate = flags_blob&.dig("gates", targeting_gate)
          return not_in unless gate && eval_gate(gate, user)
        end

        uid = user["user_id"] || user[:user_id] || user["anonymous_id"] || user[:anonymous_id]
        return not_in unless uid

        universe_name = exp["universe"]
        universe = exps_blob&.dig("universes", universe_name)
        holdout = universe&.dig("holdout_range")
        if holdout
          seg = murmur3("#{universe_name}:#{uid}") % 10000
          return not_in if seg >= holdout[0] && seg <= holdout[1]
        end

        salt          = exp["salt"]
        allocation_pct = exp["allocationPct"] || 0
        return not_in if murmur3("#{salt}:alloc:#{uid}") % 10000 >= allocation_pct

        group_hash = murmur3("#{salt}:group:#{uid}") % 10000
        cumulative = 0
        groups = exp["groups"] || []
        groups.each_with_index do |g, i|
          cumulative += g["weight"]
          if group_hash < cumulative || i == groups.length - 1
            return ExperimentResult.new(in_experiment: true, group: g["name"], params: g["params"])
          end
        end

        not_in
      end
    end
  end
end
