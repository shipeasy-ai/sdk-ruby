module Shipeasy
  module SDK
    # Native runtime-environment detection.
    #
    # Used ONLY to pick the DEFAULT for outbound egress when the caller does not
    # set it explicitly:
    #   - is the SDK allowed to make network requests at all (is_network_enabled)?
    #   - is per-evaluation usage telemetry allowed (disable_telemetry)?
    #
    # Both default to ON in production and OFF everywhere else, so a local/dev/CI
    # run of an app that embeds the SDK never phones home unless it explicitly
    # opts in.
    #
    # Precedence for the production decision (mirrors the TS SDK's src/env.ts):
    #   1. A native runtime env var — SHIPEASY_ENV, then RAILS_ENV, then RACK_ENV,
    #      then APP_ENV. A value of "production"/"prod" (case-insensitive) ⇒ prod;
    #      anything else present ("development"/"staging"/"test"/…) ⇒ not prod.
    #   2. When no native env var is set (e.g. serverless / some containers), fall
    #      back to the SDK's OWN configured `env` option, which the caller sets and
    #      which itself defaults to "prod". This keeps a real production deploy
    #      "on" by default while an `env: "dev"` config stays quiet.
    #
    # The env option is always present (it defaults to "prod"), so the production
    # decision is always inferrable — the SDK never has to make the field required.
    module Env
      # Native env vars consulted, in precedence order.
      NATIVE_ENV_VARS = %w[SHIPEASY_ENV RAILS_ENV RACK_ENV APP_ENV].freeze

      module_function

      # True when the host runtime looks like a production deployment.
      # +configured_env+ is the SDK's own `env` option (dev/staging/prod); it is
      # consulted ONLY when no native runtime env var is set.
      def is_production_env(configured_env = nil)
        native = read_native_env
        return native == "production" || native == "prod" unless native.nil?

        (configured_env || "prod").to_s.strip.downcase == "prod"
      end

      # Read the first present native env var (lowercased, trimmed), or nil when
      # none of them is set to a non-empty value.
      def read_native_env
        NATIVE_ENV_VARS.each do |name|
          raw = ENV[name]
          next if raw.nil?

          v = raw.strip.downcase
          return v unless v.empty?
        end
        nil
      end
    end
  end
end
