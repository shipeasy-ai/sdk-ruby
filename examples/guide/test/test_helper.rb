# frozen_string_literal: true

# Boot the Rails app in the test environment, then load the standard Rails
# test harness (Minitest via ActiveSupport::TestCase / ActionDispatch::*).
ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # This minimal example has no fixtures / parallelism to configure.
  end
end
