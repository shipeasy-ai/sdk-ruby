module Shipeasy
  module I18n
    module ViewHelpers
      def i18n_head_tags(profile: nil)
        safe_join([
          i18n_inline_data(profile: profile),
          i18n_script_tag,
        ], "\n")
      end

      def i18n_inline_data(profile: nil)
        config = Shipeasy.config
        label_file = Shipeasy::I18n::LabelFetcher.new.fetch(
          profile: profile || config.profile,
        )
        return "".html_safe unless label_file

        json_content = JSON.generate(label_file)
        content_tag(:script, json_content.html_safe, id: "i18n-data", type: "application/json")
      end

      def i18n_script_tag(hide_until_ready: false)
        config = Shipeasy.config
        attrs  = {
          src: config.loader_url,
          "data-key":     config.public_key,
          "data-profile": config.profile,
          async: true,
        }
        attrs[:"data-hide-until-ready"] = "true" if hide_until_ready
        # `content_tag`, NOT `tag` — the latter renders a self-closing
        # `<script … />`, which HTML has no such thing as: the parser treats
        # everything up to the next `</script>` as this script's body, silently
        # swallowing whatever the layout puts after us in the <head> (the
        # bootstrap tag, most often). An explicit close tag is required.
        content_tag(:script, "", attrs)
      end

      def i18n_t(key, variables = {}, profile: nil)
        config = Shipeasy.config
        # render_keys_only (default: env==test): return the key verbatim,
        # skipping value resolution + interpolation so tests assert stable data.
        return key if config.render_keys_only?

        label_file = Shipeasy::I18n::LabelFetcher.new.fetch(
          profile: profile || config.profile,
        )
        return key unless label_file && label_file["strings"]

        value = label_file["strings"][key] || key
        variables.each { |k, v| value = value.gsub("{{#{k}}}", v.to_s) }
        value
      end
    end
  end
end
