# frozen_string_literal: true

require_relative '../helper'

describe 'authentication options' do
  it 'warns when username is provided' do
    logged_messages = []
    original_logger = Dalli.logger
    Dalli.logger = Logger.new(StringIO.new).tap do |logger|
      logger.define_singleton_method(:warn) { |msg| logged_messages << msg }
    end

    begin
      memcached_persistent(:meta, port_or_socket: 21_345, cli_args: '',
                                  client_options: { username: 'user' }) do |_dc, port|
        # Create client with auth options that should trigger warnings
        client = Dalli::Client.new("localhost:#{port}", username: 'user', password: 'pass')
        client.flush
        client.set('key1', 'abcd')

        assert_equal 'abcd', client.get('key1')
      end

      assert_includes logged_messages, 'Dalli 5.0 removed SASL authentication support. The :username option is ignored.'
      assert_includes logged_messages, 'Dalli 5.0 removed SASL authentication support. The :password option is ignored.'
    ensure
      Dalli.logger = original_logger
    end
  end

  it 'warns when protocol: :binary option is provided' do
    logged_messages = []
    original_logger = Dalli.logger
    Dalli.logger = Logger.new(StringIO.new).tap do |logger|
      logger.define_singleton_method(:warn) { |msg| logged_messages << msg }
    end

    begin
      memcached_persistent(:meta, port_or_socket: 21_346) do |_dc, port|
        # Create client with binary protocol option that should trigger warning
        # This is the more common case - users upgrading from 4.x with explicit binary protocol
        client = Dalli::Client.new("localhost:#{port}", protocol: :binary)
        client.flush
        client.set('key1', 'value')

        assert_equal 'value', client.get('key1')
      end

      assert_includes logged_messages,
                      'Dalli 5.0 only supports the meta protocol. The :protocol option has been removed.'
    ensure
      Dalli.logger = original_logger
    end
  end

  it 'warns when credentials are embedded in memcached:// URI' do
    logged_messages = []
    original_logger = Dalli.logger
    Dalli.logger = Logger.new(StringIO.new).tap do |logger|
      logger.define_singleton_method(:warn) { |msg| logged_messages << msg }
    end

    begin
      memcached_persistent(:meta, port_or_socket: 21_347) do |_dc, port|
        # Create client with credentials in URI that should trigger warning
        client = Dalli::Client.new("memcached://user:pass@localhost:#{port}")
        client.flush
        client.set('key1', 'value')

        assert_equal 'value', client.get('key1')
      end

      assert_includes logged_messages,
                      'Dalli 5.0 removed SASL authentication. Credentials in memcached:// URIs are ignored.'
    ensure
      Dalli.logger = original_logger
    end
  end
end
