require "spec_helper"
require "cgi"

RSpec.describe "SSR bootstrap script tags" do
  # The tag helpers read their defaults off Shipeasy.config, so start every
  # example from the shipped defaults rather than whatever configure* an
  # earlier spec file left behind.
  before { Shipeasy.reset_config! }
  after  { Shipeasy.reset_config! }

  def client
    Shipeasy::Engine.from_snapshot(
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
    expect(tag).to include('src="https://cdn.shipeasy.ai/sdk/runtime.js"')
    expect(tag).to include("data-se-bootstrap")
    expect(tag).to include('data-anon-id="anon-1"')
    expect(tag).to include('data-i18n-profile="default"')   # config.profile
    expect(tag).not_to include("data-key")

    raw = tag[/data-flags="([^"]*)"/, 1]
    expect(JSON.parse(CGI.unescapeHTML(raw))["new_ui"]).to be(true)
  end

  it "omits data-anon-id when no anon id is given" do
    # Braces required: a braceless hash before keyword args is parsed as kwargs
    # on Ruby 3.0+, starving the positional `user`.
    tag = client.bootstrap_script_tag({ "user_id" => "u1" })
    expect(tag).not_to include("data-anon-id")
  end

  it "carries the server-identified user on the tag as data-user (minus anonymous_id)" do
    tag = client.bootstrap_script_tag(
      { "user_id" => "u1", "email" => "e@x.com", "anonymous_id" => "anon-1" },
      anon_id: "anon-1",
    )
    expect(tag).to include('data-anon-id="anon-1"')

    raw = tag[/data-user="([^"]*)"/, 1]
    parsed = JSON.parse(CGI.unescapeHTML(raw))
    expect(parsed).to eq("user_id" => "u1", "email" => "e@x.com")
    expect(parsed).not_to have_key("anonymous_id")
  end

  it "omits data-user for a purely anonymous request" do
    only_anon = client.bootstrap_script_tag({ "anonymous_id" => "anon-1" }, anon_id: "anon-1")
    expect(only_anon).not_to include("data-user")

    empty = client.bootstrap_script_tag({})
    expect(empty).not_to include("data-user")
  end

  it "keeps an empty-string trait (only nil is dropped — cross-SDK contract)" do
    tag = client.bootstrap_script_tag({ "user_id" => "u1", "email" => "" }, anon_id: "anon-1")
    parsed = JSON.parse(CGI.unescapeHTML(tag[/data-user="([^"]*)"/, 1]))
    expect(parsed).to eq("user_id" => "u1", "email" => "")
  end

  it "emits the i18n loader tag with the public key" do
    tag = client.i18n_script_tag("client_pub", profile: "fr:prod")
    expect(tag).to include('src="https://cdn.shipeasy.ai/sdk/i18n/loader.js"')
    expect(tag).to include('data-key="client_pub"')
    expect(tag).to include('data-profile="fr:prod"')
  end

  describe "every argument is optional (defaults come from configure)" do
    before do
      Shipeasy.config.public_key   = "sdk_client_cfg"
      Shipeasy.config.project_id   = "proj_cfg"
      Shipeasy.config.profile      = "fr:prod"
      Shipeasy.config.cdn_base_url = "https://cdn.example.test"
    end

    it "i18n_script_tag takes key, profile and CDN base from the config" do
      tag = client.i18n_script_tag
      expect(tag).to include('src="https://cdn.example.test/sdk/i18n/loader.js"')
      expect(tag).to include('data-key="sdk_client_cfg"')
      expect(tag).to include('data-profile="fr:prod"')
    end

    it "bootstrap_script_tag needs no user and takes the profile from the config" do
      tag = client.bootstrap_script_tag
      expect(tag).to include('src="https://cdn.example.test/sdk/runtime.js"')
      expect(tag).to include('data-i18n-profile="fr:prod"')
      expect(tag).not_to include("data-user")
    end

    it "devtools_script_tag takes the project id and public key from the config" do
      tag = client.devtools_script_tag
      expect(tag).to include('src="https://cdn.example.test/se-devtools.js"')
      expect(tag).to include('data-project-id="proj_cfg"')
      expect(tag).to include('data-client-api-key="sdk_client_cfg"')
      expect(tag).to include("defer")
    end

    it "an explicit argument still wins over the configured value" do
      expect(client.i18n_script_tag("other_key", profile: "de:prod"))
        .to include('data-key="other_key"').and include('data-profile="de:prod"')
      expect(client.bootstrap_script_tag({ "user_id" => "u1" }, i18n_profile: "de:prod"))
        .to include('data-i18n-profile="de:prod"')
      expect(client.devtools_script_tag("proj_other", client_key: "other_key", defer: false))
        .to include('data-project-id="proj_other"').and include('data-client-api-key="other_key"')
      expect(client.devtools_script_tag(defer: false)).not_to include("defer")
    end
  end

  it "warns (but still renders) when the devtools tag has no project id or key" do
    # Once per missing setting, and only once however many times the tag renders
    # — a helper that runs on every request must not log a line per request.
    engine = client
    expect(Shipeasy::Logging).to receive(:warn).twice
    3.times do
      expect(engine.devtools_script_tag).to include('src="https://cdn.shipeasy.ai/se-devtools.js"')
    end
  end
end
