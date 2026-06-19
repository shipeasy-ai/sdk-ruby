require "thread"

module Shipeasy
  module SDK
    # Pluggable sticky-bucketing store for the server (doc 20 §2). Duck-typed:
    # any object responding to the two methods below works.
    #
    #   get(unit) -> { exp_name => { "g" => group, "s" => salt8 } } or nil
    #   set(unit, exp_name, entry)   # entry = { "g" => group, "s" => salt8 }
    #
    # Keyed by the bucketing unit (pick_identifier-resolved id). When threaded
    # into experiment eval, an enrolled unit locks to its first-assigned variant
    # — changing allocation % or weights won't re-bucket it; changing the
    # experiment salt is the reshuffle lever. Absent ⇒ deterministic behavior.
    class InMemoryStickyStore
      # Optionally seed with { unit => { exp => { "g"=>.., "s"=>.. } } }.
      def initialize(seed = nil)
        @mutex = Mutex.new
        @data  = {}
        if seed
          seed.each { |unit, exps| @data[unit.to_s] = exps.dup }
        end
      end

      # Return this unit's per-experiment assignments, or nil if none.
      def get(unit)
        @mutex.synchronize { @data[unit.to_s] }
      end

      # Persist one assignment for (unit, exp).
      def set(unit, exp, entry)
        @mutex.synchronize do
          (@data[unit.to_s] ||= {})[exp] = entry
        end
        nil
      end
    end
  end
end
