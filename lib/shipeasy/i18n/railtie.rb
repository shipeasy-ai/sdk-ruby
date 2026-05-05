module Shipeasy
  module I18n
    # Auto-mounts ViewHelpers into ActionView when the gem is loaded inside
    # a Rails app. Skipped silently when ::Rails isn't defined (plain Ruby
    # consumers of the SDK never see the i18n surface).
    class Railtie < ::Rails::Railtie
      initializer "shipeasy.i18n.view_helpers" do
        ActiveSupport.on_load(:action_view) do
          include Shipeasy::I18n::ViewHelpers
        end
      end
    end
  end
end
