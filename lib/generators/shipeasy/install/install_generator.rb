# frozen_string_literal: true

require "rails/generators/base"

module Shipeasy
  module Generators
    # `rails generate shipeasy:install`
    #
    # Scaffolds Shipeasy into a Rails app the Rails way:
    #
    #   - writes config/initializers/shipeasy.rb (the single Shipeasy.configure call)
    #   - with --i18n, sets the public client key in that initializer AND injects
    #     `<%= i18n_head_tags %>` into the application layout's <head>
    #   - prints the keys / credentials next steps
    #
    # The gem's Railties already auto-mount the anon-id Rack middleware and the
    # i18n view helpers, so this generator never touches middleware wiring — it
    # only creates the things an app must own: the initializer, the layout tag,
    # and your keys.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Create config/initializers/shipeasy.rb (and, with --i18n, wire the i18n view helpers)."

      class_option :i18n, type: :boolean, default: false,
        desc: "Also enable i18n: set the public client key and inject i18n_head_tags into the app layout"
      class_option :poll, type: :boolean, default: true,
        desc: "Use the background poll (long-running server). Pass --no-poll for a serverless one-shot fetch"

      APP_LAYOUT = "app/views/layouts/application.html.erb"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/shipeasy.rb"
      end

      def inject_layout_helpers
        return unless options[:i18n]

        unless layout_exists?
          say_status :skip, "#{APP_LAYOUT} not found — add <%= i18n_head_tags %> to your <head> by hand", :yellow
          return
        end

        if layout_already_wired?
          say_status :identical, "#{APP_LAYOUT} already has i18n_head_tags", :blue
          return
        end

        # Insert just before the closing </head>, picking up its indentation.
        inject_into_file APP_LAYOUT, "<%= i18n_head_tags %>\n  ", before: "</head>"
      end

      def print_next_steps
        say ""
        say "  Shipeasy installed → config/initializers/shipeasy.rb", :green
        say ""
        say "  Next steps:"
        say "    1. Mint your keys: https://app.shipeasy.ai → Settings → SDK keys"
        say "    2. Provide them (pick one):"
        say "         • ENV — set SHIPEASY_SERVER_KEY#{options[:i18n] ? " and SHIPEASY_CLIENT_KEY" : ""}"
        say "         • Rails credentials — bin/rails credentials:edit, then read"
        say "           them from Rails.application.credentials in the initializer"
        if options[:i18n]
          say "    3. i18n_head_tags is wired into your layout — run the Shipeasy"
          say "       i18n install to create your en:prod profile, then translate."
        end
        say ""
        say "  Read a flag anywhere per request:"
        say "    Shipeasy::Client.new(current_user).get_flag(\"new_checkout\")"
        say ""
        say "  Docs: https://docs.shipeasy.ai", :cyan
        say ""
      end

      private

      def layout_exists?
        File.exist?(File.join(destination_root, APP_LAYOUT))
      end

      def layout_already_wired?
        File.read(File.join(destination_root, APP_LAYOUT)).include?("i18n_head_tags")
      end
    end
  end
end
