require "spec_helper"

RSpec.describe Shipeasy::SDK::RackMiddleware do
  # A downstream app that records the anon id it saw and returns a bare response.
  def app_capturing(seen)
    lambda do |env|
      seen[:env_id]    = env[described_class::ENV_KEY]
      seen[:thread_id] = Shipeasy::SDK::AnonId.current
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end

  def set_cookies(headers)
    raw = headers["Set-Cookie"] || headers["set-cookie"]
    raw.is_a?(Array) ? raw : Array(raw).flat_map { |h| h.to_s.split("\n") }
  end

  it "mints a cookie and exposes the id when none is present" do
    seen = {}
    mw = described_class.new(app_capturing(seen))
    status, headers, _ = mw.call("rack.url_scheme" => "https")

    expect(status).to eq(200)
    id = seen[:env_id]
    expect(Shipeasy::SDK::AnonId.valid?(id)).to be(true)
    expect(seen[:thread_id]).to eq(id)

    cookie = set_cookies(headers).find { |c| c.start_with?("#{Shipeasy::SDK::AnonId::COOKIE}=") }
    expect(cookie).to include("#{Shipeasy::SDK::AnonId::COOKIE}=#{id}")
    expect(cookie).to include("Path=/")
    expect(cookie).to include("Max-Age=#{Shipeasy::SDK::AnonId::MAX_AGE}")
    expect(cookie).to include("SameSite=Lax")
    expect(cookie).to include("Secure")
    expect(cookie).not_to include("HttpOnly")
  end

  it "reuses a valid existing cookie and does not re-set it" do
    seen = {}
    mw = described_class.new(app_capturing(seen))
    _, headers, _ = mw.call("HTTP_COOKIE" => "#{Shipeasy::SDK::AnonId::COOKIE}=stable-id-1; other=x")

    expect(seen[:env_id]).to eq("stable-id-1")
    expect(set_cookies(headers)).to be_empty
  end

  it "mints when the existing cookie is tampered (out of charset)" do
    seen = {}
    mw = described_class.new(app_capturing(seen))
    mw.call("HTTP_COOKIE" => "#{Shipeasy::SDK::AnonId::COOKIE}=bad value!")

    expect(seen[:env_id]).not_to eq("bad value!")
    expect(Shipeasy::SDK::AnonId.valid?(seen[:env_id])).to be(true)
  end

  it "omits Secure on plain HTTP" do
    mw = described_class.new(app_capturing({}))
    _, headers, _ = mw.call({})
    cookie = set_cookies(headers).first
    expect(cookie).not_to include("Secure")
  end

  it "clears the thread-local after the request" do
    mw = described_class.new(app_capturing({}))
    mw.call({})
    expect(Shipeasy::SDK::AnonId.current).to be_nil
  end

  it "preserves a Set-Cookie the app already emitted" do
    app = lambda { |_env| [200, { "Set-Cookie" => "session=abc; Path=/" }, ["ok"]] }
    mw = described_class.new(app)
    _, headers, _ = mw.call({})
    cookies = set_cookies(headers)
    expect(cookies.any? { |c| c.start_with?("session=") }).to be(true)
    expect(cookies.any? { |c| c.start_with?("#{Shipeasy::SDK::AnonId::COOKIE}=") }).to be(true)
  end
end
