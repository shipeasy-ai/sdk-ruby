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
    # The three groups of the lean admin surface. Exhaustive on purpose: a
    # change to the SDK spec that adds or drops a group must move this list too.
    expect(client.flags).to be_a(Shipeasy::Admin::Generated::FlagsApi)
    expect(client.killswitch).to be_a(Shipeasy::Admin::Generated::KillswitchApi)
    expect(client.ops).to be_a(Shipeasy::Admin::Generated::OpsApi)
    expect(client).not_to respond_to(:comments)
    expect(client.flags).to equal(client.flags)
  end

  it "carries the seven operations of the SDK contract" do
    client = build
    expect(client.ops).to respond_to(:create_public_bug, :create_public_feature_request)
    expect(client.killswitch).to respond_to(:toggle_killswitch)
    expect(client.flags).to respond_to(
      :get_gate_whitelist, :set_gate_whitelist, :add_to_gate_whitelist, :remove_from_gate_whitelist
    )
  end

  it "wires the client key used by the public ticket intake" do
    # The two public ticket ops authenticate with a CLIENT key (X-SDK-Key) on
    # the edge worker, not the admin bearer.
    expect(build.api_client.config.api_key["clientSdkKey"]).to be_nil
    scoped = Shipeasy::Admin::Client.new(api_key: "sdk_admin_test", client_key: "sdk_client_test")
    expect(scoped.api_client.config.api_key["clientSdkKey"]).to eq("sdk_client_test")
  end

  it "defaults to the production host" do
    client = Shipeasy::Admin::Client.new(api_key: "sdk_admin_test")
    expect(client.api_client.config.host).to eq("shipeasy.ai")
  end
end
