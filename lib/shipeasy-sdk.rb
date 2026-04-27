require_relative "shipeasy/sdk/version"
require_relative "shipeasy/sdk/murmur3"
require_relative "shipeasy/sdk/eval"
require_relative "shipeasy/sdk/flags_client"

module Shipeasy
  module SDK
    def self.new_client(api_key:, base_url: nil)
      FlagsClient.new(api_key: api_key, base_url: base_url)
    end
  end
end
