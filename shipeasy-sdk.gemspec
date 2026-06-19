require_relative "lib/shipeasy/sdk/version"

Gem::Specification.new do |spec|
  spec.name        = "shipeasy-sdk"
  spec.version     = Shipeasy::SDK::VERSION
  spec.summary     = "Shipeasy feature gates, runtime configs, experiments, metrics, and i18n helpers — Ruby gem."
  spec.description = "Server SDK for Shipeasy. Polls /sdk/flags and /sdk/experiments, evaluates gates and experiments locally, forwards exposures + metrics to /collect, and (when loaded inside Rails) auto-mounts i18n_head_tags / i18n_inline_data / i18n_script_tag / i18n_t view helpers for the Shipeasy string-manager CDN."
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
  # Optional integration: `Shipeasy::OpenFeature::Provider` adapts FlagsClient to
  # the CNCF OpenFeature API. NOT a runtime dependency — the provider file
  # (lib/shipeasy/sdk/openfeature.rb) requires "open_feature/sdk" lazily, so apps
  # that don't use OpenFeature never load it. Apps that do should add
  # `gem "openfeature-sdk"` to their own Gemfile.
  #
  # The dev dependency is guarded on Ruby >= 3.4 because openfeature-sdk itself
  # requires it; the gem (and CI) still support Ruby >= 3.0, where bundler must
  # not be forced to resolve a gem it can't install. The provider spec skips when
  # the gem isn't loadable, so older Rubies stay green.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4")
    spec.add_development_dependency "openfeature-sdk", "~> 0.6"
  end
end
