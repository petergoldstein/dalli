# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ResponseBuffer do
  let(:pipes) { IO.pipe }
  let(:write_pipe) { pipes.last }
  let(:io_source) do
    io = pipes.first
    io.extend(Dalli::Socket::InstanceMethods)
    io.define_singleton_method(:options) { {} }
    io
  end

  let(:marshaller) { Dalli::Protocol::StringMarshaller.new({}) }
  let(:processor) { Dalli::Protocol::Meta::ResponseProcessor.new(io_source, marshaller) }
  let(:buffer) { Dalli::Protocol::ResponseBuffer.new(io_source, processor) }

  describe '#in_progress?' do
    it 'returns false for an uninitialized buffer' do
      refute_predicate buffer, :in_progress?
    end

    it 'returns true for a ready buffer' do
      buffer.ensure_ready

      assert_predicate buffer, :in_progress?
    end

    it 'returns false for a cleared buffer' do
      buffer.ensure_ready
      buffer.clear

      refute_predicate buffer, :in_progress?
    end
  end

  describe '#process_single_getk_response' do
    before { buffer.ensure_ready }

    it 'returns all nils when the buffer is empty' do
      buffer.read

      assert_equal [nil, nil, nil, nil], buffer.process_single_getk_response
    end

    it "returns all nils if the response value hasn't yet been buffered" do
      write_pipe.write("VA 2 s2 t-1 c2 kfoo\r\nHI\r")
      buffer.read

      assert_equal [nil, nil, nil, nil], buffer.process_single_getk_response
    end

    it 'returns the parsed value if it has been fully buffered' do
      write_pipe.write("VA 2 s2 t-1 c2 kfoo\r\nHI\r\ngarbage")
      buffer.read

      assert_equal [true, 2, 'foo', 'HI'], buffer.process_single_getk_response
    end

    it 'advances the offset' do
      write_pipe.write("VA 2 s2 t-1 c2 kfoo\r\nHI\r\nVA 2 s5 t-1 c2 kfoo\r\nHELLO\r\ngarbage")
      buffer.read

      assert_equal [true, 2, 'foo', 'HI'], buffer.process_single_getk_response
      assert_equal [true, 2, 'foo', 'HELLO'], buffer.process_single_getk_response
    end

    it 'returns [true, *nil] when reaching MN' do
      write_pipe.write("VA 2 s2 t-1 c2 kfoo\r\nHI\r\nMN\r\n")
      buffer.read

      assert_equal [true, 2, 'foo', 'HI'], buffer.process_single_getk_response
      assert_equal [true, nil, nil, nil], buffer.process_single_getk_response
    end
  end
end
