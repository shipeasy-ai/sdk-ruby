# frozen_string_literal: true

# Optional Admin API client for the Shipeasy Ruby SDK.
#
# This subpackage is OFF by default: the main `shipeasy-sdk` entrypoint never
# requires it, and its HTTP dependency (`faraday`) is an optional development
# dependency — so `require "shipeasy-sdk"` never pulls it in. Require it
# explicitly when you want to *administer* resources (create gates, start
# experiments, …) from server code:
#
#   require "faraday"
#   require "shipeasy/admin"
#
#   admin = Shipeasy::Admin::Client.new(
#     api_key: ENV.fetch("SHIPEASY_ADMIN_KEY"),
#     project_id: ENV.fetch("SHIPEASY_PROJECT_ID"),
#   )
#   admin.ops.create_public_bug(title: "Checkout 500s on Safari")
#
# Everything under `Shipeasy::Admin::Generated` (lib/shipeasy_admin*) is produced
# by scripts/gen_admin.sh from the OpenAPI spec and must not be edited by hand.
# `Client` is a thin auth/scoping wrapper; it does NOT add name->id resolution or
# percent->basis-point conversion (that facade lives in the Shipeasy CLI/MCP). The
# surface here is the raw, 1:1-with-the-spec REST API.

# Define the namespace BEFORE loading the generated client: its files use the
# compact `module Shipeasy::Admin::Generated` form, which requires Shipeasy::Admin
# to already exist (and `require "shipeasy/admin"` may run without the main SDK).
module Shipeasy
  module Admin
  end
end

require "shipeasy_admin" # the generated client (loads faraday transitively)

module Shipeasy
  module Admin
    # Programmatic client for the Shipeasy Admin REST API. Each resource group is
    # a lazily-constructed, memoized reader whose methods map 1:1 to the OpenAPI
    # operations.
    #
    # This is the LEAN admin surface: the vendored spec is the dedicated
    # server-SDK contract (marketplace/openapi/spec/openapi-sdk.yaml in the
    # monorepo), seven operations across three capabilities — file a public
    # ticket (#ops), toggle a kill switch (#killswitch), manage a flag's
    # whitelist (#flags). The rest of the admin API (experiments, metrics,
    # events, configs, i18n, projects, …) is intentionally NOT here; reach it
    # through the Shipeasy CLI or MCP, which consume the complete spec.
    class Client
      # Friendly reader name => generated Api class.
      APIS = {
        flags: Generated::FlagsApi,
        killswitch: Generated::KillswitchApi,
        ops: Generated::OpsApi,
      }.freeze

      # Two of the seven operations — #ops.create_public_bug and
      # #ops.create_public_feature_request — are the PUBLIC ticket intake. They
      # live on the Shipeasy edge worker and authenticate with a CLIENT key
      # (`X-SDK-Key`), not the admin key, so pass `client_key:` if you want to
      # call them. The generated client routes them to the edge host itself.
      #
      # @param api_key [String] admin SDK key, sent as `Authorization: Bearer <api_key>`.
      # @param project_id [String, nil] optional project id sent as the `X-Project-Id`
      #   header on every request. Operations also accept an explicit `x_project_id:`
      #   argument to override per call.
      # @param base_url [String] admin API base URL. Defaults to https://shipeasy.ai
      #   (the spec's production server); use http://localhost:3000 for local dev.
      #   The public intake ignores it — it carries its own server list.
      # @param client_key [String, nil] client SDK key (`sdk_client_…`) carrying the
      #   `tickets:public_create` scope, sent as `X-SDK-Key` on the two public
      #   ticket operations. Optional — omit it if you only use the admin ones.
      def initialize(api_key:, project_id: nil, base_url: "https://shipeasy.ai", client_key: nil)
        config = Generated::Configuration.new
        config.access_token = api_key
        config.api_key["clientSdkKey"] = client_key if client_key
        scheme, _, host = base_url.rpartition("://")
        config.scheme = scheme unless scheme.empty?
        config.host = host.empty? ? base_url : host

        @api_client = Generated::ApiClient.new(config)
        @api_client.default_headers["X-Project-Id"] = project_id if project_id
        @apis = {}
      end

      # The underlying generated ApiClient (advanced/escape hatch).
      attr_reader :api_client

      APIS.each_key do |name|
        define_method(name) { @apis[name] ||= APIS.fetch(name).new(@api_client) }
      end
    end
  end
end
