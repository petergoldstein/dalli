# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ServerConfigParser do
  describe 'parse' do
    let(:port) { rand(9999..99_999) }
    let(:weight) { rand(1..5) }

    describe 'tcp' do
      describe 'when the hostname is a domain name' do
        let(:hostname) { "a#{SecureRandom.hex(5)}.b#{SecureRandom.hex(3)}.#{%w[net com edu].sample}" }

        it 'parses a hostname by itself' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname), [hostname, 11_211, 1, :tcp]
        end

        it 'parses hostname with a port' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}"), [hostname, port, 1, :tcp]
        end

        it 'parses hostname with a port and weight' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}"),
                       [hostname, port, weight, :tcp]
        end
      end

      describe 'when the hostname is an IPv4 address' do
        let(:hostname) { '203.0.113.28' }

        it 'parses a hostname by itself' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname), [hostname, 11_211, 1, :tcp]
        end

        it 'parses hostname with a port' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}"), [hostname, port, 1, :tcp]
        end

        it 'parses hostname with a port and weight' do
          assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}"),
                       [hostname, port, weight, :tcp]
        end
      end
    end

    describe 'unix' do
      let(:hostname) { "/tmp/#{SecureRandom.hex(5)}" }

      it 'parses a socket by itself' do
        assert_equal Dalli::Protocol::ServerConfigParser.parse(hostname), [hostname, nil, 1, :unix]
      end

      it 'parses socket with a weight' do
        assert_equal Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{weight}"), [hostname, nil, weight, :unix]
      end

      it 'produces an error with a port and weight' do
        err = assert_raises Dalli::DalliError do
          Dalli::Protocol::ServerConfigParser.parse("#{hostname}:#{port}:#{weight}")
        end
        assert_equal err.message, "Could not parse hostname #{hostname}:#{port}:#{weight}"
      end
    end

    describe 'errors' do
      describe 'when the string is empty' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse('')
          end
          assert_equal err.message, 'Could not parse hostname '
        end
      end

      describe 'when the string starts with a colon' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse(':1:2')
          end
          assert_equal err.message, 'Could not parse hostname :1:2'
        end
      end

      describe 'when the string ends with a colon' do
        it 'produces an error' do
          err = assert_raises Dalli::DalliError do
            Dalli::Protocol::ServerConfigParser.parse('abc.com:')
          end
          assert_equal err.message, 'Could not parse hostname abc.com:'
        end
      end
    end
  end
end
