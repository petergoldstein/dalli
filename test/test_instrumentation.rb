# frozen_string_literal: true

require_relative 'helper'

# Mock OpenTelemetry classes for testing
module MockOpenTelemetry
  class MockSpan
    attr_reader :name, :attributes, :kind, :recorded_exceptions
    attr_accessor :status

    def initialize(name, attributes:, kind:)
      @name = name
      @attributes = attributes
      @kind = kind
      @recorded_exceptions = []
      @status = nil
    end

    def record_exception(exception)
      @recorded_exceptions << exception
    end
  end

  class MockTracer
    attr_reader :spans

    def initialize
      @spans = []
    end

    def in_span(name, attributes:, kind:)
      span = MockSpan.new(name, attributes: attributes, kind: kind)
      @spans << span
      yield span
    end
  end

  class MockTracerProvider
    def initialize(tracer)
      @mock_tracer = tracer
    end

    def tracer(_name, _version)
      @mock_tracer
    end
  end

  class MockStatus
    attr_reader :code, :description

    def initialize(code, description)
      @code = code
      @description = description
    end

    def self.error(message)
      new(:error, message)
    end
  end
end

describe Dalli::Instrumentation do
  def clear_tracer_cache
    return unless Dalli::Instrumentation.instance_variable_defined?(:@tracer)

    Dalli::Instrumentation.remove_instance_variable(:@tracer)
  end

  describe '.tracer' do
    it 'returns nil when OpenTelemetry is not defined' do
      clear_tracer_cache

      refute defined?(OpenTelemetry), 'OpenTelemetry should not be defined in this test environment'
      assert_nil Dalli::Instrumentation.tracer
    end
  end

  describe '.enabled?' do
    it 'returns false when OpenTelemetry is not available' do
      clear_tracer_cache

      refute_predicate Dalli::Instrumentation, :enabled?
    end
  end

  describe '.trace without OpenTelemetry' do
    it 'yields the block and returns its result when tracing is disabled' do
      clear_tracer_cache

      result = Dalli::Instrumentation.trace('test_operation', { 'test.key' => 'value' }) do
        'block result'
      end

      assert_equal 'block result', result
    end

    it 'propagates exceptions from the block' do
      clear_tracer_cache

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

  describe '.trace with mock OpenTelemetry' do
    before do
      clear_tracer_cache
      @mock_tracer = MockOpenTelemetry::MockTracer.new
      @mock_provider = MockOpenTelemetry::MockTracerProvider.new(@mock_tracer)

      # Define mock OpenTelemetry module
      Object.const_set(:OpenTelemetry, Module.new) unless defined?(OpenTelemetry)
      mock_provider = @mock_provider
      OpenTelemetry.define_singleton_method(:tracer_provider) { mock_provider }

      # Define mock Status class
      unless defined?(OpenTelemetry::Trace::Status)
        OpenTelemetry.const_set(:Trace, Module.new)
        OpenTelemetry::Trace.const_set(:Status, MockOpenTelemetry::MockStatus)
      end
    end

    after do
      clear_tracer_cache
      # Remove mock OpenTelemetry
      Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
    end

    it 'returns true for enabled? when OpenTelemetry is available' do
      assert_predicate Dalli::Instrumentation, :enabled?
    end

    it 'creates a span with correct name and attributes' do
      Dalli::Instrumentation.trace('get', { 'db.operation' => 'get' }) { 'result' }

      assert_equal 1, @mock_tracer.spans.size
      span = @mock_tracer.spans.first

      assert_equal 'get', span.name
      assert_equal 'memcached', span.attributes['db.system']
      assert_equal 'get', span.attributes['db.operation']
      assert_equal :client, span.kind
    end

    it 'returns the block result' do
      result = Dalli::Instrumentation.trace('set', {}) { 'cached_value' }

      assert_equal 'cached_value', result
    end

    it 'records exceptions on the span' do
      error = assert_raises(RuntimeError) do
        Dalli::Instrumentation.trace('get', {}) do
          raise 'connection failed'
        end
      end

      assert_equal 'connection failed', error.message
      span = @mock_tracer.spans.first

      assert_equal 1, span.recorded_exceptions.size
      assert_equal 'connection failed', span.recorded_exceptions.first.message
    end

    it 'sets error status on span when exception occurs' do
      assert_raises(RuntimeError) do
        Dalli::Instrumentation.trace('get', {}) do
          raise 'network error'
        end
      end

      span = @mock_tracer.spans.first

      assert_equal :error, span.status.code
      assert_equal 'network error', span.status.description
    end

    it 're-raises exceptions after recording them' do
      assert_raises(Dalli::DalliError) do
        Dalli::Instrumentation.trace('get', {}) do
          raise Dalli::DalliError, 'memcached error'
        end
      end
    end

    it 'merges default attributes with provided attributes' do
      Dalli::Instrumentation.trace('get_multi', { 'custom.attr' => 'value' }) { 'result' }

      span = @mock_tracer.spans.first

      assert_equal 'memcached', span.attributes['db.system']
      assert_equal 'value', span.attributes['custom.attr']
    end
  end
end
