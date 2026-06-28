# frozen_string_literal: true

require "test_helper"
require "shipeasy-sdk"

# Integration test for the guide page (the `root "guide#index"` route).
#
# It demonstrates the SDK's TESTING setup: `Shipeasy.configure_for_testing`
# seeds every value Shipeasy would return — with ZERO network and no API key —
# and the app then reads through the ordinary `Shipeasy::Client.new(user)`, the
# same call production code uses (see docs/pages/testing.md).
#
# Because this is an `ActionDispatch::IntegrationTest`, `get "/"` dispatches the
# request IN-PROCESS, so the engine seeded by `configure_for_testing` in `setup`
# is the very engine the controller would evaluate against.
#
# ──────────────────────────────────────────────────────────────────────────
#  ⚠  EXPECTED: the value assertions below currently FAIL.
#
#  The example controller (app/controllers/guide_controller.rb) renders
#  hardcoded PLACEHOLDERS and is NOT wired to the SDK, so the mocked values do
#  not yet appear in the HTML. That is intentional — this test is the contract
#  the controller must satisfy once the `# TODO: once shipeasy-sdk is installed`
#  blocks are swapped in. Everything else (booting Rails, hitting the route,
#  getting HTML back) works today.
# ──────────────────────────────────────────────────────────────────────────
class GuidePageTest < ActionDispatch::IntegrationTest
  # The key names mirror those in GuideController#index. The *values*, by
  # contrast, are DISTINCTIVE sentinels chosen NOT to collide with the
  # controller's current hardcoded placeholders — so the page value assertions
  # genuinely exercise the SDK→page path. Sourcing the mocks from the placeholders
  # would make the assertions tautological (they'd "pass" because the placeholder
  # string happened to match, not because the SDK value flowed through). With
  # sentinels, the page assertions pass only once the controller actually reads
  # from Shipeasy — until then they fail, which is the expected current state.
  FLAG_KEY   = "new_checkout"
  CONFIG_KEY = "billing_copy"
  EXP_KEY    = "checkout_button"

  CONFIG_VALUE     = { "headline" => "Welcome aboard 🚀", "cta" => "Start free trial" }.freeze
  EXP_GROUP        = "treatment"
  EXP_PARAMS       = { "color" => "#0ea5e9", "label" => "Checkout now" }.freeze

  def setup
    # Mock every value Shipeasy returns. `configure_for_testing` REPLACES any
    # previously-configured engine, so each test reseeds freely with no reset
    # boilerplate. The override shapes (per docs/pages/testing.md):
    #   flags       => { name => bool }
    #   configs     => { name => value }
    #   experiments => { name => [group, params] }
    Shipeasy.configure_for_testing(
      flags:       { FLAG_KEY => true },
      configs:     { CONFIG_KEY => CONFIG_VALUE },
      experiments: { EXP_KEY => [EXP_GROUP, EXP_PARAMS] },
    )
  end

  # Sanity: the seeded values are readable through the documented public surface
  # exactly as the controller would read them. This part does NOT depend on the
  # controller being wired up, so it should pass and proves the mock is live.
  test "configure_for_testing seeds values readable via Shipeasy::Client" do
    client = Shipeasy::Client.new({ "user_id" => "u_123" })

    assert_equal true, client.get_flag(FLAG_KEY)
    assert_equal CONFIG_VALUE, client.get_config(CONFIG_KEY)

    result = client.get_experiment(EXP_KEY, { "color" => "blue" })
    assert result.in_experiment, "expected to be enrolled in the seeded experiment"
    assert_equal EXP_GROUP, result.group
    assert_equal EXP_PARAMS, result.params
  end

  # Infrastructure assertions — these work TODAY (route boots + renders HTML).
  test "GET / renders the guide page HTML in-process" do
    get "/"

    assert_response :success
    assert_match(/text\/html/, response.media_type.to_s)
    # Page chrome that the view always renders, SDK-wired or not.
    assert_includes response.body, "Shipeasy · Ruby Entity Guide"
    assert_includes response.body, FLAG_KEY
    assert_includes response.body, CONFIG_KEY
    assert_includes response.body, EXP_KEY
  end

  # Value assertions — EXPECTED TO FAIL until the controller is wired to the SDK.
  # Each asserts the mocked value appears in the rendered HTML body.
  test "GET / shows the mocked feature flag value" do
    get "/"
    assert_response :success
    # Flag new_checkout => true should be reflected somewhere in the body.
    assert_includes response.body, "true",
      "expected the mocked feature flag `#{FLAG_KEY}` value to render"
  end

  test "GET / shows the mocked dynamic config value" do
    get "/"
    assert_response :success
    CONFIG_VALUE.each_value do |v|
      assert_includes response.body, v,
        "expected the mocked config `#{CONFIG_KEY}` value #{v.inspect} to render"
    end
  end

  test "GET / shows the mocked experiment enrolment" do
    get "/"
    assert_response :success
    assert_includes response.body, EXP_GROUP,
      "expected the mocked experiment group `#{EXP_GROUP}` to render"
    EXP_PARAMS.each_value do |v|
      assert_includes response.body, v,
        "expected the mocked experiment param #{v.inspect} to render"
    end
  end
end
