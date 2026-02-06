# frozen_string_literal: true

require_relative 'helper'

# Mock OpenTelemetry classes for testing
module MockOpenTelemetry
  class MockSpan
    attr_reader :name, :attributes, :kind, :recorded_exceptions
    attr_accessor :status

    def initialize(name, attributes:, kind:)
      @name = name
      @attributes = attributes.dup
      @kind = kind
      @recorded_exceptions = []
      @status = nil
    end

    def record_exception(exception)
      @recorded_exceptions << exception
    end

    def set_attribute(key, value)
      @attributes[key] = value
    end

    def add_attributes(attrs)
      @attributes.merge!(attrs)
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
    it 'includes db.system.name set to memcached' do
      assert_equal({ 'db.system.name' => 'memcached' }, Dalli::Instrumentation::DEFAULT_ATTRIBUTES)
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
      Dalli::Instrumentation.trace('get', { 'db.operation.name' => 'get' }) { 'result' }

      assert_equal 1, @mock_tracer.spans.size
      span = @mock_tracer.spans.first

      assert_equal 'get', span.name
      assert_equal 'memcached', span.attributes['db.system.name']
      assert_equal 'get', span.attributes['db.operation.name']
      assert_equal :client, span.kind
    end

    it 'returns the block result' do
      result = Dalli::Instrumentation.trace('set', {}) { 'cached_value' }

      assert_equal 'cached_value', result
    end

    # Exception recording and error status are handled automatically by
    # OpenTelemetry's in_span method, so we don't test those explicitly here.
    # See: https://github.com/open-telemetry/opentelemetry-ruby/blob/main/api/lib/opentelemetry/trace/tracer.rb

    it 're-raises exceptions' do
      assert_raises(Dalli::DalliError) do
        Dalli::Instrumentation.trace('get', {}) do
          raise Dalli::DalliError, 'memcached error'
        end
      end
    end

    it 'merges default attributes with provided attributes' do
      Dalli::Instrumentation.trace('get_multi', { 'custom.attr' => 'value' }) { 'result' }

      span = @mock_tracer.spans.first

      assert_equal 'memcached', span.attributes['db.system.name']
      assert_equal 'value', span.attributes['custom.attr']
    end
  end

  describe '.trace_with_result with mock OpenTelemetry' do
    before do
      clear_tracer_cache
      @mock_tracer = MockOpenTelemetry::MockTracer.new
      @mock_provider = MockOpenTelemetry::MockTracerProvider.new(@mock_tracer)

      Object.const_set(:OpenTelemetry, Module.new) unless defined?(OpenTelemetry)
      mock_provider = @mock_provider
      OpenTelemetry.define_singleton_method(:tracer_provider) { mock_provider }

      unless defined?(OpenTelemetry::Trace::Status)
        OpenTelemetry.const_set(:Trace, Module.new)
        OpenTelemetry::Trace.const_set(:Status, MockOpenTelemetry::MockStatus)
      end
    end

    after do
      clear_tracer_cache
      Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
    end

    it 'yields the span to the block' do
      yielded_span = nil
      Dalli::Instrumentation.trace_with_result('get_multi', {}) do |span|
        yielded_span = span
        'result'
      end

      assert_equal @mock_tracer.spans.first, yielded_span
    end

    it 'allows setting attributes on the span after execution' do
      Dalli::Instrumentation.trace_with_result('get_multi', { 'db.operation.name' => 'get_multi' }) do |span|
        span.set_attribute('db.memcached.hit_count', 5)
        span.set_attribute('db.memcached.miss_count', 2)
        'result'
      end

      span = @mock_tracer.spans.first

      assert_equal 5, span.attributes['db.memcached.hit_count']
      assert_equal 2, span.attributes['db.memcached.miss_count']
    end

    it 'yields nil when tracing is disabled' do
      clear_tracer_cache
      Object.send(:remove_const, :OpenTelemetry)

      yielded_value = :not_set
      result = Dalli::Instrumentation.trace_with_result('get_multi', {}) do |span|
        yielded_value = span
        'result'
      end

      assert_nil yielded_value
      assert_equal 'result', result
    end

    # Exception recording is handled automatically by OpenTelemetry's in_span method
  end

  describe 'client integration with mock OpenTelemetry' do
    before do
      skip 'Meta protocol requires memcached 1.6+' unless MemcachedManager.supported_protocols.include?(:meta)
      clear_tracer_cache
      @mock_tracer = MockOpenTelemetry::MockTracer.new
      @mock_provider = MockOpenTelemetry::MockTracerProvider.new(@mock_tracer)

      Object.const_set(:OpenTelemetry, Module.new) unless defined?(OpenTelemetry)
      mock_provider = @mock_provider
      OpenTelemetry.define_singleton_method(:tracer_provider) { mock_provider }

      unless defined?(OpenTelemetry::Trace::Status)
        OpenTelemetry.const_set(:Trace, Module.new)
        OpenTelemetry::Trace.const_set(:Status, MockOpenTelemetry::MockStatus)
      end
    end

    after do
      clear_tracer_cache
      Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
    end

    describe 'server.address and server.port attributes' do
      it 'splits server.address and server.port for TCP servers' do
        memcached_persistent(:meta) do |dc|
          dc.set('otel_test', 'value')

          span = @mock_tracer.spans.last

          assert_kind_of String, span.attributes['server.address']
          refute_nil span.attributes['server.port']
          assert_kind_of Integer, span.attributes['server.port']
          refute_includes span.attributes['server.address'], ':'
        end
      end

      it 'uses socket path for server.address on Unix sockets and omits server.port' do
        memcached_persistent(:meta, MemcachedMock::UNIX_SOCKET_PATH) do |dc|
          dc.set('otel_unix_test', 'value')

          span = @mock_tracer.spans.last

          assert span.attributes['server.address'].start_with?('/')
          assert_nil span.attributes['server.port']
        end
      end
    end

    describe 'db.query.text attribute' do
      it 'includes full key text when otel_db_statement is :include' do
        memcached_persistent(:meta, 21_345, '', otel_db_statement: :include) do |dc|
          dc.set('mykey', 'value')

          span = @mock_tracer.spans.last

          assert_equal 'set mykey', span.attributes['db.query.text']
        end
      end

      it 'obfuscates key when otel_db_statement is :obfuscate' do
        memcached_persistent(:meta, 21_345, '', otel_db_statement: :obfuscate) do |dc|
          dc.set('mykey', 'value')

          span = @mock_tracer.spans.last

          assert_equal 'set ?', span.attributes['db.query.text']
        end
      end

      it 'omits db.query.text by default' do
        memcached_persistent(:meta) do |dc|
          dc.set('mykey', 'value')

          span = @mock_tracer.spans.last

          assert_nil span.attributes['db.query.text']
        end
      end

      it 'includes multiple keys for set_multi with :include' do
        memcached_persistent(:meta, 21_345, '', otel_db_statement: :include) do |dc|
          dc.set_multi({ 'key1' => 'v1', 'key2' => 'v2' })

          span = @mock_tracer.spans.last
          text = span.attributes['db.query.text']

          assert_includes text, 'set_multi'
          assert_includes text, 'key1'
          assert_includes text, 'key2'
        end
      end

      it 'includes keys for get_multi with :include' do
        memcached_persistent(:meta, 21_345, '', otel_db_statement: :include) do |dc|
          dc.set('gm1', 'v1')
          dc.set('gm2', 'v2')
          @mock_tracer.spans.clear

          dc.get_multi('gm1', 'gm2')

          span = @mock_tracer.spans.first
          text = span.attributes['db.query.text']

          assert_includes text, 'get_multi'
          assert_includes text, 'gm1'
          assert_includes text, 'gm2'
        end
      end

      it 'includes keys for delete_multi with :include' do
        memcached_persistent(:meta, 21_345, '', otel_db_statement: :include) do |dc|
          dc.set('dm1', 'v1')
          dc.set('dm2', 'v2')
          @mock_tracer.spans.clear

          dc.delete_multi(%w[dm1 dm2])

          span = @mock_tracer.spans.last
          text = span.attributes['db.query.text']

          assert_includes text, 'delete_multi'
          assert_includes text, 'dm1'
          assert_includes text, 'dm2'
        end
      end
    end

    describe 'peer.service attribute' do
      it 'includes peer.service when otel_peer_service is configured' do
        memcached_persistent(:meta, 21_345, '', otel_peer_service: 'my-cache') do |dc|
          dc.set('ps_test', 'value')

          span = @mock_tracer.spans.last

          assert_equal 'my-cache', span.attributes['peer.service']
        end
      end

      it 'omits peer.service by default' do
        memcached_persistent(:meta) do |dc|
          dc.set('ps_test', 'value')

          span = @mock_tracer.spans.last

          assert_nil span.attributes['peer.service']
        end
      end
    end

    describe 'get_with_metadata includes server attributes' do
      it 'includes server.address and server.port' do
        memcached_persistent(:meta) do |dc|
          dc.set('meta_test', 'value')
          @mock_tracer.spans.clear

          dc.get_with_metadata('meta_test')

          span = @mock_tracer.spans.last

          assert_equal 'get_with_metadata', span.name
          assert_equal 'get_with_metadata', span.attributes['db.operation.name']
          refute_nil span.attributes['server.address']
          refute_nil span.attributes['server.port']
        end
      end
    end

    describe 'fetch_with_lock includes server attributes' do
      it 'includes server.address and server.port' do
        memcached_persistent(:meta) do |dc|
          @mock_tracer.spans.clear

          dc.fetch_with_lock('lock_test', ttl: 300, lock_ttl: 30) { 'computed' }

          span = @mock_tracer.spans.first

          assert_equal 'fetch_with_lock', span.name
          assert_equal 'fetch_with_lock', span.attributes['db.operation.name']
          refute_nil span.attributes['server.address']
          refute_nil span.attributes['server.port']
        end
      end
    end

    describe 'stable semantic convention attribute names' do
      it 'uses db.operation.name instead of db.operation' do
        memcached_persistent(:meta) do |dc|
          dc.get('nonexistent')

          span = @mock_tracer.spans.last

          assert_equal 'get', span.attributes['db.operation.name']
          assert_nil span.attributes['db.operation']
        end
      end

      it 'uses db.system.name instead of db.system' do
        memcached_persistent(:meta) do |dc|
          dc.get('nonexistent')

          span = @mock_tracer.spans.last

          assert_equal 'memcached', span.attributes['db.system.name']
          assert_nil span.attributes['db.system']
        end
      end
    end
  end
end
