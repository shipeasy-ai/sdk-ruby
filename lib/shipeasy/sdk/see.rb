# see — shipeasy error. Structured error reporting for the server SDK.
#
# Mirrors `@shipeasy/sdk` (packages/ts-sdk/src/see/core.ts) and the Python
# reference (packages/server-sdks/sdk-python/shipeasy/_see.py). Every handled
# exception documents its product *consequence*, not just its stack:
#
#   begin
#     charge_card(order)
#   rescue => e
#     Shipeasy::SDK.see(e).causes_the("checkout").to("use the backup processor")
#   end
#
# Dispatch model (differs from TS, which uses a microtask): `.to(outcome)` is
# the terminal — it builds the wire event and fire-and-forgets the POST to
# /collect. `causes_the` and `extras` are chainable setters that may be called
# in any order *before* `.to`:
#
#   client.see(e).causes_the("checkout").to("use cached prices")
#   client.see(e).causes_the("checkout").extras({ order_id: oid }).to("use cached prices")
#
# If you don't know the consequence of an exception, don't catch it.

require "thread"
require "json"
require_relative "version"

module Shipeasy
  module SDK
    module See
      # ---- Limits (mirror core.ts; kept in sync with the worker's /collect) ----
      SEE_MAX_MESSAGE     = 500
      SEE_MAX_STACK       = 8000
      SEE_MAX_SUBJECT     = 200 # used for subject, outcome, error_type
      SEE_MAX_EXTRA_VALUE = 200
      SEE_MAX_EXTRA_KEYS  = 20
      SEE_DEDUP_WINDOW_MS = 30_000
      SEE_MAX_PER_PROCESS = 25

      # Default consequence parts when a chain omits them.
      DEFAULT_SUBJECT = "app".freeze
      DEFAULT_OUTCOME = "hit an error".freeze

      # Marker attribute stamped onto an exception by control_flow_exception().
      EXPECTED_IVAR = :@__shipeasy_see_expected

      module_function

      def truncate(str, limit)
        s = str.to_s
        s.length <= limit ? s : s[0, limit]
      end

      # Drop nil values, keep only String/Numeric(finite)/boolean, truncate
      # string values to 200 chars, cap at 20 keys (insertion order). Returns
      # nil if nothing is kept. Keys are stringified.
      def sanitize_extras(extras)
        return nil unless extras.is_a?(Hash)
        return nil if extras.empty?

        out = {}
        extras.each do |k, v|
          break if out.size >= SEE_MAX_EXTRA_KEYS
          next if v.nil?

          case v
          when true, false
            out[k.to_s] = v
          when String
            out[k.to_s] = truncate(v, SEE_MAX_EXTRA_VALUE)
          when Numeric
            # Reject NaN / Infinity (not representable in JSON).
            next if v.respond_to?(:finite?) && !v.finite?

            out[k.to_s] = v
          else
            next
          end
        end
        out.empty? ? nil : out
      end

      # Best-effort stamp marking an exception as expected control flow.
      def mark_expected(err, because, extras = nil)
        mark = { "because" => because.to_s }
        clean = sanitize_extras(extras)
        mark["extras"] = clean if clean
        err.instance_variable_set(EXPECTED_IVAR, mark)
      rescue StandardError
        # Frozen / builtin objects that reject ivars: best effort only.
        nil
      end

      def expected?(err)
        err.instance_variable_defined?(EXPECTED_IVAR) &&
          !err.instance_variable_get(EXPECTED_IVAR).nil?
      rescue StandardError
        false
      end

      # A non-exception problem. The name is a stable fingerprint key — put
      # variable data in `.extras`, never in the name.
      class Violation
        attr_reader :name

        def initialize(name)
          @name = name.to_s
        end
      end

      # ---- Wire event construction ----

      # Build the type:"error" event accepted by POST /collect.
      def build_event(problem, subject, outcome, extras, sdk_version:, env:)
        stack = nil

        if problem.is_a?(Violation)
          error_type = problem.name
          message    = problem.name
          kind       = "violation"
        elsif problem.is_a?(Exception)
          error_type = problem.class.name || "Error"
          message    = (problem.message.to_s.empty? ? error_type : problem.message)
          bt = problem.backtrace
          stack = bt.join("\n") if bt && !bt.empty?
          kind = "caught"
        else
          error_type = "Error"
          message    = problem.to_s
          kind       = "caught"
        end

        ev = {
          "type"        => "error",
          "kind"        => kind,
          "error_type"  => truncate(error_type, SEE_MAX_SUBJECT),
          "message"     => truncate(message, SEE_MAX_MESSAGE),
          "subject"     => truncate(subject, SEE_MAX_SUBJECT),
          "outcome"     => truncate(outcome, SEE_MAX_SUBJECT),
          "side"        => "server",
          "sdk_version" => sdk_version,
          "ts"          => (Time.now.to_f * 1000).to_i,
        }
        ev["stack"] = truncate(stack, SEE_MAX_STACK) if stack
        clean = sanitize_extras(extras)
        ev["extras"] = clean if clean
        ev["env"] = env if env && !env.to_s.empty?
        ev
      end

      # ---- Spam limiter (mirror SeeLimiter) ----

      # Per-process spam guard: identical events within 30s collapse to one
      # send; a hard cap bounds total sends. Thread-safe. The worker dedupes by
      # fingerprint anyway — this only bounds network chatter from a hot loop.
      class Limiter
        def initialize(max_per_process: SEE_MAX_PER_PROCESS, dedup_window_ms: SEE_DEDUP_WINDOW_MS)
          @max    = max_per_process
          @window = dedup_window_ms
          @last   = {}
          @sent   = 0
          @mutex  = Mutex.new
        end

        def should_send?(ev)
          @mutex.synchronize do
            return false if @sent >= @max

            key = [
              ev["kind"],
              ev["error_type"],
              ev["message"].to_s[0, 200],
              See.top_stack_line(ev["stack"]),
            ].join("|")
            now = (Time.now.to_f * 1000).to_i
            prev = @last[key]
            return false if prev && (now - prev) < @window

            @last[key] = now
            @sent += 1
            true
          end
        end
      end

      def top_stack_line(stack)
        return "" if stack.nil? || stack.empty?

        stack.each_line do |line|
          s = line.strip
          return s[0, 200] if s.start_with?("File ") || s.start_with?("at ") || s.include?("line ") || s.include?(":in ")
        end
        ""
      end

      # ---- Fluent chains ----

      # Accumulates consequence + extras; `.to(outcome)` dispatches once.
      class Chain
        def initialize(problem, dispatch)
          @problem  = problem
          @dispatch = dispatch
          @subject  = nil
          @outcome  = nil
          @extras   = nil
          @done     = false
        end

        def causes_the(subject)
          @subject = subject.to_s
          self
        end
        alias causesThe causes_the

        def extras(extras)
          if extras.is_a?(Hash) && !extras.empty?
            @extras = (@extras || {}).merge(extras)
          end
          self
        end

        # Terminal: build the event and fire-and-forget the report. Idempotent.
        def to(outcome)
          return if @done

          @done = true
          @outcome = outcome.to_s
          begin
            @dispatch.call(
              Built.new(@problem, @subject || DEFAULT_SUBJECT, @outcome.empty? ? DEFAULT_OUTCOME : @outcome, @extras)
            )
          rescue StandardError
            # Reporting must never raise into caller code.
            nil
          end
        end
      end

      # Plain carrier of a finalized chain handed to the client dispatcher.
      Built = Struct.new(:problem, :subject, :outcome, :extras)

      # `control_flow_exception(e).because("because ...")` — marks the exception
      # expected and reports NOTHING. `.extras` is stored for local debugging
      # only (an expected exception is never transmitted).
      class ControlFlowChain
        def initialize(err)
          @err = err
        end

        def because(reason)
          See.mark_expected(@err, reason)
          ControlFlowTail.new(@err, reason)
        end
      end

      class ControlFlowTail
        def initialize(err, reason)
          @err = err
          @reason = reason
        end

        def extras(extras)
          See.mark_expected(@err, @reason, extras)
          self
        end
      end

      # A no-op chain returned by the module-level see() when no client exists.
      class NullChain
        def causes_the(_subject)
          self
        end
        alias causesThe causes_the

        def extras(_extras)
          self
        end

        def to(_outcome)
          nil
        end
      end
    end
  end
end
