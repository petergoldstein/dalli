# frozen_string_literal: true

require_relative '../helper'

describe Dalli::Protocol::TtlSanitizer do
  describe 'sanitize' do
    subject { Dalli::Protocol::TtlSanitizer.sanitize(arg_value) }

    describe 'when the argument is an integer' do
      let(:arg_value) { arg_value_as_i }

      describe 'when the value is less than 30 days in seconds' do
        let(:arg_value_as_i) { rand((30 * 24 * 60 * 60) + 1) }

        it 'just returns the value' do
          assert_equal subject, arg_value_as_i
        end
      end

      describe 'when the value is more than 30 days in seconds, but less than the current timestamp' do
        let(:arg_value_as_i) { (30 * 24 * 60 * 60) + 1 + rand(100 * 24 * 60 * 60) }
        let(:now) { 1_634_706_177 }

        it 'converts to a future timestamp' do
          Dalli::Protocol::TtlSanitizer.stub :current_timestamp, now do
            assert_equal subject, arg_value_as_i + now
          end
        end
      end

      describe 'when the value is more than the current timestamp' do
        let(:now) { 1_634_706_177 }
        let(:arg_value_as_i) { now + 1 + rand(100 * 24 * 60 * 60) }

        it 'just returns the value' do
          Dalli::Protocol::TtlSanitizer.stub :current_timestamp, now do
            assert_equal subject, arg_value_as_i
          end
        end
      end
    end

    describe 'when the argument is a string' do
      let(:arg_value) { arg_value_as_i.to_s }

      describe 'when the value is less than 30 days in seconds' do
        let(:arg_value_as_i) { rand((30 * 24 * 60 * 60) + 1) }

        it 'just returns the value' do
          assert_equal subject, arg_value_as_i
        end
      end

      describe 'when the value is more than 30 days in seconds, but less than the current timestamp' do
        let(:arg_value_as_i) { (30 * 24 * 60 * 60) + 1 + rand(100 * 24 * 60 * 60) }
        let(:now) { 1_634_706_177 }

        it 'converts to a future timestamp' do
          Dalli::Protocol::TtlSanitizer.stub :current_timestamp, now do
            assert_equal subject, arg_value_as_i + now
          end
        end
      end

      describe 'when the value is more than the current timestamp' do
        let(:now) { 1_634_706_177 }
        let(:arg_value_as_i) { now + 1 + rand(100 * 24 * 60 * 60) }

        it 'just returns the value' do
          Dalli::Protocol::TtlSanitizer.stub :current_timestamp, now do
            assert_equal subject, arg_value_as_i
          end
        end
      end
    end
  end
end
