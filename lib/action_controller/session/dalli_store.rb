# Session store for Rails 2.3.x
# Tested against 2.3.9.
begin
  require_library_or_gem 'dalli'

  module ActionController
    module Session
      class DalliStore < AbstractStore
        def initialize(app, options = {})
          # Support old :expires option
          options[:expire_after] ||= options[:expires]

          super

          @default_options = {
            :namespace => 'rack:session',
            :memcache_server => 'localhost:11211'
          }.merge(@default_options)

          @pool = Dalli::Client.new(@default_options[:memcache_server], @default_options)
          super
        end

        private
          def get_session(env, sid)
            sid ||= generate_sid
            begin
              session = @pool.get(sid) || {}
            rescue Dalli::DalliError
              session = {}
            end
            [sid, session]
          end

          def set_session(env, sid, session_data)
            options = env['rack.session.options']
            expiry  = options[:expire_after] || 0
            @pool.set(sid, session_data, expiry)
            return true
          rescue Dalli::DalliError
            return false
          end
          
          def destroy(env)
            if sid = current_session_id(env)
              @pool.delete(sid)
            end
          rescue Dalli::DalliError
            false
          end
          
      end
    end
  end
rescue LoadError
  # Dalli wasn't available so neither can the store be
end
