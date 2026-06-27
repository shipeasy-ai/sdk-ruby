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

    # Advanced `configure` options — threaded into the global Engine `configure`
    # builds, so callers never construct an Engine themselves:
    #   - env (default "prod"): deployment tag on see() events + usage telemetry.
    #   - disable_telemetry (default false): opt out of per-eval usage telemetry.
    #   - telemetry_url: override the telemetry endpoint (rarely needed).
    #   - private_attributes: attribute keys stripped from every outbound event
    #     before it leaves the process (they still drive targeting locally).
    #   - sticky_store: pin a user's experiment group across re-buckets.
    attr_accessor :env, :disable_telemetry, :telemetry_url,
                  :private_attributes, :sticky_store

    # Fetch lifecycle for the global engine `configure` builds:
    #   - init (default true): fire a one-shot fetch fire-and-forget so the first
    #     `Shipeasy::Client.new(user).get_flag(...)` resolves against real rules
    #     (ideal for serverless / short-lived processes).
    #   - poll (default false): start the background poll (initial fetch +
    #     periodic refresh) for a long-running server, so flags stay fresh
    #     without a redeploy. Configuration owns the lifecycle — you never call
    #     `engine.init` yourself.
    attr_accessor :init, :poll

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
      @init                 = true
      @poll                 = false
      @env                  = "prod"
      @disable_telemetry    = false
      @telemetry_url        = nil
      @private_attributes   = nil
      @sticky_store         = nil

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

    # Build + register the one global engine (first-config-wins). Kicks off the
    # configured fetch lifecycle (one-shot by default; the background poll when
    # `c.poll = true`) fire-and-forget. Idempotent within a process.
    def register_engine!(cfg)
      return @engine if @engine && @engine_pid == Process.pid
      @engine_pid = Process.pid
      engine = Engine.new(
        api_key:            cfg.api_key,
        base_url:           cfg.base_url,
        env:                cfg.env,
        disable_telemetry:  cfg.disable_telemetry,
        telemetry_url:      cfg.telemetry_url,
        private_attributes: cfg.private_attributes,
        sticky_store:       cfg.sticky_store,
      )
      @engine = engine
      # Capture +engine+ in the closure (not the @engine ivar, which a concurrent
      # reset/reconfigure could nil out before the thread runs).
      if cfg.poll
        Thread.new do
          engine.init   # initial fetch + background poll thread
        rescue => e
          warn "[shipeasy] configure(poll) background poll failed: #{e.message}"
        end
      elsif cfg.init
        Thread.new do
          engine.init_once
        rescue => e
          warn "[shipeasy] configure() one-shot fetch failed: #{e.message}"
        end
      end
      engine
    end

    # ---- configure() test/offline siblings -----------------------------------
    #
    # Drop-in siblings of `Shipeasy.configure` for tests and offline evaluation.
    # Unlike `configure` (first-config-wins), these REPLACE the registered global
    # engine, so a suite can reconfigure between cases. After either, you read the
    # same way: `Shipeasy::Client.new(user)`.

    # Configure Shipeasy in TEST MODE — no api key, zero network, ever. Seed the
    # values your code under test should see via the override args, then read
    # through the ordinary `Shipeasy::Client.new(user)`:
    #
    #   Shipeasy.configure_for_testing(flags: { "new_checkout" => true })
    #   Shipeasy::Client.new({ "user_id" => "u_1" }).get_flag("new_checkout") # => true
    #
    #   flags:       { name => bool }              forced get_flag results
    #   configs:     { name => value }             forced get_config results
    #   experiments: { name => [group, params] }   forced enrolments
    #   attributes:  same transform as configure (default identity)
    def configure_for_testing(flags: nil, configs: nil, experiments: nil, attributes: nil)
      engine = Engine.for_testing
      apply_overrides(engine, flags, configs, experiments)
      install_global_engine(engine, attributes)
    end

    # Configure Shipeasy OFFLINE — evaluate the REAL rules from an in-memory
    # snapshot or a JSON file, with no network. Provide exactly one source:
    #
    #   snapshot: { "flags" => <body of /sdk/flags>, "experiments" => <body of /sdk/experiments> }
    #   path:     "snapshot.json"   (a JSON file of the same shape)
    #
    # Optional flags/configs/experiments overrides layer on top (same shapes as
    # configure_for_testing). Replaces any previously-configured engine.
    def configure_for_offline(snapshot: nil, path: nil, flags: nil, configs: nil, experiments: nil, attributes: nil)
      engine =
        if path
          Engine.from_file(path)
        elsif snapshot
          s = snapshot.transform_keys(&:to_s)
          Engine.from_snapshot(flags: s["flags"], experiments: s["experiments"])
        else
          raise Error, "Shipeasy.configure_for_offline requires snapshot: or path:"
        end
      apply_overrides(engine, flags, configs, experiments)
      install_global_engine(engine, attributes)
    end

    # ---- package-level helpers (so callers never name the Engine) -------------

    # On-the-spot overrides layered on top of whatever configure_for_testing /
    # configure_for_offline (or a live configure) set up — they win over the blob
    # until clear_overrides. Require a prior configure* call.
    def override_flag(name, value)
      require_engine("override_flag").override_flag(name, value)
      nil
    end

    def override_config(name, value)
      require_engine("override_config").override_config(name, value)
      nil
    end

    def override_experiment(name, group, params)
      require_engine("override_experiment").override_experiment(name, group, params)
      nil
    end

    # Drop EVERY override — including the seed from configure_for_testing (test
    # mode has no blob beneath); under configure_for_offline it reverts to the
    # snapshot.
    def clear_overrides
      require_engine("clear_overrides").clear_overrides
      nil
    end

    # Register a poll listener fired after a background poll fetches NEW data
    # (HTTP 200, not 304). Requires configure(poll: true). Returns an unsubscribe
    # proc. Accepts a block or any callable.
    def on_change(callable = nil, &block)
      require_engine("on_change").on_change(callable, &block)
    end

    # SSR tag helpers — delegate to the configured global engine, so you never
    # touch it. i18n_script_tag carries the PUBLIC client key (not the server
    # key); bootstrap_script_tag embeds no key.
    def i18n_script_tag(client_key, profile: "en:prod", base_url: nil)
      require_engine("i18n_script_tag").i18n_script_tag(client_key, profile: profile, base_url: base_url)
    end

    def bootstrap_script_tag(user, anon_id: nil, i18n_profile: "en:prod", base_url: nil)
      require_engine("bootstrap_script_tag").bootstrap_script_tag(
        user, anon_id: anon_id, i18n_profile: i18n_profile, base_url: base_url
      )
    end

    # see() structured error reporting — package-level, dispatched through the
    # last-constructed default client (the engine configure built). Never raises
    # into caller code; a call before any client exists warns and no-ops.
    def see(problem)
      Shipeasy::SDK.see(problem)
    end

    def see_violation(name)
      Shipeasy::SDK.see_violation(name)
    end

    def control_flow_exception(err)
      Shipeasy::SDK.control_flow_exception(err)
    end

    # Replace the registered global engine + attributes transform (used by the
    # configure_for_* siblings — unlike configure, they replace so a test suite
    # can reconfigure between cases). Returns the engine.
    def install_global_engine(engine, attributes)
      config.attributes = attributes
      @engine = engine
      @engine_pid = Process.pid
      engine
    end

    # Apply the configure_for_* override args onto an engine.
    def apply_overrides(engine, flags, configs, experiments)
      (flags || {}).each { |name, value| engine.override_flag(name, value) }
      (configs || {}).each { |name, value| engine.override_config(name, value) }
      (experiments || {}).each do |name, spec|
        group, params = spec   # spec is [group, params]
        engine.override_experiment(name, group, params)
      end
    end

    # The global engine, or raise a helpful error naming the package-level fn the
    # caller used before any configure*.
    def require_engine(fn_name)
      e = engine
      return e unless e.nil?

      raise Error, "Shipeasy.#{fn_name} called before Shipeasy.configure " \
                   "{ |c| c.api_key = … } (or configure_for_testing / " \
                   "configure_for_offline). Call one once at app boot."
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
