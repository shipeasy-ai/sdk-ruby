require "spec_helper"

RSpec.describe Shipeasy::SDK do
  it "exposes a version constant" do
    expect(described_class::VERSION).to be_a(String)
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end
end
