# frozen_string_literal: true

# OpenFeature provider for Shipeasy (server paradigm).
#
# Lets apps standardized on the CNCF OpenFeature API plug Shipeasy in as the
# backing provider. This file is intentionally NOT required by the main
# `shipeasy-sdk` entrypoint — `openfeature-sdk` is an optional development
# dependency, so the provider is loaded lazily and the gem is required from
# inside this file. Require it explicitly when you want the provider:
#
#   require "open_feature/sdk"
#   require "shipeasy/sdk/openfeature"
#
#   client = Shipeasy::Engine.new(api_key: ENV.fetch("SHIPEASY_SERVER_KEY"))
#   client.init
#
#   OpenFeature::SDK.configure do |config|
#     config.set_provider(Shipeasy::OpenFeature::Provider.new(client))
#   end
#
#   of = OpenFeature::SDK.build_client
#   on = of.fetch_boolean_value(flag_key: "new_checkout", default_value: false,
#                               evaluation_context: OpenFeature::SDK::EvaluationContext.new(targeting_key: "u1"))
#
# Pure adapter over `Shipeasy::Engine` — no change to evaluation. Boolean values map
# onto gates (`get_flag_detail`); string/number/integer/float/object map onto
# dynamic configs (`get_config`).

# `openfeature-sdk` (module `OpenFeature::SDK::Provider`) is an optional dep.
# Require it lazily so the main SDK never pulls it in; surface a clear error if
# the consumer forgot to add it.
begin
  require "open_feature/sdk"
rescue LoadError => e
  raise LoadError, "shipeasy/sdk/openfeature requires the `openfeature-sdk` gem " \
                   "(module OpenFeature::SDK::Provider). Add it to your Gemfile: " \
                   "gem \"openfeature-sdk\". (#{e.message})"
end

require_relative "../engine"

