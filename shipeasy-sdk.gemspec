require_relative "lib/shipeasy/sdk/version"

Gem::Specification.new do |spec|
  spec.name        = "shipeasy-sdk"
  spec.version     = Shipeasy::SDK::VERSION
  spec.summary     = "Shipeasy feature gates, runtime configs, experiments, and metrics — Ruby gem."
  spec.description = "Server SDK for Shipeasy — polls /sdk/flags and /sdk/experiments, evaluates gates and experiments locally, and forwards exposures + metrics to /collect."
  spec.authors     = ["Shipeasy, Inc."]
  spec.email       = ["sdk@shipeasy.ai"]
  spec.homepage    = "https://github.com/shipeasy-ai/sdk-ruby"

  # Source-available, non-commercial-use, permitted as a Shipeasy client.
  # Full text in LICENSE. RubyGems doesn't recognize the SPDX-style id, so
  # we surface "Nonstandard" (the documented placeholder for non-OSI
  # licenses) and link customers to the LICENSE file via metadata.
  spec.license  = "Nonstandard"
  spec.metadata = {
    "homepage_uri"          => "https://github.com/shipeasy-ai/sdk-ruby",
    "source_code_uri"       => "https://github.com/shipeasy-ai/sdk-ruby",
    "bug_tracker_uri"       => "https://github.com/shipeasy-ai/sdk-ruby/issues",
    "documentation_uri"     => "https://docs.shipeasy.ai",
    "license_file"          => "LICENSE",
    "rubygems_mfa_required" => "true",
  }

  spec.required_ruby_version = ">= 3.0"

  spec.files         = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec",   "~> 3.13"
  spec.add_development_dependency "rake",    "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.71"
end
