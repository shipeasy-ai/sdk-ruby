Rails.application.configure do
  # Settings here take precedence over those in config/application.rb.

  # The test environment is used exclusively to run the app's automated tests.
  # Eager-load nothing; reloading is irrelevant for the single-pass test run.
  config.enable_reloading = false
  config.eager_load = false

  # Show full error reports so a failing request surfaces the real exception.
  config.consider_all_requests_local = true

  # No caching layer in this example.
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Render exception templates as plain responses (don't re-raise) so an
  # integration test can assert on the response body of a failing action.
  config.action_dispatch.show_exceptions = :rescuable if config.action_dispatch.respond_to?(:show_exceptions=)

  # Disable request forgery protection in the test environment.
  config.action_controller.allow_forgery_protection = false

  # Print deprecation notices to stderr during tests.
  config.active_support.deprecation = :stderr

  # Raise on missing translations / unpermitted params to keep the example honest.
  config.action_controller.raise_on_missing_callback_actions = true if config.action_controller.respond_to?(:raise_on_missing_callback_actions=)
end
