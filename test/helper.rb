require 'rubygems'
require 'ginger'
# require 'simplecov-html'
# SimpleCov.start

require 'test/unit'
require 'shoulda'
require 'memcached_mock'
require 'mocha'

require 'dalli'

class Test::Unit::TestCase
  include MemcachedMock::Helper

  def assert_error(error, regexp=nil, &block)
    ex = assert_raise(error, &block)
    assert_match(regexp, ex.message, "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join("\n\t")}")
  end

  def with_activesupport(*versions)
    versions.each do |version|
      begin
        pid = fork do
          begin
            trap("TERM") { exit }
            gem 'activesupport', "~> #{version}"
            case version
            when '3.0.0'
              require 'active_support/all'
            when '2.3.0'
              require 'active_support'
              require 'active_support/cache/dalli_store23'
            end
            yield
          rescue Gem::LoadError
            puts "Skipping activesupport #{version} test: #{$!.message}"
          end
        end
      ensure
        Process.wait(pid)
      end
    end
  end

  def with_actionpack(*versions)
    versions.each do |version|
      begin
        pid = fork do
          begin
            trap("TERM") { exit }
            gem 'actionpack', "~> #{version}"
            case version
            when '3.0.0'
              require 'action_dispatch'
              require 'action_controller'
            when '2.3.0'
              raise NotImplementedError
            end
            yield
          rescue Gem::LoadError
            puts "Skipping actionpack #{version} test: #{$!.message}"
          end
        end
      ensure
        Process.wait(pid)
      end
    end
  end

end