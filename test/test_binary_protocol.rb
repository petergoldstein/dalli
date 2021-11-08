# frozen_string_literal: true

require "ostruct"
require_relative "helper"

describe Dalli::Protocol::Binary do
  describe "hostname parsing" do
    it "handles unix socket with no weight" do
      s = Dalli::Protocol::Binary.new("/var/run/memcached/sock")
      assert_equal "/var/run/memcached/sock", s.hostname
      assert_equal 1, s.weight
      assert_equal :unix, s.socket_type
    end

    it "handles unix socket with a weight" do
      s = Dalli::Protocol::Binary.new("/var/run/memcached/sock:2")
      assert_equal "/var/run/memcached/sock", s.hostname
      assert_equal 2, s.weight
      assert_equal :unix, s.socket_type
    end

    it "handles no port or weight" do
      s = Dalli::Protocol::Binary.new("localhost")
      assert_equal "localhost", s.hostname
      assert_equal 11_211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a port, but no weight" do
      s = Dalli::Protocol::Binary.new("localhost:11212")
      assert_equal "localhost", s.hostname
      assert_equal 11_212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a port and a weight" do
      s = Dalli::Protocol::Binary.new("localhost:11212:2")
      assert_equal "localhost", s.hostname
      assert_equal 11_212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv4 addresses" do
      s = Dalli::Protocol::Binary.new("127.0.0.1")
      assert_equal "127.0.0.1", s.hostname
      assert_equal 11_211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses" do
      s = Dalli::Protocol::Binary.new("[::1]")
      assert_equal "::1", s.hostname
      assert_equal 11_211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses with port" do
      s = Dalli::Protocol::Binary.new("[::1]:11212")
      assert_equal "::1", s.hostname
      assert_equal 11_212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses with port and weight" do
      s = Dalli::Protocol::Binary.new("[::1]:11212:2")
      assert_equal "::1", s.hostname
      assert_equal 11_212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a FQDN" do
      s = Dalli::Protocol::Binary.new("my.fqdn.com")
      assert_equal "my.fqdn.com", s.hostname
      assert_equal 11_211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a FQDN with port and weight" do
      s = Dalli::Protocol::Binary.new("my.fqdn.com:11212:2")
      assert_equal "my.fqdn.com", s.hostname
      assert_equal 11_212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "throws an exception if the hostname cannot be parsed" do
      expect(-> { Dalli::Protocol::Binary.new("[]") }).must_raise Dalli::DalliError
      expect(-> { Dalli::Protocol::Binary.new("my.fqdn.com:") }).must_raise Dalli::DalliError
      expect(-> { Dalli::Protocol::Binary.new("my.fqdn.com:11212,:2") }).must_raise Dalli::DalliError
      expect(-> { Dalli::Protocol::Binary.new("my.fqdn.com:11212:abc") }).must_raise Dalli::DalliError
    end
  end

  describe "multi_response_nonblock" do
    subject { Dalli::Protocol::Binary.new("127.0.0.1") }

    it "raises NetworkError when called before multi_response_start" do
      assert_raises Dalli::NetworkError do
        subject.request(:send_multiget, %w[a b])
        subject.multi_response_nonblock
      end
    end

    it "raises NetworkError when called after multi_response_abort" do
      assert_raises Dalli::NetworkError do
        subject.request(:send_multiget, %w[a b])
        subject.multi_response_start
        subject.multi_response_abort
        subject.multi_response_nonblock
      end
    end
  end
end
