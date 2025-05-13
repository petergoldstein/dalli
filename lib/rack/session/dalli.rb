# frozen_string_literal: true

require 'rack/session/abstract/id'
require 'dalli'
require 'connection_pool'
require 'English'

module Rack
  module Session
    # Rack::Session::Dalli provides memcached based session management.
    class Dalli < Abstract::PersistedSecure
      class MissingSessionError < StandardError; end

      RACK_SESSION_PERSISTED = 'rack.session.persisted'

      attr_reader :data

      # Don't freeze this until we fix the specs/implementation
      # rubocop:disable Style/MutableConstant
      DEFAULT_DALLI_OPTIONS = {
        namespace: 'rack:session'
      }
      # rubocop:enable Style/MutableConstant

      # Brings in a new Rack::Session::Dalli middleware with the given
      # `:memcache_server`. The server is either a hostname, or a
      # host-with-port string in the form of "host_name:port", or an array of
      # such strings. For example:
      #
      #   use Rack::Session::Dalli,
      #     :memcache_server => "mc.example.com:1234"
      #
      # If no `:memcache_server` option is specified, Rack::Session::Dalli will
      # connect to localhost, port 11211 (the default memcached port). If
      # `:memcache_server` is set to nil, Dalli::Client will look for
      # ENV['MEMCACHE_SERVERS'] and use that value if it is available, or fall
      # back to the same default behavior described above.
      #
      # Rack::Session::Dalli accepts the same options as Dalli::Client, so
      # it's worth reviewing its documentation. Perhaps most importantly,
      # if you don't specify a `:namespace` option, Rack::Session::Dalli
      # will default to using 'rack:session'.
      #
      # It is not recommended to set `:expires_in`. Instead, use `:expire_after`,
      # which will control both the expiration of the client cookie as well
      # as the expiration of the corresponding entry in memcached.
      #
      # Rack::Session::Dalli also accepts a host of options that control how
      # the sessions and session cookies are managed, including the
      # aforementioned `:expire_after` option. Please see the documentation for
      # Rack::Session::Abstract::Persisted for a detailed explanation of these
      # options and their default values.
      #
      # Finally, if your web application is multithreaded, the
      # Rack::Session::Dalli middleware can become a source of contention. You
      # can use a connection pool of Dalli clients by passing in the
      # `:pool_size` and/or `:pool_timeout` options. For example:
      #
      #   use Rack::Session::Dalli,
      #     :memcache_server => "mc.example.com:1234",
      #     :pool_size => 10
      #
      # You must include the `connection_pool` gem in your project if you wish
      # to use pool support. Please see the documentation for ConnectionPool
      # for more information about it and its default options (which would only
      # be applicable if you supplied one of the two options, but not both).
      #
      def initialize(app, options = {})
        # Parent uses DEFAULT_OPTIONS to build @default_options for Rack::Session
        super

        # Determine the default TTL for newly-created sessions
        @default_ttl = ttl(@default_options[:expire_after])
        @data = build_data_source(options)
      end

      def call(*_args)
        super
      rescue MissingSessionError
        [401, {}, ['Wrong session ID']]
      end

      def find_session(req, sid)
        with_dalli_client([nil, {}]) do |dc|
          existing_session = existing_session_for_sid(dc, sid)
          if existing_session.nil?
            sid = create_sid_with_empty_session(dc)
            existing_session = {}
          end

          update_session_persisted_data(req, { id: sid })
          return [sid, existing_session]
        end
      end

      def write_session(req, sid, session, options)
        return false unless sid

        key = memcached_key_from_sid(sid)
        return false unless key

        with_dalli_client(false) do |dc|
          write_session_safely!(
            dc, sid, session_persisted_data(req),
            write_args: [memcached_key_from_sid(sid), session, ttl(options[:expire_after])]
          )

          sid
        end
      end

      def delete_session(_req, sid, options)
        with_dalli_client do |dc|
          key = memcached_key_from_sid(sid)
          dc.delete(key) if key
          generate_sid_with(dc) unless options[:drop]
        end
      end

      private

      def memcached_key_from_sid(sid)
        sid.private_id if sid.respond_to?(:private_id)
      end

      def existing_session_for_sid(client, sid)
        return nil unless sid && !sid.empty?

        key = memcached_key_from_sid(sid)
        return nil if key.nil?

        client.get(key)
      end

      def create_sid_with_empty_session(client)
        loop do
          sid = generate_sid_with(client)
          key = memcached_key_from_sid(sid)

          break sid if key && client.add(key, {}, @default_ttl)
        end
      end

      def generate_sid_with(client)
        loop do
          raw_sid = generate_sid
          sid = raw_sid.is_a?(String) ? Rack::Session::SessionId.new(raw_sid) : raw_sid
          key = memcached_key_from_sid(sid)
          break sid unless key && client.get(key)
        end
      end

      def build_data_source(options)
        server_configurations, client_options, pool_options = extract_dalli_options(options)

        if pool_options.empty?
          ::Dalli::Client.new(server_configurations, client_options)
        else
          ensure_connection_pool_added!
          ConnectionPool.new(pool_options) do
            ::Dalli::Client.new(server_configurations, client_options.merge(threadsafe: false))
          end
        end
      end

      def write_session_safely!(dalli_client, sid, persisted_data, write_args:)
        if persisted_data && persisted_data[:id] == sid # That means that we update the existing session
          # Override the session only if it still exists in the store!
          raise MissingSessionError unless dalli_client.replace(*write_args)
        else
          dalli_client.set(*write_args)
        end
      end

      def extract_dalli_options(options)
        raise 'Rack::Session::Dalli no longer supports the :cache option.' if options[:cache]

        client_options = retrieve_client_options(options)
        server_configurations = client_options.delete(:memcache_server)

        [server_configurations, client_options, retrieve_pool_options(options)]
      end

      def retrieve_client_options(options)
        # Filter out Rack::Session-specific options and apply our defaults
        filtered_opts = options.reject { |k, _| DEFAULT_OPTIONS.key? k }
        DEFAULT_DALLI_OPTIONS.merge(filtered_opts)
      end

      def retrieve_pool_options(options)
        {}.tap do |pool_options|
          pool_options[:size] = options.delete(:pool_size) if options[:pool_size]
          pool_options[:timeout] = options.delete(:pool_timeout) if options[:pool_timeout]
        end
      end

      def ensure_connection_pool_added!
        require 'connection_pool'
      rescue LoadError => e
        warn "You don't have connection_pool installed in your application. " \
             'Please add it to your Gemfile and run bundle install'
        raise e
      end

      def with_dalli_client(result_on_error = nil, &block)
        @data.with(&block)
      rescue ::Dalli::DalliError, Errno::ECONNREFUSED
        raise if $ERROR_INFO.message.include?('undefined class')

        if $VERBOSE
          warn "#{self} is unable to find memcached server."
          warn $ERROR_INFO.inspect
        end
        result_on_error
      end

      def ttl(expire_after)
        expire_after.nil? ? 0 : expire_after + 1
      end

      def session_persisted_data(req)
        req.get_header RACK_SESSION_PERSISTED
      end

      def update_session_persisted_data(req, data)
        req.set_header RACK_SESSION_PERSISTED, data
      end
    end
  end
end
