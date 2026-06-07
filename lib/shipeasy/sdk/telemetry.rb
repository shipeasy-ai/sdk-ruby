require "net/http"
require "uri"
require "digest"
require "erb"
require "thread"

module Shipeasy
  module SDK
    # Per-evaluation usage telemetry. Fires one fire-and-forget HTTP beacon per
    # evaluation so usage is counted by Cloudflare's native per-path analytics.
    # Mirrors the contract in the TypeScript reference SDK and
    # experiment-platform/15-usage-metering.md. The path carries sha256(api_key)
    # -- never the raw key -- plus side/env, then feature/resource. A long-lived
    # Ruby process emits reliably; the 2s dedup window bounds volume under loops.
    class Telemetry
      DEFAULT_TELEMETRY_URL = "https://t.shipeasy.ai"

      def initialize(endpoint:, sdk_key:, side: "server", env: "prod", disabled: false, dedupe_ms: 2000)
        endpoint = (endpoint || "").chomp("/")
        @disabled  = disabled || sdk_key.nil? || sdk_key.empty? || endpoint.empty?
        @dedupe_ms = dedupe_ms
        @last      = {}
        @mutex     = Mutex.new
        unless @disabled
          key_hash = Digest::SHA256.hexdigest(sdk_key)
          @prefix = "#{endpoint}/t/#{key_hash}/#{side}/#{enc(env)}"
        end
      end

      # Best-effort usage beacon for one evaluation. Never blocks the caller
      # (the thread owns the request) and never raises into evaluation.
      def emit(feature, resource)
        return if @disabled

        if @dedupe_ms > 0
          dedupe_key = "#{feature}/#{resource}"
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
          duplicate = @mutex.synchronize do
            last = @last[dedupe_key]
            if last && (now - last) < @dedupe_ms
              true
            else
              @last[dedupe_key] = now
              false
            end
          end
          return if duplicate
        end

        dispatch("#{@prefix}/#{feature}/#{enc(resource)}")
      end

      private

      # Fire-and-forget HTTP GET on a background thread. Isolated as its own
      # method so tests can intercept it without real network/timing.
      def dispatch(url)
        Thread.new do
          begin
            uri = URI(url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = 2
            http.read_timeout = 2
            http.get(uri.request_uri)
          rescue StandardError
            # telemetry must never affect the caller
          end
        end
      end

      # encodeURIComponent-equivalent: %20 for space, %2F for slash (NOT "+").
      def enc(value)
        ERB::Util.url_encode(value.to_s)
      end
    end
  end
end
