# Leveled logger shared by the whole gem.
#
# Every diagnostic the SDK emits from a *caught* error goes through here, so a
# single `log_level` config option (default :warn) controls the SDK's stderr
# output. The contract for the SDK's public RUNTIME methods (get_flag,
# get_config, universe(...).assign, get_killswitch, track, see, …) is
# that they NEVER raise into product code — so logging itself is best-effort
# too: a broken/throwing $stderr can never take down a flag read.
#
# Level ordering (a message at level L is emitted iff the configured level is at
# least as verbose as L):
#   silent < error < warn < info < debug
# :warn (the default) therefore emits `error` + `warn` and suppresses the
# informational `info` / `debug` chatter.

module Shipeasy
  module Logging
    # All accepted levels, in increasing verbosity.
    LEVELS = %i[silent error warn info debug].freeze

    RANK = { silent: 0, error: 1, warn: 2, info: 3, debug: 4 }.freeze

    DEFAULT_LEVEL = :warn

    class << self
      # Set the SDK-wide log level. Accepts a symbol or string (case-insensitive);
      # an unrecognised value falls back to the default :warn so a bad config value
      # can never silence a genuine error unexpectedly.
      def set_level(level)
        @level = normalize(level)
      end

      # The current SDK-wide log level (defaults to :warn until set).
      def level
        @level || DEFAULT_LEVEL
      end

      # Normalise any input to a known level symbol; unknown → DEFAULT_LEVEL.
      def normalize(level)
        sym =
          case level
          when Symbol then level.to_s.downcase.to_sym
          when String then level.downcase.to_sym
          else nil
          end
        RANK.key?(sym) ? sym : DEFAULT_LEVEL
      end

      def error(msg)
        emit(:error, msg)
      end

      def warn(msg)
        emit(:warn, msg)
      end

      def info(msg)
        emit(:info, msg)
      end

      def debug(msg)
        emit(:debug, msg)
      end

      private

      # Gate on the configured level, then write to $stderr exactly as the old
      # bare `warn "[shipeasy] …"` calls did (Kernel#warn → $stderr). Never
      # raises: a broken stream is swallowed.
      def emit(msg_level, msg)
        return if RANK[level] < RANK[msg_level]

        Kernel.warn(msg)
      rescue StandardError
        # logging must never raise into product code
      end
    end
  end
end