module Shipeasy
  module OpenFeature
    # Shipeasy OpenFeature provider (server paradigm). Wraps a
    # `Shipeasy::Engine`; evaluation is local against the cached blob,
    # so resolution is effectively synchronous.
    class Provider
      OF = ::OpenFeature::SDK::Provider

      # Shipeasy `FlagDetail#reason` → [OpenFeature reason, optional error_code].
      # Per the cross-SDK contract (doc 20):
      #   RULE_MATCH       → TARGETING_MATCH
      #   DEFAULT          → DEFAULT
      #   OFF              → DISABLED
      #   OVERRIDE         → STATIC
      #   FLAG_NOT_FOUND   → ERROR (error_code FLAG_NOT_FOUND)
      #   CLIENT_NOT_READY → ERROR (error_code PROVIDER_NOT_READY)
      REASON_MAP = {
        Shipeasy::Engine::REASON_RULE_MATCH       => [OF::Reason::TARGETING_MATCH, nil],
        Shipeasy::Engine::REASON_DEFAULT          => [OF::Reason::DEFAULT, nil],
        Shipeasy::Engine::REASON_OFF              => [OF::Reason::DISABLED, nil],
        Shipeasy::Engine::REASON_OVERRIDE         => [OF::Reason::STATIC, nil],
        Shipeasy::Engine::REASON_FLAG_NOT_FOUND   => [OF::Reason::ERROR, OF::ErrorCode::FLAG_NOT_FOUND],
        Shipeasy::Engine::REASON_CLIENT_NOT_READY => [OF::Reason::ERROR, OF::ErrorCode::PROVIDER_NOT_READY],
      }.freeze

      attr_reader :metadata

      def initialize(client)
        @client = client
        @metadata = OF::ProviderMetadata.new(name: "shipeasy").freeze
      end

      # OpenFeature lifecycle (optional but supported): fetch the blob once and
      # tear down the poll thread on shutdown.
      def init(_evaluation_context = nil)
        @client.init_once
      end

      def shutdown
        @client.destroy
      end

      # --- Boolean → gate ------------------------------------------------------

      def fetch_boolean_value(flag_key:, default_value:, evaluation_context: nil)
        user = to_user(evaluation_context)
        detail = @client.get_flag_detail(flag_key, user)
        of_reason, error_code = REASON_MAP.fetch(detail.reason, [OF::Reason::UNKNOWN, nil])

        if error_code
          OF::ResolutionDetails.new(value: default_value, reason: of_reason, error_code: error_code)
        else
          OF::ResolutionDetails.new(value: detail.value, reason: of_reason)
        end
      rescue => e
        OF::ResolutionDetails.new(
          value: default_value, reason: OF::Reason::ERROR,
          error_code: OF::ErrorCode::GENERAL, error_message: e.message,
        )
      end

      # --- String / number / integer / float / object → dynamic config --------

      def fetch_string_value(flag_key:, default_value:, evaluation_context: nil)
        resolve_config(flag_key, default_value) { |v| v.is_a?(String) }
      end

      def fetch_number_value(flag_key:, default_value:, evaluation_context: nil)
        resolve_config(flag_key, default_value) { |v| numeric?(v) }
      end

      def fetch_integer_value(flag_key:, default_value:, evaluation_context: nil)
        resolve_config(flag_key, default_value) { |v| v.is_a?(Integer) }
      end

      def fetch_float_value(flag_key:, default_value:, evaluation_context: nil)
        resolve_config(flag_key, default_value) { |v| numeric?(v) }
      end

      def fetch_object_value(flag_key:, default_value:, evaluation_context: nil)
        resolve_config(flag_key, default_value) { |v| v.is_a?(Hash) || v.is_a?(Array) }
      end

      # OpenFeature `track()` → Shipeasy `track()`. No-ops without a targeting key.
      def track(tracking_event_name, evaluation_context: nil, details: {})
        ctx = normalize_context(evaluation_context)
        user_id = ctx["targeting_key"] || ctx["user_id"]
        return if user_id.nil? || user_id.to_s.empty?

        props = details.is_a?(Hash) ? details : {}
        @client.track(user_id, tracking_event_name, props)
      end

      private

      # A sentinel distinct from any legitimate config value so we can tell an
      # absent key (→ DEFAULT) from a present-but-nil value.
      ABSENT = Object.new
      private_constant :ABSENT

      # Resolve a dynamic config and type-check it. Absent key → DEFAULT;
      # present but failing the type predicate → TYPE_MISMATCH; otherwise
      # TARGETING_MATCH with the value. Both return the default for the value.
      def resolve_config(flag_key, default_value)
        raw = @client.get_config(flag_key, nil, default: ABSENT)

        if raw.equal?(ABSENT)
          return OF::ResolutionDetails.new(value: default_value, reason: OF::Reason::DEFAULT)
        end

        unless yield(raw)
          return OF::ResolutionDetails.new(
            value: default_value, reason: OF::Reason::ERROR,
            error_code: OF::ErrorCode::TYPE_MISMATCH,
            error_message: "config value #{raw.inspect} does not match the requested type",
          )
        end

        OF::ResolutionDetails.new(value: raw, reason: OF::Reason::TARGETING_MATCH)
      rescue => e
        OF::ResolutionDetails.new(
          value: default_value, reason: OF::Reason::ERROR,
          error_code: OF::ErrorCode::GENERAL, error_message: e.message,
        )
      end

      def numeric?(value)
        # Booleans are Integers' cousins in some langs but not Ruby; exclude
        # them explicitly so `true` never satisfies a number/float request.
        return false if value == true || value == false

        value.is_a?(Numeric)
      end

      # Build a Shipeasy user hash from an OpenFeature EvaluationContext:
      # `targeting_key` → `user_id`; every other field carried through verbatim
      # for targeting. Accepts a real EvaluationContext, a plain Hash, or nil.
      def to_user(evaluation_context)
        ctx = normalize_context(evaluation_context)
        targeting_key = ctx["targeting_key"]
        rest = ctx.reject { |k, _| k == "targeting_key" }
        user = rest
        if targeting_key.is_a?(String) && !targeting_key.empty?
          user = user.merge("user_id" => targeting_key)
        end
        user
      end

      # Coerce any of {EvaluationContext, Hash, nil} into a string-keyed Hash.
      def normalize_context(evaluation_context)
        return {} if evaluation_context.nil?

        if evaluation_context.respond_to?(:fields)
          evaluation_context.fields.transform_keys(&:to_s)
        elsif evaluation_context.is_a?(Hash)
          evaluation_context.transform_keys(&:to_s)
        else
          {}
        end
      end
    end
  end
end
