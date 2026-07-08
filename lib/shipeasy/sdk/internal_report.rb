# Internal self-monitoring channel — SDK bugs that are "on our end".
#
# When the SDK swallows one of its OWN internal errors (the `Engine#safe_run`
# last-resort guard in engine.rb, which keeps a get_flag/get_config/… from
# raising into product code even when an internal invariant is violated), it
# ALSO ships a structured see event here — to Shipeasy's OWN project, NOT the
# consumer's — so the SDK team can track SDK-internal failures across every app
# the SDK runs in.
#
# This is deliberately distinct from the customer-facing `see()` path
# (Shipeasy::SDK.see / Engine#see), which authenticates with the consumer's key
# and lands in the consumer's dashboard. Internal errors must never pollute a
# customer's Errors tab, and the SDK team must see them centrally — so this
# channel has its own baked-in destination + credential.
#
# Guarantees (identical to telemetry/see): fire-and-forget, never blocks, never
# raises into product code, deduped/rate-limited. A failed send is swallowed
# silently — it must never log (that would risk recursion through safe_run).

require "net/http"
require "uri"
require "json"
require "thread"
require_relative "see"
require_relative "version"

module Shipeasy
  module SDK
    module InternalReport
      # ---- Baked-in destination ----
      #
      # The main Shipeasy project (`.shipeasy` project_id
      # e976b15e-3ccc-44d3-821d-87f06d5a0e43). The credential is a PUBLIC client
      # key — the same class of credential already embedded verbatim in every
      # browser bundle that ships the client SDK, and mirroring how the CLI bakes
      # Shipeasy's own public key for setup-bug self-reporting — so baking it into
      # the published gem is safe. `/collect` treats it as a write-only ingest
      # key; it grants no read access. The canonical ingest host is
      # api.shipeasy.ai (the SDK default base_url), which routes /collect to the
      # edge worker.
      INGEST_URL = "https://api.shipeasy.ai/collect".freeze

      # Sentinel used until the real key is minted + baked. While INGEST_KEY is
      # still the placeholder the channel stays fully inert (see .report), so a
      # gem that ships before the key is provisioned never fires doomed requests.
      # Mint the key with:
      #   shipeasy keys create --type client --env prod \
      #     --name "SDK internal error self-reporting" --scopes events:write
      # then replace the INGEST_KEY assignment below with the returned value.
      PLACEHOLDER_KEY = "sdk_client_REPLACE_WITH_SHIPEASY_INTERNAL_ERROR_KEY".freeze

      # The baked-in ingest credential. Swap the placeholder for the real minted
      # key here (this is the ONLY line to change when the key is provisioned).
      INGEST_KEY = "sdk_client_00bd4608a03e4084922978f9522614d5"

      # Stable consequence. The `label` (the safe_run operation name, e.g.
      # "flags.get") is the subject; the outcome is fixed. Both are constant per
      # operation — no variable data — so occurrences of the same internal bug
      # fold into one issue on our dashboard (fingerprint = error_type +
      # normalized message + top stack + subject|outcome). `sdk` marks which
      # language SDK reported it.
      OUTCOME = "returned a safe default".freeze
      SDK_ID  = "ruby".freeze

      class << self
        # True once a real key has been baked in (not the placeholder sentinel).
        def key_configured?(key = @ingest_key || INGEST_KEY)
          !key.nil? && !key.empty? && key != PLACEHOLDER_KEY
        end

        # Wire the self-monitoring channel. Called from Engine#initialize with the
        # bundle's side + version. `enabled` defaults on; it is forced off in test
        # mode (no network) and when the caller opts out via
        # disable_internal_error_reporting.
        def set_context(side:, sdk_version:, enabled: true)
          @side        = side
          @sdk_version = sdk_version
          @enabled     = enabled != false
          @limiter   ||= See::Limiter.new
        end

        # Report an SDK-internal error to Shipeasy's own project. Called from
        # Engine#safe_run's rescue. `label` is the swallowed operation (e.g.
        # "flags.get") and becomes the stable issue subject. Never raises.
        def report(label, err)
          return unless @enabled
          key = @ingest_key || INGEST_KEY
          return unless key_configured?(key)

          ev = See.build_event(
            err,
            label.to_s,
            OUTCOME,
            { "sdk" => SDK_ID },
            sdk_version: @sdk_version || Shipeasy::SDK::VERSION,
            env: nil,
          )
          # Internal reports carry only the SDK-side context — never a consumer's
          # env or url — so a customer's config can't leak into our project.
          ev["side"] = @side || "server"

          limiter = (@limiter ||= See::Limiter.new)
          return unless limiter.should_send?(ev)

          send_event(key, JSON.generate({ events: [ev] }))
        rescue StandardError
          # Self-reporting must never raise into product code.
          nil
        end

        private

        # Fire-and-forget POST to the baked-in ingest on a background thread.
        # Isolated so specs can intercept it without real network. A failed send
        # is swallowed silently — it must never log (that would risk recursion
        # through safe_run).
        def send_event(key, body)
          Thread.new do
            begin
              uri  = URI.parse(INGEST_URL)
              http = Net::HTTP.new(uri.host, uri.port)
              http.use_ssl      = (uri.scheme == "https")
              http.open_timeout = 2
              http.read_timeout = 2
              http.post(uri.request_uri, body, { "X-SDK-Key" => key, "Content-Type" => "text/plain" })
            rescue StandardError
              # self-reporting must never surface a network error
            end
          end
        end

        # ---- Test seams ----

        public

        # Reset module state (context + rate limiter + key override) so a spec
        # starts from a clean, inert channel.
        def reset_for_test!
          @side        = nil
          @sdk_version = nil
          @enabled     = nil
          @limiter     = See::Limiter.new
          @ingest_key  = nil
        end

        # Stand in a real-looking key so specs can exercise the send path without
        # the (deliberately inert) placeholder blocking it.
        def set_ingest_key_for_test(key)
          @ingest_key = key
        end
      end
    end
  end
end
