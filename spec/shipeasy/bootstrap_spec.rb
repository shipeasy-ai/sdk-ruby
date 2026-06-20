require "spec_helper"
require "cgi"

RSpec.describe "SSR bootstrap script tags" do
  def client
    Shipeasy::SDK::FlagsClient.from_snapshot(
      flags: {
        "gates" => {
          "new_ui"   => { "enabled" => true, "salt" => "s", "rolloutPct" => 10_000 },
          "off_gate" => { "enabled" => false, "salt" => "s", "rolloutPct" => 10_000 },
        },
        "configs" => { "theme" => { "value" => { "color" => "blue" } } },
      },
      experiments: { "experiments" => {}, "universes" => {} },
    )
  end

  it "builds a bootstrap payload" do
    p = client.evaluate("user_id" => "u1")
    expect(p["flags"]["new_ui"]).to be(true)
    expect(p["flags"]["off_gate"]).to be(false)
    expect(p["configs"]["theme"]).to eq("color" => "blue")
    expect(p["killswitches"]).to eq({})
  end

  it "emits the bootstrap script tag with data-* attributes and no key" do
    tag = client.bootstrap_script_tag({ "user_id" => "u1" }, anon_id: "anon-1")
    expect(tag).to include('src="https://cdn.shipeasy.ai/sdk/bootstrap.js"')
    expect(tag).to include("data-se-bootstrap")
    expect(tag).to include('data-anon-id="anon-1"')
    expect(tag).to include('data-i18n-profile="en:prod"')
    expect(tag).not_to include("data-key")

    raw = tag[/data-flags="([^"]*)"/, 1]
    expect(JSON.parse(CGI.unescapeHTML(raw))["new_ui"]).to be(true)
  end

  it "omits data-anon-id when no anon id is given" do
    tag = client.bootstrap_script_tag("user_id" => "u1")
    expect(tag).not_to include("data-anon-id")
  end

  it "emits the i18n loader tag with the public key" do
    tag = client.i18n_script_tag("client_pub", profile: "fr:prod")
    expect(tag).to include('src="https://cdn.shipeasy.ai/sdk/i18n/loader.js"')
    expect(tag).to include('data-key="client_pub"')
    expect(tag).to include('data-profile="fr:prod"')
  end
end
