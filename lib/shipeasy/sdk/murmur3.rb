module Shipeasy
  module SDK
    module Murmur3
      C1 = 0xcc9e2d51
      C2 = 0x1b873593
      MASK32 = 0xFFFFFFFF

      def self.hash32(key, seed = 0)
        bytes = key.encode("UTF-8").bytes
        len   = bytes.length
        h1    = seed

        (len / 4).times do |i|
          off = i * 4
          k1 = bytes[off] | (bytes[off + 1] << 8) | (bytes[off + 2] << 16) | (bytes[off + 3] << 24)
          k1 = (k1 & MASK32)
          k1 = ((k1 * C1) & MASK32)
          k1 = ((k1 << 15) | (k1 >> 17)) & MASK32
          k1 = ((k1 * C2) & MASK32)
          h1 ^= k1
          h1 = ((h1 << 13) | (h1 >> 19)) & MASK32
          h1 = ((h1 * 5) & MASK32)
          h1 = (h1 + 0xe6546b64) & MASK32
        end

        tail   = (len / 4) * 4
        k1     = 0
        remain = len & 3
        k1 ^= (bytes[tail + 2] << 16) if remain >= 3
        k1 ^= (bytes[tail + 1] << 8)  if remain >= 2
        k1 ^= bytes[tail]              if remain >= 1
        if remain > 0
          k1 = (k1 * C1) & MASK32
          k1 = ((k1 << 15) | (k1 >> 17)) & MASK32
          k1 = (k1 * C2) & MASK32
          h1 ^= k1
        end

        h1 ^= len
        h1  = fmix32(h1)
        h1
      end

      def self.fmix32(h)
        h ^= (h >> 16)
        h  = (h * 0x85ebca6b) & MASK32
        h ^= (h >> 13)
        h  = (h * 0xc2b2ae35) & MASK32
        h ^= (h >> 16)
        h
      end
    end
  end
end
