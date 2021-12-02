# frozen_string_literal: true

module Dalli
  module Protocol
    class Binary
      ##
      # Class that encapsulates data parsed from a memcached response header.
      ##
      class ResponseHeader
        SIZE = 24
        FMT = '@2nCCnNNQ'

        attr_reader :key_len, :extra_len, :data_type, :status, :body_len, :opaque, :cas

        def initialize(buf)
          raise ArgumentError, "Response buffer must be at least #{SIZE} bytes" unless buf.bytesize >= SIZE

          @key_len, @extra_len, @data_type, @status, @body_len, @opaque, @cas = buf.unpack(FMT)
        end

        def ok?
          status.zero?
        end

        def not_found?
          status == 1
        end

        NOT_STORED_STATUSES = [2, 5].freeze
        def not_stored?
          NOT_STORED_STATUSES.include?(status)
        end
      end
    end
  end
end
