# frozen_string_literal: true

require_relative 'helper'

describe Dalli::Instrumentation do
  describe '.tracer' do
    it 'returns nil when OpenTelemetry is not defined' do
      # Clear the cached tracer
      if Dalli::Instrumentation.instance_variable_defined?(:@tracer)
        Dalli::Instrumentation.remove_instance_variable(:@tracer)
      end

      refute defined?(OpenTelemetry), 'OpenTelemetry should not be defined in this test environment'
      assert_nil Dalli::Instrumentation.tracer
    end
  end

  describe '.enabled?' do
    it 'returns false when OpenTelemetry is not available' do
      # Clear the cached tracer
      if Dalli::Instrumentation.instance_variable_defined?(:@tracer)
        Dalli::Instrumentation.remove_instance_variable(:@tracer)
      end

      refute_predicate Dalli::Instrumentation, :enabled?
    end
  end

  describe '.trace' do
    it 'yields the block and returns its result when tracing is disabled' do
      # Clear the cached tracer
      if Dalli::Instrumentation.instance_variable_defined?(:@tracer)
        Dalli::Instrumentation.remove_instance_variable(:@tracer)
      end

      result = Dalli::Instrumentation.trace('test_operation', { 'test.key' => 'value' }) do
        'block result'
      end

      assert_equal 'block result', result
    end

    it 'propagates exceptions from the block' do
      # Clear the cached tracer
      if Dalli::Instrumentation.instance_variable_defined?(:@tracer)
        Dalli::Instrumentation.remove_instance_variable(:@tracer)
      end

      assert_raises(RuntimeError) do
        Dalli::Instrumentation.trace('test_operation') do
          raise 'test error'
        end
      end
    end
  end

  describe 'DEFAULT_ATTRIBUTES' do
    it 'includes db.system set to memcached' do
      assert_equal({ 'db.system' => 'memcached' }, Dalli::Instrumentation::DEFAULT_ATTRIBUTES)
    end

    it 'is frozen' do
      assert_predicate Dalli::Instrumentation::DEFAULT_ATTRIBUTES, :frozen?
    end
  end
end
