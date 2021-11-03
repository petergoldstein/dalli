# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ServerConfigParser do
  describe 'parse' do
    let(:port) { rand(9999..99_999) }
    let(:weight) { rand(1..5) }

    describe 'when the string is not an memcached URI' do
      let(:options) { {} }

      describe 'tcp' do
        describe 'when the hostname is a domain name' do
          let(:hostname) { "a#{SecureRandom.hex(5)}.b#{SecureRandom.hex(3)}.#{%w[net com edu].sample}" }

          it 'parses a hostname by itself' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname, options), [hostname, 11_211, 1, :tcp, {}]
          end

          it 'parses hostname with a port' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}", options),
                         [hostname, port, 1, :tcp, {}]
          end

          it 'parses hostname with a port and weight' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}", options),
                         [hostname, port, weight, :tcp, {}]
          end
        end

        describe 'when the hostname is an IPv4 address' do
          let(:hostname) { '203.0.113.28' }

          it 'parses a hostname by itself' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname, options), [hostname, 11_211, 1, :tcp, {}]
          end

          it 'parses hostname with a port' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}", options),
                         [hostname, port, 1, :tcp, {}]
          end

          it 'parses hostname with a port and weight' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}", options),
                         [hostname, port, weight, :tcp, {}]
          end
        end

        describe 'when the hostname is an IPv6 address' do
          let(:hostname) { ['2001:db8:ffff:ffff:ffff:ffff:ffff:ffff', '2001:db8::'].sample }

          it 'parses a hostname by itself' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("[#{hostname}]", options),
                         [hostname, 11_211, 1, :tcp, {}]
          end

          it 'parses hostname with a port' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("[#{hostname}]:#{port}", options),
                         [hostname, port, 1, :tcp, {}]
          end

          it 'parses hostname with a port and weight' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse("[#{hostname}]:#{port}:#{weight}", options),
                         [hostname, port, weight, :tcp, {}]
          end
        end
      end

      describe 'unix' do
        let(:hostname) { "/tmp/#{SecureRandom.hex(5)}" }

        it 'parses a socket by itself' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname, {}), [hostname, nil, 1, :unix, {}]
        end

        it 'parses socket with a weight' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{weight}", {}),
                       [hostname, nil, weight, :unix, {}]
        end

        it 'produces an error with a port and weight' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}", {})
          end
          assert_equal err.message, "Could not parse hostname #{hostname}:#{port}:#{weight}"
        end
      end
    end

    describe 'when the string is a memcached URI' do
      let(:user) { SecureRandom.hex(5) }
      let(:password) { SecureRandom.hex(5) }
      let(:port) { rand(15_000..16_023) }
      let(:hostname) { "a#{SecureRandom.hex(3)}.b#{SecureRandom.hex(3)}.com" }

      describe 'when the URI is properly formed and includes all values' do
        let(:uri) { "memcached://#{user}:#{password}@#{hostname}:#{port}" }

        describe 'when the client options are empty' do
          let(:client_options) { {} }

          it 'parses correctly' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse(uri, client_options),
                         [hostname, port, 1, :tcp, { username: user, password: password }]
          end
        end

        describe 'when the client options are not empty' do
          let(:option_a) { SecureRandom.hex(3) }
          let(:option_b) { SecureRandom.hex(3) }
          let(:client_options) { { a: option_a, b: option_b } }

          it 'parses correctly' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse(uri, client_options),
                         [hostname, port, 1, :tcp, { username: user, password: password, a: option_a, b: option_b }]
          end
        end
      end

      describe 'when the URI does not include a port' do
        let(:uri) { "memcached://#{user}:#{password}@#{hostname}" }

        describe 'when the client options are empty' do
          let(:client_options) { {} }

          it 'parses correctly' do
            assert_equal Dalli::Protocol::ServerConfigParser.parse(uri, client_options),
                         [hostname, 11_211, 1, :tcp, { username: user, password: password }]
          end
        end
      end

    end

    describe 'errors' do
      describe 'when the string is empty' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse('', {})
          end
          assert_equal err.message, 'Could not parse hostname '
        end
      end

      describe 'when the string starts with a colon' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse(':1:2', {})
          end
          assert_equal err.message, 'Could not parse hostname :1:2'
        end
      end

      describe 'when the string ends with a colon' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse('abc.com:', {})
          end
          assert_equal err.message, 'Could not parse hostname abc.com:'
        end
      end
    end
  end
end
