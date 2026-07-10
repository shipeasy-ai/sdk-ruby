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

      # Pick the bucketing identifier. When bucket_by is set and the user
      # carries that attribute as a non-empty string (or any number, stringified),
      # bucket on it — so a whole company/org lands on one variant. Otherwise fall
      # back to user_id, then anonymous_id. Mirrors core's pickIdentifier.
      def self.pick_identifier(user, bucket_by)
        if bucket_by && !bucket_by.to_s.empty?
          v = user[bucket_by] || user[bucket_by.to_sym]
          return v if v.is_a?(String) && !v.empty?
          return v.to_s if v.is_a?(Numeric)
        end
        user["user_id"] || user[:user_id] || user["anonymous_id"] || user[:anonymous_id]
      end

      def self.eval_gate(gate, user)
        return false if enabled?(gate["killswitch"])
        return false unless enabled?(gate["enabled"])

        (gate["rules"] || []).each do |rule|
          return false unless match_rule(rule, user)
        end

        uid = user["user_id"] || user[:user_id] || user["anonymous_id"] || user[:anonymous_id]
        # No unit id (an unidentified request before any anon id is minted): a
        # fully-rolled gate is on for everyone, so it can be answered without
        # bucketing; a fractional rollout genuinely needs a stable unit, so deny
        # until one exists. Rules above are still checked, so targeting wins.
        # See experiment-platform/18-identity-bucketing.md.
        return (gate["rolloutPct"] || gate[:rolloutPct] || 0) >= 10000 unless uid

        salt = gate["salt"] || gate[:salt]
        murmur3("#{salt}:#{uid}") % 10000 < (gate["rolloutPct"] || gate[:rolloutPct] || 0)
      end

      ExperimentResult = Struct.new(:in_experiment, :group, :params, keyword_init: true)

      # Flatten a universe param schema (`[{ "name", "type", "default" }, ...]`)
      # to a plain `name => default` map — the defaults `assign()` layers under a
      # variant's override map. Returns nil for a null/empty schema so the merge
      # short-circuits. Mirrors the TS reference / @shipeasy/core.
      def self.param_defaults_from_schema(schema)
        return nil if schema.nil? || schema.empty?
        schema.each_with_object({}) do |p, h|
          name = p["name"] || p[:name]
          h[name] = p.key?("default") ? p["default"] : p[:default]
        end
      end

      # `universeDefaults ⊕ variantOverride` — a variant inherits every universe
      # default it doesn't explicitly override. A nil defaults map short-circuits
      # to the variant params (dup'd) alone.
      def self.merge_params(param_defaults, group_params)
        gp = group_params || {}
        param_defaults ? param_defaults.merge(gp) : gp.dup
      end

      # exp_name + sticky_store are optional so existing callers stay deterministic.
      # When a sticky_store is passed, an enrolled unit whose stored salt prefix
      # still matches skips the allocation gate (so a shrinking allocation keeps
      # it in) and returns the stored group without re-running the pick. A fresh
      # pick is persisted via store.set; a salt mismatch / missing stored group
      # falls through to re-bucket + overwrite. Mirrors the TS reference
      # (doc 20 §2). exp_name is the key under which the entry is stored.
      #
      # Pooling / holdout-gate / reserved-headroom / universe param-default merge
      # (doc 20 §B) are layered in here so both the low-level parity path and the
      # universe assign() path share ONE classify. The added steps are all guarded
      # by presence checks, so a legacy blob (no hashVersion/pool/reserved) behaves
      # exactly as before.
      # Resolve a forced override group for +uid+ (spec step 1): ID overrides
      # (tier 1) beat cohort/GK overrides (tier 2); within cohort overrides the
      # first (pre-sorted by priority) gate that passes wins. Returns the forced
      # group name or nil. The caller applies eligibility + group-existence
      # (forced-but-gated). Mirrors @shipeasy/core resolveForcedGroup.
      def self.resolve_forced_group(exp, uid, flags_blob, user)
        id_overrides = exp["idOverrides"] || exp[:idOverrides]
        if id_overrides
          by_id = id_overrides[uid]
          return by_id if by_id && !by_id.to_s.empty?
        end
        cohort_overrides = exp["cohortOverrides"] || exp[:cohortOverrides]
        if cohort_overrides
          cohort_overrides.each do |co|
            gname = co["gate"] || co[:gate]
            gate = flags_blob&.dig("gates", gname)
            return (co["group"] || co[:group]) if gate && eval_gate(gate, user)
          end
        end
        nil
      end

      def self.eval_experiment(exp, flags_blob, exps_blob, user, exp_name: nil, sticky_store: nil)
        universe_name  = exp && exp["universe"]
        universe       = exps_blob&.dig("universes", universe_name)
        param_defaults = param_defaults_from_schema(universe && (universe["param_schema"] || universe[:param_schema]))

        not_in = ExperimentResult.new(in_experiment: false, group: "control", params: nil)
        as_group = lambda do |g|
          ExperimentResult.new(
            in_experiment: true, group: g["name"], params: merge_params(param_defaults, g["params"]),
          )
        end

        return not_in unless exp && exp["status"] == "running"

        targeting_gate = exp["targetingGate"]
        if targeting_gate && !targeting_gate.empty?
          gate = flags_blob&.dig("gates", targeting_gate)
          return not_in unless gate && eval_gate(gate, user)
        end

        bucket_by = exp["bucketBy"] || exp[:bucketBy]
        uid = pick_identifier(user, bucket_by)
        return not_in unless uid

        # One segment in the universe's shared [0, 10000) hash space. The holdout
        # carve-out AND every experiment's pool slice are disjoint ranges of THIS
        # segment — that's what makes "held out / taken / free" a real partition.
        universe_seg = murmur3("#{universe_name}:#{uid}") % 10000

        holdout = universe&.dig("holdout_range")
        if holdout
          return not_in if universe_seg >= holdout[0] && universe_seg <= holdout[1]
        end

        # Holdout gate: a passing gate holds the unit out of every experiment in
        # the universe (mirrors the universe carve-out, but gate-driven).
        holdout_gate = exp["holdoutGate"]
        if holdout_gate && !holdout_gate.to_s.empty?
          gate = flags_blob&.dig("gates", holdout_gate)
          return not_in if gate && eval_gate(gate, user)
        end

        salt          = exp["salt"]
        allocation_pct = exp["allocationPct"] || 0
        groups = exp["groups"] || []
        salt8 = (salt || "")[0, 8]

        # Durable overrides (spec step 1, forced-but-gated). Reached only after the
        # unit passes targeting and is not held out, so an override may now pin the
        # group — bypassing allocation + the weighted pick but NOT the gates above.
        # ID overrides (tier 1) beat cohort/GK overrides (tier 2); a forced group
        # that no longer exists falls through to normal allocation. No-op when
        # unconfigured, so v1/v2 stay byte-identical. Mirrors @shipeasy/core.
        forced = resolve_forced_group(exp, uid, flags_blob, user)
        if forced
          g = groups.find { |x| x["name"] == forced }
          if g
            sticky_store.set(uid, exp_name, { "g" => forced, "s" => salt8 }) if sticky_store && exp_name
            return as_group.call(g)
          end
        end

        # Sticky short-circuit: an enrolled unit whose stored salt prefix still
        # matches skips allocation and returns the stored group. If the stored
        # group no longer exists, fall through to re-bucket + overwrite.
        if sticky_store && exp_name
          entry = (sticky_store.get(uid) || {})[exp_name]
          if entry && entry["s"] == salt8
            g = groups.find { |x| x["name"] == entry["g"] }
            return as_group.call(g) if g
          end
        end

        # Allocation. Pooled (hashVersion >= 2 with a slice) gives real mutual
        # exclusion: the unit's universe segment must fall in the claimed range.
        # Legacy falls back to an independent per-experiment salt so siblings
        # overlap freely (the existing parity path).
        hash_version = exp["hashVersion"] || exp[:hashVersion] || 1
        pool_offset  = exp["poolOffsetBp"] || exp[:poolOffsetBp]
        pool_size    = exp["poolSizeBp"] || exp[:poolSizeBp]
        pooled       = hash_version >= 2 && !pool_offset.nil? && !pool_size.nil? && pool_size > 0
        if pooled
          lo = pool_offset
          hi = pool_offset + pool_size
          return not_in if universe_seg < lo || universe_seg >= hi
        else
          return not_in if murmur3("#{salt}:alloc:#{uid}") % 10000 >= allocation_pct
        end

        # Group split over [0, usable) where usable = 10000 - reserved; a unit in
        # the reserved tail is left unassigned so an appended variant can absorb it.
        reserved = (exp["reservedHeadroomBp"] || exp[:reservedHeadroomBp] || 0)
        reserved = 0 if reserved < 0
        reserved = 10000 if reserved > 10000
        usable = 10000 - reserved
        group_hash = murmur3("#{salt}:group:#{uid}") % 10000
        return not_in if group_hash >= usable

        cumulative = 0
        groups.each_with_index do |g, i|
          cumulative += g["weight"]
          if group_hash < cumulative || i == groups.length - 1
            sticky_store.set(uid, exp_name, { "g" => g["name"], "s" => salt8 }) if sticky_store && exp_name
            return as_group.call(g)
          end
        end

        not_in
      end

      # The result of `universe(name).assign(user)` — a unit's standing in a
      # universe (a mutual-exclusion pool, so it lands in at most one experiment).
      # Never raises: an un-enrolled unit still resolves `get` to the universe
      # defaults (or the caller's fallback). Reading is side-effect free — the
      # single exposure is logged once by assign() when the unit is enrolled.
      class Assignment
        # The experiment the unit landed in, or nil when not enrolled.
        attr_reader :name
        # The assigned variant/group name, or nil when not enrolled.
        attr_reader :group

        # +params+ is already merged (universeDefaults ⊕ variantOverride) when
        # enrolled; defaults-only (or {}) when not. +on_expose+ fires the single
        # exposure the first time an enrolled param is read (nil when not
        # enrolled — nothing to expose); deduped downstream.
        def initialize(name, group, params, on_expose = nil)
          @name      = name
          @group     = group
          @params    = params || {}
          @on_expose = on_expose
          @exposed   = false
        end

        # True iff the unit is enrolled in an experiment in this universe.
        # Reading it does NOT log an exposure (only +get+ of a param does).
        def enrolled?
          !@group.nil?
        end

        # Read a resolved param: the assigned variant's override, else the
        # universe default, else +fallback+. Works even when not enrolled (the
        # variant layer is absent, so you get universeDefault ?? fallback).
        # Looks up both string and symbol keys.
        #
        # Exposure is logged **on read** (spec step 7): the first enrolled read
        # fires the single exposure; pass +exposure: false+ to read without
        # logging (peek).
        def get(field, fallback = nil, exposure: true)
          if exposure && !@exposed && @on_expose
            @exposed = true
            @on_expose.call
          end
          if @params.key?(field)
            @params[field]
          elsif field.respond_to?(:to_s) && @params.key?(field.to_s)
            @params[field.to_s]
          elsif field.respond_to?(:to_sym) && @params.key?(field.to_sym)
            @params[field.to_sym]
          else
            fallback
          end
        end
      end
    end
  end
end
