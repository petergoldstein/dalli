begin
  require 'base64'
rescue LoadError
  # Ruby 1.9 compat
  module Base64
    def self.encode64(data)
      [data].pack('m')
    end

    def self.decode64(data64)
      data64.unpack('m')[0]
    end
  end
end
