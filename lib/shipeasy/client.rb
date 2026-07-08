module Shipeasy
  # A lightweight, user-bound evaluation handle. Construct one per user/request
  # via its real constructor:
  #
  #   flags = Shipeasy::Client.new(current_user)
  #   flags.get_flag("new_checkout")          # NO user arg — bound at construction
  #   flags.universe("checkout").assign       # NO user arg — bound at construction
  #
  # It is cheap: it delegates every evaluation to the single global engine built
  # by `Shipeasy.configure { … }`. It does NOT open its own HTTP connection,
  # fetch, or start a poll timer.
  #
  # The configured `attributes` transform (see Shipeasy::Configuration#attributes)
  # runs ONCE here, in the constructor, against the raw user object you pass.
  # The resulting attribute hash is then enriched with the request-scoped
  # anonymous_id (when you supplied neither user_id nor anonymous_id) and bound,
  # so every getter reads the same bag.
  #
  # Raises if constructed before `Shipeasy.configure` registered an engine.
  class Client
    # The resolved attribute hash this handle evaluates against.
    attr_reader :attributes

    def initialize(user)
      engine = Shipeasy.engine
      if engine.nil?
        raise Error, "Shipeasy::Client.new(user) called before Shipeasy.configure " \
                     "{ |c| c.api_key = … }. Call Shipeasy.configure once at app boot."
      end
      @engine = engine
      # Run the configured attributes transform (default identity), then apply
      # the existing anon-id merge exactly as the per-call engine path does.
      mapped = Shipeasy.attributes_transform.call(user)
      @attributes = engine.bind_attributes(mapped)
    end

    # NOTE on fail-safe reads: the engine's runtime methods already never raise
    # (each is wrapped in Engine#safe_run). The extra defensive rescue here is a
    # belt-and-braces guard so even an unexpected failure BEFORE the engine call
    # (e.g. an @attributes deref) still returns the documented safe default
    # rather than propagating into product code.

    def get_flag(name, default: false)
      @engine.get_flag(name, @attributes, default: default)
    rescue StandardError => e
      Shipeasy::Logging.error "[shipeasy] Client#get_flag('#{name}') failed — returning default: #{e.message}"
      default
    end

    def get_flag_detail(name)
      @engine.get_flag_detail(name, @attributes)
    rescue StandardError => e
      Shipeasy::Logging.error "[shipeasy] Client#get_flag_detail('#{name}') failed — returning safe default: #{e.message}"
      Shipeasy::Engine::FlagDetail.new(value: false, reason: Shipeasy::Engine::REASON_CLIENT_NOT_READY)
    end

    # Configs are not user-scoped, but exposed here for one-stop ergonomics.
    def get_config(name, decode = nil, default: nil)
      @engine.get_config(name, decode, default: default)
    rescue StandardError => e
      Shipeasy::Logging.error "[shipeasy] Client#get_config('#{name}') failed — returning default: #{e.message}"
      default
    end

    # Assign the bound user within a universe: `client.universe("checkout").assign`.
    # A universe is a mutual-exclusion pool — the unit lands in at most one
    # experiment. Returns a reusable handle whose `assign` takes NO user arg (the
    # user is bound at construction) and forwards the bound attributes to the
    # engine. `assign` auto-logs a single deduped exposure when enrolled and
    # returns an Eval::Assignment (never raises).
    def universe(name)
      BoundUniverseHandle.new(@engine, name, @attributes)
    end

    # Returned by Client#universe. Binds the universe name AND the client's
    # already-resolved attributes, so `assign` needs no user argument.
    class BoundUniverseHandle
      def initialize(engine, name, attributes)
        @engine     = engine
        @name       = name
        @attributes = attributes
      end

      def assign
        @engine.assign_universe(@name, @attributes)
      rescue StandardError => e
        Shipeasy::Logging.error "[shipeasy] Client#universe('#{@name}').assign failed — returning not-enrolled: #{e.message}"
        Shipeasy::SDK::Eval::Assignment.new(nil, nil, {})
      end
    end

    # Killswitches are not user-scoped; forwarded straight to the engine.
    def get_killswitch(name, switch_key = nil)
      @engine.get_killswitch(name, switch_key)
    rescue StandardError => e
      Shipeasy::Logging.error "[shipeasy] Client#get_killswitch('#{name}') failed — returning false: #{e.message}"
      false
    end

    def track(event_name, props = {})
      id = @attributes["user_id"] || @attributes["anonymous_id"]
      @engine.track(id, event_name, props)
    rescue StandardError => e
      Shipeasy::Logging.error "[shipeasy] Client#track('#{event_name}') failed: #{e.message}"
      nil
    end
  end

  # Raised by Shipeasy::Client when constructed before Shipeasy.configure.
  class Error < StandardError; end
end
