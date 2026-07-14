require_relative "shipeasy/sdk/version"
require_relative "shipeasy/logging"
require_relative "shipeasy/config"
require_relative "shipeasy/sdk/murmur3"
require_relative "shipeasy/sdk/eval"
require_relative "shipeasy/sdk/sticky_store"
require_relative "shipeasy/engine"
require_relative "shipeasy/client"
require_relative "shipeasy/sdk/anon_id"
require_relative "shipeasy/sdk/rack_middleware"
require_relative "shipeasy/i18n/label_fetcher"

# Rails-only surface. Skipped on plain Ruby so the gem stays usable in
# non-Rails apps (Sinatra, Hanami, scripts) without pulling Rails in.
if defined?(::Rails)
  require_relative "shipeasy/i18n/view_helpers"
  require_relative "shipeasy/i18n/railtie"
  # Auto-mounts RackMiddleware so anonymous bucketing works with no config.
  require_relative "shipeasy/sdk/railtie"
end

module Shipeasy
  module SDK
    # Convenience constructor for a heavyweight Engine. Reads api_key + base_url
    # from the gem-wide config when omitted. Most apps should prefer
    # `Shipeasy.configure { … }` + `Shipeasy::Client.new(user)` instead.
    def self.new_client(api_key: Shipeasy.config.api_key, base_url: Shipeasy.config.base_url)
      Shipeasy::Engine.new(api_key: api_key, base_url: base_url)
    end

    # ---- see() module-level facade --------------------------------------
    #
    # Backed by a default client, registered when an Engine is constructed
    # (last constructed wins). Mirrors the package-level see() in the TS/Python
    # SDKs so callers can `Shipeasy::SDK.see(e).causes_the(...).to(...)` without
    # threading a client reference through every call site. A call before any
    # client exists warns and returns a no-op chain (NEVER raises).

    @see_default_client = nil
    @see_default_mutex  = Mutex.new

    # Register the client backing the module-level see() funcs. Called
    # automatically from Engine#initialize; also exposed for explicit use.
    def self.set_default_client(client)
      @see_default_mutex.synchronize { @see_default_client = client }
      client
    end

    def self.default_client
      @see_default_mutex.synchronize { @see_default_client }
    end

    # Report a caught exception via the default client. Use client.see to
    # target a specific client.
    def self.see(problem)
      client = default_client
      if client.nil?
        Shipeasy::Logging.warn "[shipeasy] see() called before a client was created — error dropped"
        return See::NullChain.new
      end
      client.see(problem)
    end

    # Report a non-exception problem via the default client.
    def self.see_violation(name)
      client = default_client
      if client.nil?
        Shipeasy::Logging.warn "[shipeasy] see_violation() called before a client was created — error dropped"
        return See::NullChain.new
      end
      client.see_violation(name)
    end

    # Mark an exception as expected control flow (reports nothing). Works
    # without a client — it only stamps the exception object.
    def self.control_flow_exception(err)
      See::ControlFlowChain.new(err)
    end

    # ---- ambient per-request see() extras -------------------------------
    #
    # Attach context that merges into every see() report firing later in this
    # request, from anywhere — no need to thread it into the rescue block:
    #
    #   Shipeasy::SDK.add_extras(order_id: order.id, tenant: tenant.slug)
    #   # ...later, somewhere else in the same request...
    #   rescue => e
    #     Shipeasy::SDK.see(e).causes_the("checkout").to("use cached prices")
    #     # ^ report carries order_id + tenant automatically
    #
    # Fiber-local, so concurrent requests never bleed. The Rack middleware
    # clears the buffer per request (Rails auto-mounts it); outside Rack, call
    # `clear_extras` when a unit of work ends. Accepts a hash and/or keywords.
    # Works with no client configured (it only writes the buffer); never raises.
    def self.add_extras(extras = nil, **kwargs)
      merged = {}
      merged.merge!(extras) if extras.is_a?(Hash)
      merged.merge!(kwargs) unless kwargs.empty?
      See::Context.add(merged)
      nil
    end

    # Drop the ambient extras buffer for the current request/context.
    def self.clear_extras
      See::Context.clear
      nil
    end
  end
end
