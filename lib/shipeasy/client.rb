module Shipeasy
  # A lightweight, user-bound evaluation handle. Construct one per user/request
  # via its real constructor:
  #
  #   flags = Shipeasy::Client.new(current_user)
  #   flags.get_flag("new_checkout")          # NO user arg — bound at construction
  #   flags.get_experiment("price_test", { price: 9 })
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

    def get_flag(name, default: false)
      @engine.get_flag(name, @attributes, default: default)
    end

    def get_flag_detail(name)
      @engine.get_flag_detail(name, @attributes)
    end

    # Configs are not user-scoped, but exposed here for one-stop ergonomics.
    def get_config(name, decode = nil, default: nil)
      @engine.get_config(name, decode, default: default)
    end

    def get_experiment(name, default_params, decode = nil)
      @engine.get_experiment(name, @attributes, default_params, decode)
    end

    # Killswitches are not user-scoped; forwarded straight to the engine.
    def get_killswitch(name, switch_key = nil)
      @engine.get_killswitch(name, switch_key)
    end
  end

  # Raised by Shipeasy::Client when constructed before Shipeasy.configure.
  class Error < StandardError; end
end
