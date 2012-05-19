require 'uri'

module Dalli
  # Inspired by https://github.com/mongodb/mongo-ruby-driver/blob/master/lib/mongo/util/uri_parser.rb
  class UrlParser
    class << self
      # Extract the comma-separated hosts and single port from the URL
      def multi_host_port(url)
        stop = url.index(%r{[?/]}, 12)
        start = url.rindex(%r{[@/]}, stop)
        url[(start+1)..(stop-1)].split(':')
      end
    end

    SPEC = "memcached://[username:password@]host1[:port1][,host2[:port2],...[,hostN[:portN]]][?options]"

    attr_reader :username
    attr_reader :password
    attr_reader :servers
    attr_reader :options

    def initialize(url)
      # Since we're breaking the rules by allowing multiple comma-separated hosts, extract hosts and port manually...
      multi_host, port = UrlParser.multi_host_port url
      
      # ... and then we can use Ruby's URI class to get username, password, and querystring
      parsed_uri = URI.parse url.sub multi_host, 'fakehost'

      @servers = multi_host.split(',').map do |host|
        "#{host}:#{port}"
      end
      @options = {}
      if parsed_uri.user
        @options[:username] = parsed_uri.user
      end
      if parsed_uri.password
        @options[:password] = parsed_uri.password
      end
      URI.decode_www_form(parsed_uri.query).each do |k, v|
        k = k.downcase.to_sym
        v = v.to_f if k == :expires_in
        @options[k] = v
      end
    end
  end
end
