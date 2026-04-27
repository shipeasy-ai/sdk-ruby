require "net/http"
require "uri"
require "json"
require "thread"
require_relative "eval"

module Shipeasy
  module SDK
    class FlagsClient
      DEFAULT_BASE_URL = "https://edge.shipeasy.dev"

      def initialize(api_key:, base_url: nil)
        @api_key     = api_key
        @base_url    = (base_url || DEFAULT_BASE_URL).chomp("/")
        @flags_blob  = nil
        @exps_blob   = nil
        @flags_etag  = nil
        @exps_etag   = nil
        @poll_interval = 30
        @mutex       = Mutex.new
        @timer       = nil
        @initialized = false
      end

      def init
        fetch_all
        @initialized = true
        start_poll
      end

      def init_once
        return if @initialized
        fetch_all
        @initialized = true
      end

      def destroy
        @timer&.kill
        @timer = nil
      end

      def get_flag(name, user)
        gate = @mutex.synchronize { @flags_blob&.dig("gates", name) }
        return false unless gate
        Eval.eval_gate(gate, user.transform_keys(&:to_s))
      end

      def get_config(name, decode = nil)
        entry = @mutex.synchronize { @flags_blob&.dig("configs", name) }
        return nil unless entry
        value = entry["value"]
        decode ? decode.call(value) : value
      end

      def get_experiment(name, user, default_params, decode = nil)
        flags_blob, exps_blob = @mutex.synchronize { [@flags_blob, @exps_blob] }
        exp = exps_blob&.dig("experiments", name)
        result = Eval.eval_experiment(exp, flags_blob, exps_blob, user.transform_keys(&:to_s))
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
