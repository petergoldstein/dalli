require 'active_support/cache'

module ActionDispatch
  module Session
    class DalliStore < AbstractStore
      def initialize(app, options = {})
        require 'dalli'

        # Support old :expires option
        options[:expire_after] ||= options[:expires]

        super

        @default_options = {
          :namespace => 'rack:session',
          :memcache_server => 'localhost:11211',
          :expires_in => options[:expire_after]
        }.merge(@default_options)

        @pool = options[:cache] || begin
          store = RAILS_VERSION < '3.0' ? :dalli_store23 : :dalli_store
          ActiveSupport::Cache.lookup_store(store, @default_options[:memcache_server], @default_options)
        end
        # unless @pool.servers.any? { |s| s.alive? }
        #   raise "#{self} unable to find server during initialization."
        # end
        @mutex = Mutex.new

        super
      end

      private
        def get_session(env, sid)
          begin
            session = @pool.get(sid) || {}
          rescue Dalli::DalliError => de
            Rails.logger.warn("Session::DalliStore: #{$!.message}")
            session = {}
          end
          [sid, session]
        end

        def set_session(env, sid, session_data)
          options = env['rack.session.options']
          expiry  = options[:expire_after] || 0
          @pool.set(sid, session_data, expiry)
          sid
        rescue Dalli::DalliError
          Rails.logger.warn("Session::DalliStore: #{$!.message}")
          false
        end

        def destroy(env)
          if sid = current_session_id(env)
            @pool.delete(sid)
          end
        rescue Dalli::DalliError
          Rails.logger.warn("Session::DalliStore: #{$!.message}")
          false
        end

    end
  end
end
