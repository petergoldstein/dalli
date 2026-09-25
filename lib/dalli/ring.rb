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

    attr_accessor :servers
    attr_reader :continuum

    def initialize(servers_arg, options)
      @servers = servers_arg.map do |s|
        Dalli::Protocol::Meta.new(s, options)
      end
      self.continuum = (build_continuum(servers) if servers.size > 1)

      threadsafe! unless options[:threadsafe] == false
      @failover = options[:failover] != false
    end

    def continuum=(entries)
      @continuum = entries
      # Plain integers, so the binary search in server_for_hash_key needn't
      # call Entry#value at each step
      @continuum_values = entries&.map(&:value)
    end

    # alive_cache (optional) remembers each server's alive? result, so a
    # caller routing many keys checks each server once rather than per key.
    def server_for_key(key, alive_cache = nil)
      # server_from_continuum only returns a server that is alive
      server = if @continuum
                 server_from_continuum(key, alive_cache)
               elsif (first = @servers.first) && server_alive?(first, alive_cache)
                 first
               end
      return server if server

      raise Dalli::RingError, 'No server available'
    end

    def server_from_continuum(key, alive_cache = nil)
      hkey = hash_for(key)
      20.times do |try|
        server = server_for_hash_key(hkey)

        return server if server_alive?(server, alive_cache)
        break unless @failover

        hkey = hash_for("#{try}#{key}")
      end
      nil
    end

    def keys_grouped_by_server(key_arr)
      alive_cache = {}.compare_by_identity
      key_arr.group_by do |key|
        server_for_key(key, alive_cache)
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

    # Drains the replies left by quiet requests. Only servers that were sent a
    # quiet request need it, so the others (and servers never connected) are
    # skipped rather than each costing a noop round trip.
    def pipeline_consume_and_ignore_responses
      @servers.each do |s|
        next unless s.quiet_responses_pending?

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

    # Note that the call to alive? has the side effect of initializing
    # the socket
    def server_alive?(server, alive_cache)
      return server.alive? unless alive_cache

      alive_cache.fetch(server) { alive_cache[server] = server.alive? }
    end

    def entry_count_for(server, total_servers, total_weight)
      ((total_servers * POINTS_PER_SERVER * server.weight) / Float(total_weight)).floor
    end

    def server_for_hash_key(hash_key)
      # Find the closest index in the Ring with value <= the given value
      entryidx = @continuum_values.bsearch_index { |value| value > hash_key }
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
