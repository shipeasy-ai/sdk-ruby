require_relative "rack_middleware"

module Shipeasy
  module SDK
    # Auto-mounts RackMiddleware in a Rails app so anonymous bucketing works
    # out of the box — no manual `config.middleware.use`. Loaded only when Rails
    # is present (see lib/shipeasy-sdk.rb), so plain Ruby apps are unaffected.
    class Railtie < ::Rails::Railtie
      initializer "shipeasy.sdk.anon_id_middleware" do |app|
        app.middleware.use Shipeasy::SDK::RackMiddleware
      end
    end
  end
end
