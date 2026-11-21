require "openssl"
require "json"

module Shipeasy
  module SDK
    # Signed DevTools override cookie (`se_ov`) — verifier.
    #
    # This is a VENDORED port of the canonical implementation in the Shipeasy
    # monorepo (`packages/core/src/overrides/cookie.ts`, mirrored in sdk-ts as
    # `verifyOverrideCookie` / `extractOverrideCookie`). The format and the key
    # derivation MUST stay byte-compatible with core; a cross-impl fixture spec
    # (spec/shipeasy/request_overrides_spec.rb) guards drift.
    #
    #   cookie = base64url(JSON payload) "." base64url(HMAC-SHA256(Ks, body))
    #   Ks     = HMAC-SHA256(Kp, "se-ov-sess:v1:<nonce>:<exp>")
    #
    # Kp is the project verify key the platform serves as `overrideKey` in the
    # /sdk/flags response. No key served => overrides are never trusted (fail
    # closed). Every failure returns nil; nothing here raises to the caller.
    module OverrideCookie
      COOKIE_NAME    = "se_ov".freeze
      # Unsigned, dev-only sibling cookie (base64url JSON, no signature/expiry).
      # Only ever read when the opt-in dev_overrides option is on AND the process
      # is non-production — see Engine#dev_overrides_active?.
      DEV_COOKIE_NAME = "se_ov_dev".freeze
      # Request header carrying the same cookies (cookie-header syntax) for APIs
      # on another origin/subdomain. Rack env key: HTTP_X_SHIPEASY_OVERRIDES.
      HEADER_NAME = "X-Shipeasy-Overrides".freeze
      HEADER_ENV_KEY = "HTTP_X_SHIPEASY_OVERRIDES".freeze
      FORMAT_VERSION = 1

      EMPTY = { "gates" => {}.freeze, "configs" => {}.freeze, "exps" => {}.freeze }.freeze

      module_function

      # base64url (no padding required) -> binary String. Raises ArgumentError
      # on malformed input.
      def b64u_decode(str)
        s = str.to_s.tr("-_", "+/")
        s += "=" * ((4 - (s.length % 4)) % 4)
        s.unpack1("m0")
      end

      def b64u_encode(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      def hmac(key_bytes, msg)
        OpenSSL::HMAC.digest("SHA256", key_bytes, msg)
      end

      def secure_equal?(a, b)
        return false unless a.bytesize == b.bytesize

        diff = 0
        a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
        diff.zero?
      end

      # Verify +cookie_value+ (bare `body.sig`) against the base64url project key
      # +encoded_key+ and its +key_id+. Returns the normalised override map
      # `{ "gates" =>, "configs" =>, "exps" => }` or nil on ANY failure.
      def verify(cookie_value, encoded_key, key_id, now: Time.now.to_i)
        return nil unless cookie_value.is_a?(String) && encoded_key.is_a?(String) && !encoded_key.empty?
        return nil unless key_id.is_a?(String) && !key_id.empty?

        project_key = b64u_decode(encoded_key)

        dot = cookie_value.index(".")
        return nil if dot.nil? || dot.zero? || dot != cookie_value.rindex(".")

        body = cookie_value[0...dot]
        sig  = cookie_value[(dot + 1)..]

        payload = JSON.parse(b64u_decode(body))
        return nil unless payload.is_a?(Hash)
        return nil unless payload["v"] == FORMAT_VERSION &&
                          payload["pid"].is_a?(String) &&
                          payload["keyId"].is_a?(String) &&
                          payload["nonce"].is_a?(String) &&
                          payload["exp"].is_a?(Numeric) &&
                          payload["ov"].is_a?(Hash)
        # pid is NOT checked: the per-project Kp already binds the cookie.
        return nil unless payload["keyId"] == key_id

        exp = payload["exp"]
        return nil unless exp > now

        exp_s = exp.is_a?(Float) && exp == exp.floor ? exp.to_i : exp
        session_key = hmac(project_key, "se-ov-sess:v1:#{payload["nonce"]}:#{exp_s}")
        expected    = hmac(session_key, body)
        return nil unless secure_equal?(expected, b64u_decode(sig))

        normalize(payload["ov"])
      rescue StandardError
        nil
      end

      def normalize(ov)
        {
          "gates"   => hash_or_empty(ov["gates"]).select { |_k, v| v == true || v == false },
          "configs" => hash_or_empty(ov["configs"]),
          "exps"    => hash_or_empty(ov["exps"]).select { |_k, v| v.is_a?(String) },
        }.freeze
      end

      # Decode an UNSIGNED `se_ov_dev` value (base64url JSON of
      # `{gates, configs, exps}`). nil on any malformation; never raises.
      def decode_dev(value)
        return nil unless value.is_a?(String) && !value.empty?

        ov = JSON.parse(b64u_decode(value))
        ov.is_a?(Hash) ? normalize(ov) : nil
      rescue StandardError
        nil
      end

      # Merge verified signed overrides over dev ones, per name (signed wins).
      def merge(dev, signed)
        return signed if dev.nil?
        return dev if signed.nil?

        %w[gates configs exps].each_with_object({}) do |k, h|
          h[k] = dev[k].merge(signed[k])
        end.freeze
      end

      def hash_or_empty(value)
        value.is_a?(Hash) ? value : {}
      end

      # Pull the raw `se_ov` value out of either a bare cookie value or a full
      # `Cookie:` header (`a=1; se_ov=...; b=2`). URL-decodes the value. nil when
      # absent.
      def extract(input, name = COOKIE_NAME)
        return nil if input.nil? || !input.is_a?(String) || input.empty?

        # A bare value contains neither "=" nor ";" (base64url has no padding).
        # Anything else is a Cookie header, so an unrelated `theme=a.b` is never
        # mistaken for a bare se_ov value.
        unless input.include?("=") || input.include?(";")
          return nil if name == COOKIE_NAME && !input.include?(".")

          return input
        end

        input.split(";").each do |part|
          eq = part.index("=")
          next if eq.nil?
          next unless part[0...eq].strip == name

          return url_decode(part[(eq + 1)..].strip)
        end
        nil
      rescue StandardError
        nil
      end

      def url_decode(str)
        str.gsub(/%([0-9a-fA-F]{2})/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
      end
    end

    # Request-scoped verified override map. Stored in Fiber storage (Ruby 3.2+,
    # which child fibers inherit — so GraphQL::Dataloader / Async resolver fibers
    # still see the request's overrides) and falls back to Thread#[] (fiber-local)
    # on older Rubies. Either way concurrent requests never bleed. Set by
    # RackMiddleware or `Shipeasy.with_request_overrides`; restored in `ensure`.
    module RequestOverrides
      KEY = :shipeasy_request_overrides
      FIBER_STORAGE = Fiber.respond_to?(:[]) && Fiber.respond_to?(:[]=)

      module_function

      # The verified override map for the current request, or nil.
      def current
        FIBER_STORAGE ? Fiber[KEY] : Thread.current[KEY]
      end

      def scope(map)
        previous = current
        store(map)
        yield
      ensure
        store(previous)
      end

      def store(map)
        if FIBER_STORAGE
          Fiber[KEY] = map
        else
          Thread.current[KEY] = map
        end
      end
    end
  end
end
