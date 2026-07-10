require "spec_helper"
# view_helpers is only auto-required under Rails; load it directly for the suite.
require "shipeasy/i18n/view_helpers"

# i18n render_keys_only: `i18n_t` returns the KEY instead of resolving its
# translated value, so tests/snapshots assert against stable data. Defaults on
# under env==test and off otherwise; an explicit config wins.
#
# NB: spec_helper sets SHIPEASY_ENV=production, so the env-derived default is OFF
# in this suite unless a case opts in.
RSpec.describe "i18n render_keys_only" do
  # Swap the process env for the block, restoring every touched var after.
  def with_env(vars)
    saved = {}
    vars.each do |k, v|
      saved[k] = ENV[k]
      v.nil? ? ENV.delete(k) : (ENV[k] = v)
    end
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  NATIVE = Shipeasy::SDK::Env::NATIVE_ENV_VARS
  def with_clean_env(extra = {})
    with_env(NATIVE.each_with_object({}) { |k, h| h[k] = nil }.merge(extra)) { yield }
  end

  # Bare harness that mixes in the view helper; i18n_t needs no Rails tag helpers.
  let(:helper) { Class.new { include Shipeasy::I18n::ViewHelpers }.new }

  after { Shipeasy.reset_config! }

  describe "Shipeasy::SDK::Env.is_test_env" do
    it "is true only when a native env var is exactly \"test\"" do
      with_clean_env("RAILS_ENV" => "test") { expect(Shipeasy::SDK::Env.is_test_env).to be(true) }
      with_clean_env("SHIPEASY_ENV" => "test") { expect(Shipeasy::SDK::Env.is_test_env).to be(true) }
      with_clean_env("RAILS_ENV" => "development") { expect(Shipeasy::SDK::Env.is_test_env).to be(false) }
      with_clean_env { expect(Shipeasy::SDK::Env.is_test_env).to be(false) }
    end
  end

  describe "Configuration#render_keys_only?" do
    it "defaults to the env==test signal when unset (nil)" do
      with_clean_env("RAILS_ENV" => "test") { expect(Shipeasy.config.render_keys_only?).to be(true) }
      with_clean_env("RAILS_ENV" => "production") { expect(Shipeasy.config.render_keys_only?).to be(false) }
    end

    it "an explicit true/false overrides the env default" do
      with_clean_env("RAILS_ENV" => "production") do
        Shipeasy.config.render_keys_only = true
        expect(Shipeasy.config.render_keys_only?).to be(true)
      end
      with_clean_env("RAILS_ENV" => "test") do
        Shipeasy.config.render_keys_only = false
        expect(Shipeasy.config.render_keys_only?).to be(false)
      end
    end
  end

  describe "#i18n_t" do
    it "returns the key verbatim (no fetch, no interpolation) when on" do
      with_clean_env("RAILS_ENV" => "test") do
        # The label fetcher must never be consulted on the render-keys path.
        expect(Shipeasy::I18n::LabelFetcher).not_to receive(:new)
        expect(helper.i18n_t("checkout.cta", { "name" => "Sam" })).to eq("checkout.cta")
      end
    end

    it "resolves the value and interpolates when off" do
      with_clean_env("RAILS_ENV" => "production") do
        label_file = { "strings" => { "cart.count" => "{{count}} items" } }
        fetcher = instance_double(Shipeasy::I18n::LabelFetcher, fetch: label_file)
        allow(Shipeasy::I18n::LabelFetcher).to receive(:new).and_return(fetcher)

        expect(helper.i18n_t("cart.count", { "count" => 3 })).to eq("3 items")
        # unknown key still falls back to the key itself
        expect(helper.i18n_t("missing.key")).to eq("missing.key")
      end
    end
  end
end
