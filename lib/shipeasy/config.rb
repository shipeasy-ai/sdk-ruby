# Single configuration object for the Shipeasy gem.
#
# Covers both subsystems:
#   - SDK / experimentation (api_key, base_url) — drives Engine
#   - i18n / string manager (public_key, profile, cdn_base_url, ...) — drives
#     the Rails view helpers and label fetcher
#
# Usage:
#
#   Shipeasy.configure do |c|
#     c.api_key    = ENV["SHIPEASY_SERVER_KEY"]
#     c.public_key = ENV["SHIPEASY_CLIENT_KEY"]
#     c.profile    = "default"
#   end
#
# Anything not set falls back to the defaults below. The same Shipeasy.config
# is read by Engine and the Rails helpers, so there is one place to
# point environment variables at.

module Shipeasy
  class Configuration
    # ---- experimentation / SDK ----
    attr_accessor :api_key, :base_url

    # Optional transform from YOUR user object (any shape) to the Shipeasy
    # attribute hash every flag/experiment evaluation uses. A callable
    # (lambda/proc or anything responding to #call). Default = identity (the
    # user object is assumed to already BE the attribute hash). Runs once, in
    # the Shipeasy::Client constructor.
    #
    #   Shipeasy.configure do |c|
    #     c.api_key    = ENV["SHIPEASY_SERVER_KEY"]
    #     c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
    #   end
    attr_accessor :attributes

    # ---- i18n / string manager ----
    attr_accessor :public_key, :profile, :default_chunk,
                  :cdn_base_url, :loader_url,
                  :manifest_cache_ttl, :label_file_cache_ttl, :http_timeout

    def initialize
      @base_url             = "https://edge.shipeasy.dev"
      @attributes           = nil

      @profile              = "default"
      @default_chunk        = "index"
      @cdn_base_url         = "https://cdn.i18n.shipeasy.ai"
      @loader_url           = "https://cdn.i18n.shipeasy.ai/loader.js"
      @manifest_cache_ttl   = 60
      @label_file_cache_ttl = 3600
      @http_timeout         = 1
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    # Configure the gem once at boot. In addition to populating the shared
    # Configuration, this builds and registers the ONE global Shipeasy::Engine
    # (first-config-wins) from the api_key/base_url and kicks off its one-shot
    # fetch (fire-and-forget) so `Shipeasy::Client.new(user).get_flag(...)`
    # resolves against real rules with no explicit init call.
    #
    #   Shipeasy.configure do |c|
    #     c.api_key    = ENV["SHIPEASY_SERVER_KEY"]
    #     c.attributes = ->(u) { { "user_id" => u.id, "plan" => u.plan } }
    #   end
    #
    #   Shipeasy::Client.new(current_user).get_flag("new_checkout")
    #
    # Long-running servers that also want the background poll can call
    # `Shipeasy.engine.init` after configure.
    def configure
      yield config
      register_engine!(config) if config.api_key
      config
    end

    # The resolved attributes transform (callable). Default = identity, so a
    # user object that is already the attribute hash is used verbatim.
    def attributes_transform
      transform = config.attributes
      if transform.nil?
        ->(user) { user }
      elsif transform.respond_to?(:call)
        transform
      else
        raise Error, "Shipeasy.configure { |c| c.attributes = … } must be a callable (e.g. a lambda)"
      end
    end

    # The single global engine registered by configure, or nil if configure has
    # not run (or ran without an api_key). Shipeasy::Client reads this.
    def engine
      pid = Process.pid
      if @engine && @engine_pid != pid
        # Post-fork: the parent's poll thread didn't survive. Rebuild lazily
        # from the stored config in this child process.
        @engine = nil
        register_engine!(config) if config.api_key
      end
      @engine
    end

    # Build + register the one global engine (first-config-wins). Fires the
    # one-shot fetch fire-and-forget. Idempotent within a process.
    def register_engine!(cfg)
      return @engine if @engine && @engine_pid == Process.pid
      @engine_pid = Process.pid
      engine = Engine.new(api_key: cfg.api_key, base_url: cfg.base_url)
      @engine = engine
      # Capture +engine+ in the closure (not the @engine ivar, which a concurrent
      # reset/reconfigure could nil out before the thread runs).
      Thread.new do
        engine.init_once
      rescue => e
        warn "[shipeasy] configure() one-shot fetch failed: #{e.message}"
      end
      engine
    end

    # Reset the config back to defaults — primarily for tests.
    def reset_config!
      @config = nil
      @flags_pid = nil
      @flags&.destroy
      @flags = nil
      @engine&.destroy
      @engine = nil
      @engine_pid = nil
    end

    # Lazy, fork-safe singleton Engine. The first call from each
    # process spawns a fresh client + poll thread — including post-fork
    # workers under Puma's preload_app!. Callers can `Shipeasy.flags.get_flag(...)`
    # straight from a controller without holding a constant or worrying
    # about `before_worker_boot` hooks.
    #
    # Initializers stay minimal:
    #
    #   # config/initializers/shipeasy.rb
    #   Shipeasy.configure { |c| c.api_key = ENV["SHIPEASY_SERVER_KEY"] }
    #
    # The first request that touches `Shipeasy.flags.*` triggers init().
    # For serverless / Lambda where you want a single fetch with no thread,
    # build the engine explicitly: `Shipeasy::Engine.new(...).init_once`.
    #
    # NOTE: this remains a separate, polling engine from the one configure()
    # registers (Shipeasy.engine). New code should prefer the
    # Shipeasy.configure + Shipeasy::Client.new(user) front door; `Shipeasy.flags`
    # is retained for the legacy `Shipeasy.flags.get_flag(name, user)` style.
    def flags
      pid = Process.pid
      if @flags && @flags_pid != pid
        # Post-fork: parent's poll thread didn't survive. Don't destroy
        # @flags (its mutex/state is invalid in this child anyway); just
        # rebuild from scratch.
        @flags = nil
      end
      @flags ||= begin
        @flags_pid = pid
        client = Engine.new(
          api_key:  config.api_key,
          base_url: config.base_url,
        )
        client.init
        client
      end
    end
  end
end
