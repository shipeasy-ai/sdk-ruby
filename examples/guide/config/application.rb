require_relative "boot"

# Load only the Rails frameworks this example actually needs. We deliberately
# skip Active Record (no database), Active Job, Action Cable, Action Mailer,
# etc. — this app just renders one static page.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
# No asset-pipeline gem (sprockets/propshaft) needed — the layout inlines the
# stylesheet from app/assets/stylesheets/guide.css.

# Bundler.require would normally pull in every gem group; we only need rails +
# puma, and we want a minimal boot, so we require the framework railties above
# explicitly instead.

module Guide
  class Application < Rails::Application
    config.load_defaults 7.1

    # This is a full-stack (HTML) app, not an API-only app.
    config.api_only = false

    # No database / Active Record in this example.
    config.generators.system_tests = nil

    # Serve static assets from /public even outside production so the example
    # works with a bare `bin/rails server`.
    config.public_file_server.enabled = true

    # We don't ship secrets; give the app a stable dev secret so sessions work.
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "shipeasy-guide-example-dev-secret-key-base-0000000000000000")
  end
end
