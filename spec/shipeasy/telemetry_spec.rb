require "spec_helper"

RSpec.describe Shipeasy::SDK::Telemetry do
  let(:sent) { [] }

  before do
    # Intercept the fire-and-forget dispatch so we assert the URL without
    # real network/threads.
    allow_any_instance_of(described_class).to receive(:dispatch) { |_, url| sent << url }
  end

  # 1) basic telemetry send works for each entity call, hitting the right URL.
  it "fires a beacon with the right feature path for every entity call" do
    client = Shipeasy::SDK::FlagsClient.new(api_key: "srv", base_url: "https://e.x")
    client.get_flag("g", {})
    client.get_config("c")
    client.get_experiment("e", {}, {})

    expect(sent.size).to eq(3)
    expect(sent).to include(a_string_ending_with("/gate/g"))
    expect(sent).to include(a_string_ending_with("/config/c"))
    expect(sent).to include(a_string_ending_with("/experiment/e"))
    expect(sent).to all(include("https://e.x/t/"))
    expect(sent.join).not_to include("srv") # raw key never appears in the URL
  end

  # 2) telemetry is not sent when disabled in settings.
  it "fires no beacon when disable_telemetry is true" do
    client = Shipeasy::SDK::FlagsClient.new(
      api_key: "srv", base_url: "https://e.x", disable_telemetry: true
    )
    client.get_flag("g", {})
    client.get_config("c")
    client.get_experiment("e", {}, {})

    expect(sent).to be_empty
  end
end
