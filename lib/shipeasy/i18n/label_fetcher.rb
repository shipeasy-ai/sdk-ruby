require "net/http"
require "uri"
require "json"
require "digest"

module Shipeasy
  module I18n
    class LabelFetcher
      MANIFEST_KEY_PREFIX = "i18n:manifest:"
      LABEL_KEY_PREFIX    = "i18n:label:"

      def initialize(config = Shipeasy.config)
        @config = config
      end

      def fetch(profile: @config.profile, chunk: @config.default_chunk)
        manifest = fetch_manifest(profile)
        return nil unless manifest

        file_url = manifest[chunk]
        return nil unless file_url

        fetch_label_file(file_url)
      rescue => e
        ::Rails.logger.warn("[Shipeasy::I18n] Failed to fetch labels: #{e.message}") if defined?(::Rails)
        nil
      end

      private

      def fetch_manifest(profile)
        cache_key = "#{MANIFEST_KEY_PREFIX}#{@config.public_key}:#{profile}"
        cache_fetch(cache_key, @config.manifest_cache_ttl) do
          url = "#{@config.cdn_base_url}/labels/#{@config.public_key}/#{profile}/manifest.json"
          http_get_json(url)
        end
      end

      def fetch_label_file(url)
        cache_key = "#{LABEL_KEY_PREFIX}#{Digest::MD5.hexdigest(url)}"
        cache_fetch(cache_key, @config.label_file_cache_ttl) do
          http_get_json(url)
        end
      end

      def cache_fetch(key, ttl, &block)
        if defined?(::Rails) && ::Rails.cache
          ::Rails.cache.fetch(key, expires_in: ttl.seconds, &block)
        else
          block.call
        end
      end

      def http_get_json(url)
        uri  = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = (uri.scheme == "https")
        http.open_timeout = @config.http_timeout
        http.read_timeout = @config.http_timeout
        res  = http.get(uri.request_uri, { "Accept" => "application/json" })
        raise "HTTP #{res.code} fetching #{url}" unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      end
    end
  end
end
