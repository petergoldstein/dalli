require 'zlib'

module Dalli
  class Compressor
    def self.compress(data)
      Zlib::Deflate.deflate(data)
    end

    def self.decompress(data)
      Zlib::Inflate.inflate
    end
  end
end
