require "net/http"
require "uri"
require "json"
require "thread"
require_relative "eval"
require_relative "telemetry"
require_relative "anon_id"

module Shipeasy
  module SDK
    class FlagsClient
      DEFAULT_BASE_URL = "https://edge.shipeasy.dev"

      def initialize(api_key:, base_url: nil, env: "prod", disable_telemetry: false, telemetry_url: nil, test_mode: false)
        @api_key     = api_key
        @base_url    = (base_url || DEFAULT_BASE_URL).chomp("/")
        # Test mode: no network, ever. init/init_once/track become no-ops and
        # evaluation answers come purely from local overrides. Built via the
        # FlagsClient.for_testing factory; see clear_overrides / override_*.
        @test_mode   = test_mode
        # Per-evaluation usage telemetry. ON by default; pass
        # disable_telemetry: true to opt out. See telemetry.rb.
        @telemetry = Telemetry.new(
          endpoint: telemetry_url || Telemetry::DEFAULT_TELEMETRY_URL,
          sdk_key: api_key,
          side: "server",
          env: env,
          disabled: disable_telemetry,
        )
        @flags_blob  = nil
        @exps_blob   = nil
        @flags_etag  = nil
        @exps_etag   = nil
        @poll_interval = 30
        @mutex       = Mutex.new
        @timer       = nil
        @initialized = false
        # Statsig-style local overrides. Keyed by resource name; an override,
        # when present, short-circuits the corresponding getter. Usable on any
        # client (test or live) for deterministic tests / local development.
        @flag_overrides   = {}
        @config_overrides = {}
        @exp_overrides    = {}
      end

      # Build a no-network, immediately-usable client for tests. Telemetry is
      # disabled, init/init_once/track are no-ops (never fetch), and no api_key
      # is required. Seed it with override_flag / override_config /
      # override_experiment, then call the normal getters.
      def self.for_testing(env: "prod")
        new(
          api_key: "test",
          env: env,
          disable_telemetry: true,
          test_mode: true,
        )
      end

      def init
        return if @test_mode
        fetch_all
        @initialized = true
        start_poll
      end

      def init_once
        return if @test_mode
        return if @initialized
        fetch_all
        @initialized = true
      end

      # --- Local overrides -------------------------------------------------
      # An override wins over the fetched blob in the matching getter. Setters
      # are mutex-guarded so they're safe to call alongside background polling
      # on a live client.

      def override_flag(name, value)
        @mutex.synchronize { @flag_overrides[name.to_s] = (value ? true : false) }
        self
      end

      def override_config(name, value)
        @mutex.synchronize { @config_overrides[name.to_s] = value }
        self
      end

      def override_experiment(name, group, params)
        @mutex.synchronize do
          @exp_overrides[name.to_s] = { group: group, params: params }
        end
        self
      end

      def clear_overrides
        @mutex.synchronize do
          @flag_overrides.clear
          @config_overrides.clear
          @exp_overrides.clear
        end
        self
      end

      def destroy
        @timer&.kill
        @timer = nil
      end

      def get_flag(name, user)
        key = name.to_s
        override = @mutex.synchronize { @flag_overrides[key] if @flag_overrides.key?(key) }
        return override unless override.nil?

        @telemetry.emit("gate", name)
        gate = @mutex.synchronize { @flags_blob&.dig("gates", name) }
        return false unless gate
        Eval.eval_gate(gate, with_anon_id(user))
      end

      def get_config(name, decode = nil)
        key = name.to_s
        has_override, override = @mutex.synchronize do
          [@config_overrides.key?(key), @config_overrides[key]]
        end
        if has_override
          return decode ? decode.call(override) : override
        end

        @telemetry.emit("config", name)
        entry = @mutex.synchronize { @flags_blob&.dig("configs", name) }
        return nil unless entry
        value = entry["value"]
        decode ? decode.call(value) : value
      end

      def get_experiment(name, user, default_params, decode = nil)
        key = name.to_s
        override = @mutex.synchronize { @exp_overrides[key] }
        if override
          params = override[:params]
          params = decode.call(params) if decode
          return Eval::ExperimentResult.new(
            in_experiment: true,
            group: override[:group],
            params: params,
          )
        end

        @telemetry.emit("experiment", name)
        flags_blob, exps_blob = @mutex.synchronize { [@flags_blob, @exps_blob] }
        exp = exps_blob&.dig("experiments", name)
        result = Eval.eval_experiment(exp, flags_blob, exps_blob, with_anon_id(user))
        result.params ||= default_params

        if result.in_experiment && decode
          begin
            result = Eval::ExperimentResult.new(
              in_experiment: true,
              group: result.group,
              params: decode.call(result.params),
            )
          rescue => e
            warn "[shipeasy] get_experiment('#{name}') decode failed: #{e.message}"
            return Eval::ExperimentResult.new(in_experiment: false, group: "control", params: default_params)
          end
        end

        result
      end

      def track(user_id, event_name, props = {})
        return if @test_mode

        payload = JSON.generate({
          events: [{
            type: "metric",
            event_name: event_name,
            user_id: user_id.to_s,
            ts: (Time.now.to_f * 1000).to_i,
            **(props.empty? ? {} : { properties: props }),
          }],
        })

        Thread.new do
          post("/collect", payload)
        rescue => e
          warn "[shipeasy] track failed: #{e.message}"
        end
      end

      private

      # Normalise the user hash to string keys and, when the caller passed no
      # explicit unit, default anonymous_id to the request's __se_anon_id (set by
      # RackMiddleware). Lets `get_flag("x", {})` bucket anonymous traffic with
      # zero per-call wiring. A caller-supplied user_id/anonymous_id always wins.
      def with_anon_id(user)
        u = user.transform_keys(&:to_s)
        has_unit = !blank?(u["user_id"]) || !blank?(u["anonymous_id"])
        unless has_unit
          anon = AnonId.current
          u["anonymous_id"] = anon if anon
        end
        u
      end

      def blank?(v)
        v.nil? || v == ""
      end

      def start_poll
        @timer = Thread.new do
          loop do
            sleep(@poll_interval)
            begin
              fetch_all
            rescue => e
              warn "[shipeasy] background poll failed: #{e.message}"
            end
          end
        end
        @timer.abort_on_exception = false
      end

      def fetch_all
        flags_thread = Thread.new { fetch_flags }
        fetch_exps
        interval = flags_thread.value
        if interval && interval != @poll_interval
          @poll_interval = interval
        end
      end

      def fetch_flags
        headers = { "X-SDK-Key" => @api_key }
        headers["If-None-Match"] = @flags_etag if @flags_etag
        res = http_get("/sdk/flags", headers)
        interval = (res["X-Poll-Interval"] || "30").to_i
        return interval if res.code == "304"
        raise "GET /sdk/flags returned #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        etag = res["ETag"]
        blob = JSON.parse(res.body)
        @mutex.synchronize do
          @flags_etag = etag if etag
          @flags_blob = blob
        end
        interval
      end

      def fetch_exps
        headers = { "X-SDK-Key" => @api_key }
        headers["If-None-Match"] = @exps_etag if @exps_etag
        res = http_get("/sdk/experiments", headers)
        return if res.code == "304"
        raise "GET /sdk/experiments returned #{res.code}" unless res.is_a?(Net::HTTPSuccess)
        etag = res["ETag"]
        blob = JSON.parse(res.body)
        @mutex.synchronize do
          @exps_etag = etag if etag
          @exps_blob = blob
        end
      end

      def http_get(path, headers = {})
        uri  = URI.parse("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl     = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10
        http.get(uri.request_uri, headers)
      end

      def post(path, body)
        uri  = URI.parse("#{@base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = 5
        http.read_timeout = 10
        http.post(uri.request_uri, body, { "X-SDK-Key" => @api_key, "Content-Type" => "text/plain" })
      end
    end
  end
end
