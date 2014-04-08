require 'rack/session/abstract/id'
require 'dalli'

module Rack
  module Session
    class Dalli < Abstract::ID
      attr_reader :pool, :mutex

      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge \
        :namespace => 'rack:session',
        :memcache_server => 'localhost:11211'

      def initialize(app, options={})
        super
        @mutex = Mutex.new
        mserv = @default_options[:memcache_server]
        mopts = @default_options.reject{|k,v| !DEFAULT_OPTIONS.include? k }
        @pool = options[:cache] || ::Dalli::Client.new(mserv, mopts)
        @pool.alive!
      end

      def generate_sid
        loop do
          sid = super
          break sid unless @pool.get(cache_key(sid))
        end
      end

      def get_session(env, sid)
        with_lock(env, [nil, {}]) do
          unless sid and session = @pool.get(cache_key(sid))
            sid, session = generate_sid, {}
            unless @pool.add(cache_key(sid), session)
              raise "Session collision on '#{sid.inspect}'"
            end
          end
          [sid, session]
        end
      end

      def set_session(env, session_id, new_session, options)
        key = cache_key(session_id)
        return false unless session_id
        expiry = options[:expire_after]
        expiry = expiry.nil? ? 0 : expiry + 1

        with_lock(env, false) do
          @pool.set key, new_session, expiry
          session_id
        end
      end

      def destroy_session(env, session_id, options)
        with_lock(env) do
          @pool.delete(cache_key(session_id))
          generate_sid unless options[:drop]
        end
      end

      def with_lock(env, default=nil)
        @mutex.lock if env['rack.multithread']
        yield
      rescue ::Dalli::DalliError, Errno::ECONNREFUSED
        raise if $!.message =~ /undefined class/
        if $VERBOSE
          warn "#{self} is unable to find memcached server."
          warn $!.inspect
        end
        default
      ensure
        @mutex.unlock if @mutex.locked?
      end

      private
        # Turn the session id into a cache key.
        def cache_key(sid)
          "_session_id:#{sid}"
        end
    end
  end
end
