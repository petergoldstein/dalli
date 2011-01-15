class Dalli::Client

  module MemcacheClientCompatibility

    def initialize(*args)
      Dalli.logger.error("Starting Dalli in memcache-client compatibility mode")
      super(*args)
    end

    def set(key, value, ttl = nil, options = nil)
      if options == true || options == false
        Dalli.logger.error("Dalli: please use set(key, value, ttl, :raw => boolean): #{caller[0]}")
        options = { :raw => options }
      end
      super(key, value, ttl, options) ? "STORED\r\n" : "NOT_STORED\r\n"

    end

    def add(key, value, ttl = nil, options = nil)
      if options == true || options == false
        Dalli.logger.error("Dalli: please use add(key, value, ttl, :raw => boolean): #{caller[0]}")
        options = { :raw => options }
      end
      super(key, value, ttl, options) ? "STORED\r\n" : "NOT_STORED\r\n"
    end

    def replace(key, value, ttl = nil, options = nil)
      if options == true || options == false
        Dalli.logger.error("Dalli: please use replace(key, value, ttl, :raw => boolean): #{caller[0]}")
        options = { :raw => options }
      end
      super(key, value, ttl, options) ? "STORED\r\n" : "NOT_STORED\r\n"
    end

    # Dalli does not unmarshall data that does not have the marshalled flag set so we need
    # to unmarshall manually any marshalled data originally put in memcached by memcache-client.
    # Peek at the data and see if it looks marshalled.
    def get(key, options = nil)
      value = super(key, options)
      if value && value.is_a?(String) && !options && value.size > 2 &&
              bytes = value.unpack('cc') && bytes[0] == 4 && bytes[1] == 8
        return Marshal.load(value) rescue value
      end
      value
    end

    def delete(key)
      super(key) ? "DELETED\r\n" : "NOT_DELETED\r\n"
    end
  end

end