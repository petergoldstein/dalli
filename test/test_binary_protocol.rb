# frozen_string_literal: true

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
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a port, but no weight" do
      s = Dalli::Protocol::Binary.new("localhost:11212")
      assert_equal "localhost", s.hostname
      assert_equal 11212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a port and a weight" do
      s = Dalli::Protocol::Binary.new("localhost:11212:2")
      assert_equal "localhost", s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv4 addresses" do
      s = Dalli::Protocol::Binary.new("127.0.0.1")
      assert_equal "127.0.0.1", s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses" do
      s = Dalli::Protocol::Binary.new("[::1]")
      assert_equal "::1", s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses with port" do
      s = Dalli::Protocol::Binary.new("[::1]:11212")
      assert_equal "::1", s.hostname
      assert_equal 11212, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles ipv6 addresses with port and weight" do
      s = Dalli::Protocol::Binary.new("[::1]:11212:2")
      assert_equal "::1", s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a FQDN" do
      s = Dalli::Protocol::Binary.new("my.fqdn.com")
      assert_equal "my.fqdn.com", s.hostname
      assert_equal 11211, s.port
      assert_equal 1, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "handles a FQDN with port and weight" do
      s = Dalli::Protocol::Binary.new("my.fqdn.com:11212:2")
      assert_equal "my.fqdn.com", s.hostname
      assert_equal 11212, s.port
      assert_equal 2, s.weight
      assert_equal :tcp, s.socket_type
    end

    it "throws an exception if the hostname cannot be parsed" do
      expect(lambda { Dalli::Protocol::Binary.new("[]") }).must_raise Dalli::DalliError
      expect(lambda { Dalli::Protocol::Binary.new("my.fqdn.com:") }).must_raise Dalli::DalliError
      expect(lambda { Dalli::Protocol::Binary.new("my.fqdn.com:11212,:2") }).must_raise Dalli::DalliError
      expect(lambda { Dalli::Protocol::Binary.new("my.fqdn.com:11212:abc") }).must_raise Dalli::DalliError
    end
  end

  describe "guard_max_value" do
    it "throws when size is over max" do
      s = Dalli::Protocol::Binary.new("127.0.0.1")
      value = OpenStruct.new(bytesize: 1_048_577)

      assert_raises Dalli::ValueOverMaxSize do
        s.send(:guard_max_value, :foo, value)
      end
    end
  end

  describe "deserialize" do
    subject { Dalli::Protocol::Binary.new("127.0.0.1") }

    it "uses Marshal as default serializer" do
      assert_equal subject.serializer, Marshal
    end

    it "deserializes serialized value" do
      value = "some_value"
      deserialized = subject.send(:deserialize, Marshal.dump(value), Dalli::Protocol::Binary::FLAG_SERIALIZED)
      assert_equal value, deserialized
    end

    it "raises UnmarshalError for broken data" do
      assert_raises Dalli::UnmarshalError do
        subject.send(:deserialize, :not_marshaled_value, Dalli::Protocol::Binary::FLAG_SERIALIZED)
      end
    end

    describe "custom serializer" do
      let(:serializer) { Minitest::Mock.new }
      subject { Dalli::Protocol::Binary.new("127.0.0.1", serializer: serializer) }

      it "uses custom serializer" do
        assert subject.serializer === serializer
      end

      it "reraises general NameError" do
        serializer.expect(:load, nil) do
          raise NameError, "ddd"
        end
        assert_raises NameError do
          subject.send(:deserialize, :some_value, Dalli::Protocol::Binary::FLAG_SERIALIZED)
        end
      end

      it "raises UnmarshalError on uninitialized constant" do
        serializer.expect(:load, nil) do
          raise NameError, "uninitialized constant Ddd"
        end
        assert_raises Dalli::UnmarshalError do
          subject.send(:deserialize, :some_value, Dalli::Protocol::Binary::FLAG_SERIALIZED)
        end
      end

      it "reraises general ArgumentError" do
        serializer.expect(:load, nil) do
          raise ArgumentError, "ddd"
        end
        assert_raises ArgumentError do
          subject.send(:deserialize, :some_value, Dalli::Protocol::Binary::FLAG_SERIALIZED)
        end
      end

      it "raises UnmarshalError on undefined class" do
        serializer.expect(:load, nil) do
          raise ArgumentError, "undefined class Ddd"
        end
        assert_raises Dalli::UnmarshalError do
          subject.send(:deserialize, :some_value, Dalli::Protocol::Binary::FLAG_SERIALIZED)
        end
      end
    end
  end

  describe "multi_response_nonblock" do
    subject { Dalli::Protocol::Binary.new("127.0.0.1") }

    it "raises NetworkError when called before multi_response_start" do
      assert_raises Dalli::NetworkError do
        subject.request(:send_multiget, ["a", "b"])
        subject.multi_response_nonblock
      end
    end

    it "raises NetworkError when called after multi_response_abort" do
      assert_raises Dalli::NetworkError do
        subject.request(:send_multiget, ["a", "b"])
        subject.multi_response_start
        subject.multi_response_abort
        subject.multi_response_nonblock
      end
    end
  end
end
