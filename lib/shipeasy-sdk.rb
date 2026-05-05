require_relative "shipeasy/sdk/version"
require_relative "shipeasy/config"
require_relative "shipeasy/sdk/murmur3"
require_relative "shipeasy/sdk/eval"
require_relative "shipeasy/sdk/flags_client"
require_relative "shipeasy/i18n/label_fetcher"

# Rails-only surface. Skipped on plain Ruby so the gem stays usable in
# non-Rails apps (Sinatra, Hanami, scripts) without pulling Rails in.
if defined?(::Rails)
  require_relative "shipeasy/i18n/view_helpers"
  require_relative "shipeasy/i18n/railtie"
end

module Shipeasy
  module SDK
    # Convenience constructor. Reads api_key + base_url from the gem-wide
    # config when omitted, so a single `Shipeasy.configure { … }` block at
    # boot is enough.
    def self.new_client(api_key: Shipeasy.config.api_key, base_url: Shipeasy.config.base_url)
      FlagsClient.new(api_key: api_key, base_url: base_url)
    end
  end
end
