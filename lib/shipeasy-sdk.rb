require_relative "shipeasy/sdk/version"
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
        warn "[shipeasy] see() called before a client was created — error dropped"
        return See::NullChain.new
      end
      client.see(problem)
    end

    # Report a non-exception problem via the default client.
    def self.see_violation(name)
      client = default_client
      if client.nil?
        warn "[shipeasy] see_violation() called before a client was created — error dropped"
        return See::NullChain.new
      end
      client.see_violation(name)
    end

    # Mark an exception as expected control flow (reports nothing). Works
    # without a client — it only stamps the exception object.
    def self.control_flow_exception(err)
      See::ControlFlowChain.new(err)
    end
  end
end
