module Dalli
  class Client
    
    def initialize(servers, options=nil)
      @ring = Dalli::Ring.new(
        Array(servers).map do |s| 
          Dalli::Server.new(s)
        end
      )
    end
    
    def get(key)
      perform(:get, key)
    end
    
    def set(key, value, expiry=0)
      perform(:set, key, value, expiry)
    end
    
    private

    def perform(op, *args)
      server = @ring.server_for_key(args.first)
      server.request(op, *args)
    end
    
  end
end