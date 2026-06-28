Rails.application.configure do
  # Settings here take precedence over those in config/application.rb.

  # In development, code is not eager loaded, and is reloaded on every request.
  config.enable_reloading = true
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # No caching layer in this example.
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Serve static files from /public.
  config.public_file_server.enabled = true

  # Raise on missing translations / unpermitted params to keep the example honest.
  config.action_controller.raise_on_missing_callback_actions = true if config.action_controller.respond_to?(:raise_on_missing_callback_actions=)

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Highlight code that triggered database queries in logs — n/a here (no DB),
  # but harmless to leave off.
  config.action_view.annotate_rendered_view_with_filenames = true if config.action_view.respond_to?(:annotate_rendered_view_with_filenames=)
end
