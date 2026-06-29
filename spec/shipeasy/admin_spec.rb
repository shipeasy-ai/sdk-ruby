# frozen_string_literal: true

require "spec_helper"

# The Admin API client depends on the optional `faraday` gem (a development
# dependency, not a runtime one). When it is unavailable the require below fails
# and the whole describe block is skipped — the client still ships, just
# unverified in that environment. Constructing the client touches no network.
admin_available =
  begin
    require "faraday"
    require "shipeasy/admin"
    true
  rescue LoadError
    false
  end

RSpec.describe "Shipeasy::Admin::Client", if: admin_available do
  # The generated Configuration does `@logger = defined?(Rails) ? Rails.logger : …`.
  # Other specs in this suite load railties, so `Rails` is defined without a booted
  # app (no `.logger`). Real Rails apps always have `Rails.logger`; mirror that here
  # so construction doesn't raise from the cross-spec contamination.
  before do
    if defined?(Rails) && !Rails.respond_to?(:logger)
      require "logger"
      Rails.define_singleton_method(:logger) { Logger.new(IO::NULL) }
    end
  end

  def build
    Shipeasy::Admin::Client.new(
      api_key: "sdk_admin_test",
      project_id: "proj_123",
      base_url: "http://localhost:3000",
    )
  end

  it "wires bearer auth, host and project scoping" do
    client = build
    config = client.api_client.config
    expect(config.access_token).to eq("sdk_admin_test")
    expect(config.host).to eq("localhost:3000")
    expect(config.scheme).to eq("http")
    expect(client.api_client.default_headers["X-Project-Id"]).to eq("proj_123")
  end

  it "exposes the resource groups, memoized" do
    client = build
    expect(client.gates).to be_a(Shipeasy::Admin::Generated::GatesApi)
    expect(client.experiments).to be_a(Shipeasy::Admin::Generated::ExperimentsApi)
    expect(client.gates).to equal(client.gates)
  end

  it "defaults to the production host" do
    client = Shipeasy::Admin::Client.new(api_key: "sdk_admin_test")
    expect(client.api_client.config.host).to eq("shipeasy.ai")
  end
end
