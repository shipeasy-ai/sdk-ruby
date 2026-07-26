require "net/http"
require "uri"
require "json"

module Shipeasy
  module I18n
    class LabelFetcher
      LABEL_KEY_PREFIX = "i18n:strings:"

      def initialize(config = Shipeasy.config)
        @config = config
      end

      # Fetch a profile's published strings.
      #
      # Publishing is PROFILE-WIDE: the whole profile is snapshotted into one
      # blob and served from a single endpoint, so there is no sub-profile unit
      # to select. This used to fetch a `manifest.json` and index it by "chunk"
      # — an endpoint the worker never served, so SSR i18n always came back
      # empty and pages rendered raw `{{var}}` templates and key fallbacks.
      # (sdk-ts hit the same bug and moved to this endpoint; see its
      # `fetchLabelsForSSR`.)
      #
      # Returns the `{ "locale" => ..., "strings" => { key => value } }` blob,
      # or nil when it cannot be fetched.
      def fetch(profile: @config.profile)
        cache_key = "#{LABEL_KEY_PREFIX}#{@config.public_key}:#{profile}"
        cache_fetch(cache_key, @config.label_file_cache_ttl) do
          url = "#{@config.cdn_base_url}/sdk/i18n/strings?profile=#{URI.encode_www_form_component(profile)}"
          http_get_json(url, { "X-SDK-Key" => @config.public_key.to_s })
        end
      rescue => e
        ::Rails.logger.warn("[Shipeasy::I18n] Failed to fetch labels: #{e.message}") if defined?(::Rails)
        nil
      end

      private

      def cache_fetch(key, ttl, &block)
        if defined?(::Rails) && ::Rails.cache
          ::Rails.cache.fetch(key, expires_in: ttl.seconds, &block)
        else
          block.call
        end
      end

      def http_get_json(url, headers = {})
        uri  = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = @config.http_timeout
        http.read_timeout = @config.http_timeout
        res  = http.get(uri.request_uri, { "Accept" => "application/json" }.merge(headers))
        raise "HTTP #{res.code} fetching #{url}" unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      end
    end
  end
end
