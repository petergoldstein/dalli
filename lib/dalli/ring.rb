# frozen_string_literal: true

require 'digest/sha1'
require 'zlib'

module Dalli
  ##
  # An implementation of a consistent hash ring, designed to minimize
  # the cache miss impact of adding or removing servers from the ring.
  # That is, adding or removing a server from the ring should impact
  # the key -> server mapping of ~ 1/N of the stored keys where N is the
  # number of servers in the ring.  This is done by creating a large
  # number of "points" per server, distributed over the space
  # 0x00000000 - 0xFFFFFFFF. For a given key, we calculate the CRC32
  # hash, and find the nearest "point" that is less than or equal to the
  # the key's hash.  In this implemetation, each "point" is represented
  # by a Dalli::Ring::Entry.
  ##
  class Ring
    # The number of entries on the continuum created per server
    # in an equally weighted scenario.
    POINTS_PER_SERVER = 160 # this is the default in libmemcached

    attr_accessor :servers, :continuum

    def initialize(servers_arg, protocol_implementation, options)
      @servers = servers_arg.map do |s|
        protocol_implementation.new(s, options)
      end
      @continuum = nil
      @continuum = build_continuum(servers) if servers.size > 1

      threadsafe! unless options[:threadsafe] == false
      @failover = options[:failover] != false
    end

    def server_for_key(key)
      server = if @continuum
                 server_from_continuum(key)
               else
                 @servers.first
               end

      # Note that the call to alive? has the side effect of initializing
      # the socket
      return server if server&.alive?

      raise Dalli::RingError, 'No server available'
    end

    def server_from_continuum(key)
      hkey = hash_for(key)
      20.times do |try|
        server = server_for_hash_key(hkey)

        # Note that the call to alive? has the side effect of initializing
        # the socket
        return server if server.alive?
        break unless @failover

        hkey = hash_for("#{try}#{key}")
      end
      nil
    end

    def keys_grouped_by_server(key_arr)
      key_arr.group_by do |key|
        server_for_key(key)
      rescue Dalli::RingError
        Dalli.logger.debug { "unable to get key #{key}" }
        nil
      end
    end

    def lock
      @servers.each(&:lock!)
      begin
        yield
      ensure
        @servers.each(&:unlock!)
      end
    end

    def pipeline_consume_and_ignore_responses
      @servers.each do |s|
        s.request(:noop)
      rescue Dalli::NetworkError
        # Ignore this error, as it indicates the socket is unavailable
        # and there's no need to flush
      end
    end

    def socket_timeout
      @servers.first.socket_timeout
    end

    def close
      @servers.each(&:close)
    end

    private

    def threadsafe!
      @servers.each do |s|
        s.extend(Dalli::Threadsafe)
      end
    end

    def hash_for(key)
      Zlib.crc32(key)
    end

    def entry_count_for(server, total_servers, total_weight)
      ((total_servers * POINTS_PER_SERVER * server.weight) / Float(total_weight)).floor
    end

    def server_for_hash_key(hash_key)
      # Find the closest index in the Ring with value <= the given value
      entryidx = @continuum.bsearch_index { |entry| entry.value > hash_key }
      if entryidx.nil?
        entryidx = @continuum.size - 1
      else
        entryidx -= 1
      end
      @continuum[entryidx].server
    end

    def build_continuum(servers)
      continuum = []
      total_weight = servers.inject(0) { |memo, srv| memo + srv.weight }
      servers.each do |server|
        entry_count_for(server, servers.size, total_weight).times do |idx|
          hash = Digest::SHA1.hexdigest("#{server.name}:#{idx}")
          value = Integer("0x#{hash[0..7]}")
          continuum << Dalli::Ring::Entry.new(value, server)
        end
      end
      continuum.sort_by(&:value)
    end

    ##
    # Represents a point in the consistent hash ring implementation.
    ##
    class Entry
      attr_reader :value, :server

      def initialize(val, srv)
        @value = val
        @server = srv
      end
    end
  end
end
