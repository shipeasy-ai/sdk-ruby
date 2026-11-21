require_relative "anon_id"
require_relative "see"
require_relative "override_cookie"

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
    #
    # It also reads the browser SDK's `X-SE-Correlation` request header into the
    # request-local see() context, so every `Shipeasy.see` fired while serving
    # the request carries that `correlation_id` — the token the platform joins
    # on to link the browser's error to the server exception behind it.
    #
    # It also scopes the signed DevTools override cookie (`se_ov`) to the request:
    # the cookie is verified ONCE here against the project key Shipeasy serves,
    # and every Shipeasy::Client read while serving the request honours it
    # (programmatic override > signed cookie > normal evaluation). Fail closed,
    # and cleared in `ensure`.
    class RackMiddleware
      ENV_KEY = "shipeasy.anon_id".freeze
      CORRELATION_HEADER = "HTTP_X_SE_CORRELATION".freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        id, minted = read_or_mint(env)
        env[ENV_KEY] = id
        AnonId.current = id
        See::Context.correlation_id = env[CORRELATION_HEADER]
        begin
          status, headers, body = RequestOverrides.scope(verified_overrides(env)) { @app.call(env) }
        ensure
          # Don't leak the id — or any ambient see() extras — onto the next
          # request handled by this thread.
          AnonId.current = nil
          See::Context.clear
        end
        set_cookie!(headers, id, env) if minted
        [status, headers, body]
      end

      private

      # Verified `se_ov` override map for this request, or nil. Cheap when the
      # cookie is absent (the common case): no engine/crypto work.
      def verified_overrides(env)
        header = env["HTTP_COOKIE"]
        return nil unless header && header.include?(OverrideCookie::COOKIE_NAME)

        engine = Shipeasy.engine
        engine && engine.verify_request_overrides(header)
      rescue StandardError
        nil
      end

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
