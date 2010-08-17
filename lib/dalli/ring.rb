require 'digest/sha1'
require 'zlib'

module Dalli
  class Ring
    POINTS_PER_SERVER = 160 # this is the default in libmemcached
    
    attr_accessor :servers, :continuum
    
    def initialize(servers)
      @servers = servers
      if servers.size > 1
        total_weight = servers.inject(0) { |memo, srv| memo + srv.weight }
        continuum = []
        servers.each do |server|
          entry_count_for(server, servers.size, total_weight).times do |idx|
            hash = Digest::SHA1.hexdigest("#{server.hostname}:#{server.port}:#{idx}")
            value = Integer("0x#{hash[0..7]}")
            continuum << Dalli::Ring::Entry.new(value, server)
          end
        end
        continuum.sort { |a, b| a.value <=> b.value }
        @continuum = continuum
      end
    end
    
    def server_for_key(key)
      return @servers.first unless @continuum

      hkey = Zlib.crc32(key)

      20.times do |try|
        entryidx = self.class.binary_search(@continuum, hkey)
        server = @continuum[entryidx].server
        return server if server.alive?
        break unless failover
        hkey = Zlib.crc32("#{try}#{key}")
      end

      raise Dalli::NetworkError, "No servers available"
    end
    
    private
    
    class Entry
      attr_reader :value
      attr_reader :server

      def initialize(val, srv)
        @value = val
        @server = srv
      end

      def inspect
        "<#{value}, #{server.host}:#{server.port}>"
      end
    end

    def entry_count_for(server, total_servers, total_weight)
      ((total_servers * POINTS_PER_SERVER * server.weight) / Float(total_weight)).floor
    end

    # Find the closest index in the Ring with value <= the given value
    def self.binary_search(ary, value)
      upper = ary.size - 1
      lower = 0
      idx = 0

      while (lower <= upper) do
        idx = (lower + upper) / 2
        comp = ary[idx].value <=> value

        if comp == 0
          return idx
        elsif comp > 0
          upper = idx - 1
        else
          lower = idx + 1
        end
      end
      return upper
    end
    
    # Native extension to perform the binary search within the ring.  This is purely optional for
    # performance and only necessary if you are using multiple memcached servers.
    class << self
      begin
        require 'inline'
        inline do |builder|
          builder.c <<-EOM
          int binary_search(VALUE ary, unsigned int r) {
              int upper = RARRAY_LEN(ary) - 1;
              int lower = 0;
              int idx = 0;
              ID value = rb_intern("value");
    
              while (lower <= upper) {
                  idx = (lower + upper) / 2;
    
                  VALUE continuumValue = rb_funcall(RARRAY_PTR(ary)[idx], value, 0);
                  unsigned int l = NUM2UINT(continuumValue);
                  if (l == r) {
                      return idx;
                  }
                  else if (l > r) {
                      upper = idx - 1;
                  }
                  else {
                      lower = idx + 1;
                  }
              }
              return upper;
          }
          EOM
        end
      rescue Exception => e
      end
    end
  end
end