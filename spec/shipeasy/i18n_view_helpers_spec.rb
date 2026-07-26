# frozen_string_literal: true

require "spec_helper"
# view_helpers is only auto-required under Rails; load it directly for the suite.
require "shipeasy/i18n/view_helpers"

# ActionView's tag helpers are what `i18n_script_tag` / `i18n_inline_data` build
# on. `uri` must be required first: actionview <= 7.2's UrlHelper references
# `URI` at load time without requiring it, which blows up on Rubies that no
# longer autoload it. When actionview is missing entirely the block is skipped —
# the helper still ships, just unverified in that environment.
action_view_available =
  begin
    require "uri"
    require "action_view"
    require "action_view/helpers"
    true
  rescue LoadError, NameError
    false
  end

RSpec.describe "Shipeasy::I18n::ViewHelpers tag rendering", if: action_view_available do
  let(:helper) do
    Class.new do
      include ActionView::Helpers::TagHelper
      include ActionView::Helpers::OutputSafetyHelper
      include Shipeasy::I18n::ViewHelpers
    end.new
  end

  before do
    Shipeasy.configure_for_testing(flags: {})
    Shipeasy.config.public_key = "sdk_client_abc"
    Shipeasy.config.profile    = "en:prod"
  end

  describe "#i18n_script_tag" do
    # The regression this file exists for: `tag(:script, attrs)` renders
    # `<script … />`, and HTML has no self-closing script — the parser swallows
    # everything up to the next `</script>`, eating whatever the layout emits
    # after us in the <head>.
    it "closes the script element instead of self-closing it" do
      tag = helper.i18n_script_tag.to_s
      expect(tag).to end_with("></script>")
      expect(tag).not_to include("/>")
    end

    it "carries the loader src, public key and profile" do
      tag = helper.i18n_script_tag.to_s
      expect(tag).to include("/sdk/i18n/loader.js")
      expect(tag).to include('data-key="sdk_client_abc"')
      expect(tag).to include('data-profile="en:prod"')
    end

    it "opts into hide-until-ready only when asked" do
      expect(helper.i18n_script_tag.to_s).not_to include("data-hide-until-ready")
      expect(helper.i18n_script_tag(hide_until_ready: true).to_s)
        .to include('data-hide-until-ready="true"')
    end
  end

  describe "#i18n_head_tags" do
    # The inline-data half reads through LabelFetcher, which wants a booted
    # Rails (Rails.cache); hand it a label file directly so this stays a pure
    # markup assertion.
    before do
      allow_any_instance_of(Shipeasy::I18n::LabelFetcher)
        .to receive(:fetch).and_return({ "strings" => { "greeting" => "Hello" } })
    end

    it "leaves no unclosed element that would swallow following markup" do
      head = "#{helper.i18n_head_tags}\n<script src=\"/bootstrap.js\"></script>"
      expect(head).to include("i18n-data")     # both halves actually rendered
      expect(head).to include("loader.js")
      # Every <script> opened is closed: equal counts, and nothing self-closes.
      expect(head.scan("<script").length).to eq(head.scan("</script>").length)
      expect(head).not_to include("/>")
    end
  end
end
