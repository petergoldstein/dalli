# frozen_string_literal: true
require 'zlib'
require 'stringio'

begin
  require 'lz4-ruby'
rescue LoadError
  # This space intentionally left blank.
end

module Dalli
  class Compressor
    def self.compress(data)
      Zlib::Deflate.deflate(data)
    end

    def self.decompress(data)
      Zlib::Inflate.inflate(data)
    end
  end

  class GzipCompressor
    def self.compress(data)
      io = StringIO.new(String.new(""), "w")
      gz = Zlib::GzipWriter.new(io)
      gz.write(data)
      gz.close
      io.string
    end

    def self.decompress(data)
      io = StringIO.new(data, "rb")
      Zlib::GzipReader.new(io).read
    end
  end

  class LZ4Compressor
    def self.compress(data)
      LZ4::compress(data)
    end
    def self.decompress(data)
      LZ4::uncompress(data)
    end
  end
  class LZ4HCCompressor < LZ4Compressor
    def self.compress(data)
      LZ4::compressHC(data)
    end
  end
  
end
