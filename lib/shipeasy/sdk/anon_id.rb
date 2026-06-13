require "securerandom"

module Shipeasy
  module SDK
    # Anonymous bucketing identity — the cross-SDK `__se_anon_id` cookie.
    #
    # Gates and experiments bucket a unit with murmur3(salt:unit). For a
    # logged-out visitor the unit is a stable anonymous id carried in a single
    # first-party cookie that EVERY Shipeasy SDK (server + browser) reads and
    # writes, so a server render and the browser bucket a fractional rollout
    # identically. The cookie name + format are frozen across every language;
    # see experiment-platform/18-identity-bucketing.md.
    module AnonId
      COOKIE  = "__se_anon_id".freeze
      MAX_AGE = 31_536_000 # 1 year, in seconds

      # The cookie value is client-controllable and feeds bucketing, so a
      # tampered value is treated as absent and a fresh id is minted. UUIDs
      # satisfy this charset.
      VALID_RX = /\A[A-Za-z0-9_-]{1,64}\z/.freeze

      THREAD_KEY = :shipeasy_anon_id

      module_function

      # A fresh opaque bucketing id (UUIDv4).
      def mint
        SecureRandom.uuid
      end

      def valid?(value)
        value.is_a?(String) && VALID_RX.match?(value)
      end

      # The anon id RackMiddleware resolved for the current request, or nil when
      # no middleware ran (e.g. a background job). FlagsClient falls back to this
      # as the default anonymous_id, so evaluations need no per-call wiring.
      def current
        Thread.current[THREAD_KEY]
      end

      def current=(value)
        Thread.current[THREAD_KEY] = value
      end
    end
  end
end
