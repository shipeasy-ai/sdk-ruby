require "spec_helper"

# These fixtures match MurmurHash3_x86_32 with seed 0. They're the same set
# the worker and the JS SDK assert against, so the three implementations
# stay byte-compatible — a divergence here would silently re-bucket every
# user the moment one platform's eval ran on a different commit than
# another.
RSpec.describe Shipeasy::SDK::Murmur3 do
  {
    ""                   => 0x00000000,
    "0"                  => 0xD271C07F,
    "1"                  => 0x9416AC93,
    "abc"                => 0xB3DD93FA,
    "Hello, world!"      => 0xC0363E43,
    "user_42:flag_alpha" => 0xF3A63607,
  }.each do |input, expected|
    it "hash32(#{input.inspect}) == 0x#{expected.to_s(16).rjust(8, '0').upcase}" do
      expect(described_class.hash32(input)).to eq(expected)
    end
  end

  it "is deterministic across calls" do
    %w[a longer-input-string user_id_42].each do |input|
      expect(described_class.hash32(input)).to eq(described_class.hash32(input))
    end
  end
end
