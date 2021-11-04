# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::ValueMarshaller do
  describe 'options' do
    subject { Dalli::Protocol::ValueMarshaller.new(options) }

    describe 'value_max_bytes' do
      describe 'by default' do
        let(:options) { {} }

        it 'sets value_max_bytes to 1MB by default' do
          assert_equal subject.value_max_bytes, 1024 * 1024
        end
      end

      describe 'with a user specified value' do
        let(:value_max_bytes) { rand(4 * 1024 * 1024) + 1 }
        let(:options) { { value_max_bytes: value_max_bytes } }

        it 'sets value_max_bytes to the user specified value' do
          assert_equal subject.value_max_bytes, value_max_bytes
        end
      end
    end
  end
end
