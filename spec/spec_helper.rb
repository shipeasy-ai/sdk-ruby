require "shipeasy-sdk"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.warnings = true

  # Internal-error self-reporting safety net for the whole test suite.
  #
  # The published gem bakes a REAL public ingest key into
  # Shipeasy::SDK::InternalReport::INGEST_KEY, so a spec that builds a live,
  # non-test-mode engine and trips Engine#safe_run could otherwise fire a real
  # POST to api.shipeasy.ai/collect and pollute Shipeasy's own errors dashboard
  # from CI. We override the module's active ingest key with the inert
  # PLACEHOLDER_KEY so key_configured? is false and every send is gated off by
  # default. This runs before the suite AND before each example, so it holds in
  # any test ordering and when a single fail-safe spec is run in isolation.
  #
  # The InternalReport specs themselves opt back into a FAKE key via
  # set_ingest_key_for_test(FAKE_KEY) and stub send_event (no real network), so
  # this default-inert state does not break them (their per-example `before`
  # runs after this suite-wide hook).
  reset_internal_report_key = proc do
    Shipeasy::SDK::InternalReport.set_ingest_key_for_test(
      Shipeasy::SDK::InternalReport::PLACEHOLDER_KEY,
    )
  end
  config.before(:suite, &reset_internal_report_key)
  config.before(:each, &reset_internal_report_key)
end
