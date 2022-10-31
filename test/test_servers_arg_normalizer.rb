# frozen_string_literal: true

require_relative 'helper'

describe Dalli::ServersArgNormalizer do
  describe 'normalize_servers' do
    subject { Dalli::ServersArgNormalizer.normalize_servers(arg) }

    describe 'when the argument is nil' do
      let(:arg) { nil }

      describe 'when the MEMCACHE_SERVERS environment is set' do
        let(:server_string) { 'example.com:1234' }

        before do
          ENV['MEMCACHE_SERVERS'] = server_string
        end

        after do
          ENV['MEMCACHE_SERVERS'] = nil
        end

        it 'returns the value from the environment' do
          assert_equal [server_string], subject
        end
      end

      describe 'when the MEMCACHE_SERVERS environment is not set' do
        it 'returns the expected default' do
          assert_equal ['127.0.0.1:11211'], subject
        end
      end
    end

    describe 'when the argument is a single string' do
      describe 'when the string is a single entry' do
        let(:arg) { 'example.com:1234' }

        it 'returns the single entry as an array' do
          assert_equal [arg], subject
        end
      end

      describe 'when the string is multiple comma separated entries' do
        let(:server1) { 'example.com:1234' }
        let(:server2) { '127.0.0.1:11111' }
        let(:server3) { 'abc.def.com:7890' }
        let(:arg) { [server1, server2, server3].join(',') }

        it 'splits the string and returns an array' do
          assert_equal [server1, server2, server3], subject
        end
      end

      describe 'when the string is multiple comma separated entries with empty entries' do
        let(:server1) { 'example.com:1234' }
        let(:server2) { '127.0.0.1:11111' }
        let(:server3) { 'abc.def.com:7890' }
        let(:arg) { [server1, server2, '', server3, ''].join(',') }

        it 'splits the string and returns an array, discarding the empty elements' do
          assert_equal [server1, server2, server3], subject
        end
      end
    end

    describe 'when the argument is an array of strings' do
      describe 'when there is a single entry, with no commas' do
        let(:server1) { 'example.com:1234' }
        let(:arg) { [server1] }

        it 'returns the single entry as an array' do
          assert_equal arg, subject
        end
      end

      describe 'when there is a single entry, with commas' do
        let(:server1) { 'example.com:1234' }
        let(:server2) { '127.0.0.1:11111' }
        let(:server3) { 'abc.def.com:7890' }
        let(:arg) { [[server1, server2, server3].join(',')] }

        it 'returns the servers as an array' do
          assert_equal [server1, server2, server3], subject
        end
      end

      describe 'when there are multiple entries' do
        let(:server1) { 'example.com:1234' }
        let(:server2) { '127.0.0.1:11111' }
        let(:server3) { 'abc.def.com:7890' }
        let(:server4) { 'localhost' }
        let(:server5) { '192.168.0.6:11211:3' }
        let(:server6) { '192.168.0.6:11211:3' }
        let(:arg) do
          entry1 = [server1, server2, server3].join(',')
          entry2 = server4
          entry3 = [server5, '', server6].join(',')
          [entry1, entry2, entry3]
        end

        it 'returns the individual servers as an array' do
          assert_equal [server1, server2, server3, server4, server5, server6], subject
        end
      end
    end

    describe 'when the argument is an array with non-strings' do
      let(:arg) { [1, 2, 3, 4] }

      it 'raises an error' do
        err = assert_raises ArgumentError do
          subject
        end

        assert_equal 'An explicit servers argument must be a comma separated string or an array containing strings.',
                     err.message
      end
    end

    describe 'when the argument is neither a string nor an array of strings' do
      let(:arg) { Object.new }

      it 'raises an error' do
        err = assert_raises ArgumentError do
          subject
        end

        assert_equal 'An explicit servers argument must be a comma separated string or an array containing strings.',
                     err.message
      end
    end
  end
end
