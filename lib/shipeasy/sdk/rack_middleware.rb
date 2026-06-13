require_relative "anon_id"

module Shipeasy
  module SDK
    # Rack middleware that mints the shared `__se_anon_id` bucketing cookie.
    #
    # For every request without a valid `__se_anon_id` cookie it mints a UUIDv4,
    # exposes it for the duration of the request, and Set-Cookies it on the
    # response. Once installed, gate/experiment evaluations with no explicit
    # user_id / anonymous_id automatically bucket on the cookie id — anonymous
    # visitors get stable, SSR/browser-consistent bucketing with zero per-call
    # wiring.
    #
    # Rails apps get this automatically (a Railtie inserts it). For Sinatra /
    # Hanami / bare Rack, add it yourself:
    #
    #   use Shipeasy::SDK::RackMiddleware
    #
    # The resolved id is also stored in the Rack env under "shipeasy.anon_id"
    # for callers that prefer to read it explicitly.
    class RackMiddleware
      ENV_KEY = "shipeasy.anon_id".freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        id, minted = read_or_mint(env)
        env[ENV_KEY] = id
        AnonId.current = id
        begin
          status, headers, body = @app.call(env)
        ensure
          # Don't leak the id onto the next request handled by this thread.
          AnonId.current = nil
        end
        set_cookie!(headers, id, env) if minted
        [status, headers, body]
      end

      private

      def read_or_mint(env)
        raw = parse_cookies(env["HTTP_COOKIE"])[AnonId::COOKIE]
        return [raw, false] if AnonId.valid?(raw)

        [AnonId.mint, true]
      end

      def parse_cookies(header)
        out = {}
        return out unless header

        header.split(/;\s*/).each do |pair|
          k, v = pair.split("=", 2)
          out[k] = v if k && v && !out.key?(k)
        end
        out
      end

      def set_cookie!(headers, id, env)
        cookie = +"#{AnonId::COOKIE}=#{id}; Path=/; Max-Age=#{AnonId::MAX_AGE}; SameSite=Lax"
        cookie << "; Secure" if https?(env)

        # Append without clobbering any Set-Cookie the app already emitted, and
        # match the existing header key's case (Rack 3 mandates lowercase).
        key = headers.keys.find { |k| k.respond_to?(:casecmp) && k.casecmp("set-cookie").zero? } || "Set-Cookie"
        existing = headers[key]
        headers[key] =
          case existing
          when nil   then cookie
          when Array then existing + [cookie]
          else "#{existing}\n#{cookie}"
          end
      end

      def https?(env)
        env["HTTPS"] == "on" ||
          env["rack.url_scheme"] == "https" ||
          env["HTTP_X_FORWARDED_PROTO"].to_s.split(",").first.to_s.strip.casecmp("https").zero?
      end
    end
  end
end
