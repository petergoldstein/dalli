# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ValueCompressor do
  describe 'options' do
    subject { Dalli::Protocol::ValueCompressor.new(options) }

    describe 'compress_by_default?' do
      describe 'when the compress option is unspecified' do
        let(:options) { {} }

        it 'defaults to true' do
          assert_predicate subject, :compress_by_default?
        end
      end

      describe 'when the compress option is explicitly true' do
        let(:options) { { compress: true } }

        it 'is true' do
          assert_predicate subject, :compress_by_default?
        end
      end

      describe 'when the compress option is explicitly false' do
        let(:options) { { compress: false } }

        it 'is false' do
          refute_predicate subject, :compress_by_default?
        end
      end
    end

    describe 'compressor' do
      describe 'when the compressor option is unspecified' do
        let(:options) { {} }

        it 'defaults to Dalli::Compressor' do
          assert_equal subject.compressor, Dalli::Compressor
        end
      end

      describe 'when the compressor option is explicitly specified' do
        let(:dummy_compressor) { Object.new }
        let(:options) { { compressor: dummy_compressor } }

        it 'uses the explicit option' do
          assert_equal subject.compressor, dummy_compressor
        end
      end
    end

    describe 'compression_min_size' do
      describe 'when the compression_min_size option is unspecified' do
        let(:options) { {} }

        it 'defaults to 4 KB' do
          assert_equal(4096, subject.compression_min_size)
        end
      end

      describe 'when the compression_min_size option is explicitly specified' do
        let(:size) { rand(1..4096) }
        let(:options) { { compression_min_size: size } }

        it 'uses the explicit option' do
          assert_equal subject.compression_min_size, size
        end
      end
    end
  end

  describe 'store' do
    let(:bitflags) { rand(32) }
    let(:compressor) { Minitest::Mock.new }
    let(:compressed_dummy) { SecureRandom.hex(8) }
    let(:compressor_options) { { compressor: compressor } }
    let(:vc) { Dalli::Protocol::ValueCompressor.new(vc_options) }

    describe 'when the raw value is below the compression_min_size' do
      describe 'when no compression_min_size options is set' do
        let(:compression_min_size_options) { compressor_options }
        describe 'when the value size is less than the default compression_min_size' do
          let(:raw_value) { 'a' * (4096 - 1) }

          describe 'when the client-level compress option is set to true' do
            let(:vc_options) { compression_min_size_options.merge(compress: true) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end

          describe 'when the client-level compress option is set to false' do
            let(:vc_options) { compression_min_size_options.merge(compress: false) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end
        end

        describe 'when the value size is greater than the default compression_min_size' do
          let(:raw_value) { 'a' * (4096 + 1) }

          describe 'when the client-level compress option is set to true' do
            let(:vc_options) { compression_min_size_options.merge(compress: true) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end

          describe 'when the client-level compress option is set to false' do
            let(:vc_options) { compression_min_size_options.merge(compress: false) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end
        end
      end

      describe 'when a compression_min_size options is explicitly set' do
        let(:compression_min_size) { 512 }
        let(:compression_min_size_options) { compressor_options.merge(compression_min_size: compression_min_size) }

        describe 'when the value size is less than the explicit compression size' do
          let(:raw_value) { 'a' * (compression_min_size - 1) }

          describe 'when the client-level compress option is set to true' do
            let(:vc_options) { compression_min_size_options.merge(compress: true) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end

          describe 'when the client-level compress option is set to false' do
            let(:vc_options) { compression_min_size_options.merge(compress: false) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end
        end

        describe 'when the value size is greater than the explicit compression size' do
          let(:raw_value) { 'a' * (compression_min_size + 1) }

          describe 'when the client-level compress option is set to true' do
            let(:vc_options) { compression_min_size_options.merge(compress: true) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end

          describe 'when the client-level compress option is set to false' do
            let(:vc_options) { compression_min_size_options.merge(compress: false) }

            describe 'when the request options do not specify an explicit compress option' do
              let(:req_options) { {} }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end

            describe 'when the request options specify compress as true' do
              let(:req_options) { { compress: true } }

              it 'compresses the argument' do
                compressor.expect :compress, compressed_dummy, [raw_value]
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, compressed_dummy
                assert_equal newbitflags, (bitflags | 0x2)
                compressor.verify
              end
            end

            describe 'when the request options specify compress as false' do
              let(:req_options) { { compress: false } }

              it 'does not compress the argument' do
                val, newbitflags = vc.store(raw_value, req_options, bitflags)

                assert_equal val, raw_value
                assert_equal newbitflags, bitflags
                compressor.verify
              end
            end
          end
        end
      end
    end

    # Raw reads ignore bitflags, so a raw write must store the bytes as given
    describe 'when the request options specify raw' do
      let(:vc) { Dalli::Protocol::ValueCompressor.new(compress: true) }
      let(:raw_value) { 'a' * 5000 }

      it 'does not compress a value above the compression_min_size' do
        val, newbitflags = vc.store(raw_value, { raw: true }, bitflags)

        assert_equal raw_value, val
        assert_equal bitflags, newbitflags
      end

      it 'does not compress even when compress is explicitly true' do
        val, newbitflags = vc.store(raw_value, { raw: true, compress: true }, bitflags)

        assert_equal raw_value, val
        assert_equal bitflags, newbitflags
      end

      it 'still compresses when raw is false' do
        val, newbitflags = vc.store(raw_value, { raw: false }, 0)

        assert_equal Dalli::Flags::COMPRESSED, newbitflags
        assert_equal raw_value, Dalli::Compressor.decompress(val)
      end
    end
  end

  describe 'decompressed_max_bytes' do
    let(:data) { 'abc' * 100_000 }
    let(:compressed) { Dalli::Compressor.compress(data) }
    let(:bitflags) { Dalli::Flags::COMPRESSED }

    it 'defaults to 128 MiB' do
      assert_equal 128 * 1024 * 1024, Dalli::Protocol::ValueCompressor::DEFAULTS[:decompressed_max_bytes]
    end

    it 'rejects values that decompress past the configured limit' do
      vc = Dalli::Protocol::ValueCompressor.new(decompressed_max_bytes: 1024)

      assert_raises(Dalli::UnmarshalError) { vc.retrieve(compressed, bitflags) }
    end

    it 'can be disabled with nil' do
      vc = Dalli::Protocol::ValueCompressor.new(decompressed_max_bytes: nil)

      assert_equal data.b, vc.retrieve(compressed, bitflags).b
    end

    it 'still calls a custom compressor that only defines decompress(data)' do
      custom = Class.new do
        def self.compress(data) = Zlib::Deflate.deflate(data)
        def self.decompress(data) = Zlib::Inflate.inflate(data)
      end
      vc = Dalli::Protocol::ValueCompressor.new(compressor: custom, decompressed_max_bytes: 1024)

      assert_equal data.b, vc.retrieve(compressed, bitflags).b
    end
  end

  describe 'retrieve' do
    let(:raw_value) { SecureRandom.hex(8) }
    let(:decompressed_dummy) { SecureRandom.hex(8) }
    let(:vc) { Dalli::Protocol::ValueCompressor.new(vc_options) }

    describe 'when the bitflags do not specify compression' do
      let(:compressor) { Minitest::Mock.new }
      let(:vc_options) { { compressor: compressor } }

      it 'should return the value without decompressing' do
        bitflags = rand(32)
        bitflags &= 0xFFFD

        assert_equal(0, bitflags & 0x2)
        assert_equal vc.retrieve(raw_value, bitflags), raw_value
        compressor.verify
      end
    end

    describe 'when the bitflags specify compression' do
      let(:compressor) { Minitest::Mock.new }
      let(:vc_options) { { compressor: compressor } }

      it 'should decompress the value' do
        compressor.expect :decompress, decompressed_dummy, [raw_value]
        bitflags = rand(32)
        bitflags |= 0x2

        assert_equal(0x2, bitflags & 0x2)
        assert_equal vc.retrieve(raw_value, bitflags), decompressed_dummy
        compressor.verify
      end
    end

    describe 'when the decompression raises a Zlib::Error' do
      let(:vc_options) { {} }
      let(:error_message) { SecureRandom.hex(10) }

      it 'translates that into a UnmarshalError' do
        error = ->(_arg) { raise Zlib::Error, error_message }
        Dalli::Compressor.stub :decompress, error do
          bitflags = rand(32)
          bitflags |= 0x2

          assert_equal(0x2, bitflags & 0x2)
          exception = assert_raises Dalli::UnmarshalError do
            vc.retrieve(raw_value, bitflags)
          end

          assert_equal exception.message, "Unable to uncompress value: #{error_message}"
        end
      end
    end
  end
end
