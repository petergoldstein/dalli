# frozen_string_literal: true

require_relative 'helper'
require 'tmpdir'
require 'fileutils'

describe StrictWarnings do
  # Warnings emitted while loading a gem must not abort the suite.  json 2.21.2's
  # pure-Ruby generator produces exactly this warning on JRuby at require time.
  it 'ignores an interpreter warning originating in a gem' do
    msg = '/app/vendor/bundle/ruby/3.4.0/gems/json-2.21.2/lib/json/ext/generator/state.rb:73: ' \
          "warning: method redefined; discarding old to_hash\n"

    _, err = capture_subprocess_io { Warning.warn(msg) }

    assert_equal msg, err
  end

  it 'raises for an interpreter warning originating in lib/' do
    msg = "#{File.expand_path('../lib/dalli/client.rb', __dir__)}:42: warning: assigned but unused variable\n"

    error = assert_raises(RuntimeError) { Warning.warn(msg) }

    assert_equal msg, error.message
  end

  it 'raises for an interpreter warning originating in test/' do
    msg = "#{File.expand_path('some_test.rb', __dir__)}:42: warning: shadowing outer local variable\n"

    assert_raises(RuntimeError) { Warning.warn(msg) }
  end

  # Kernel#warn produces no embedded location, so attribution falls back to the
  # caller -- this file, which is ours.  lib/rack/session/dalli.rb relies on this.
  it 'raises for a Kernel#warn call from Dalli code' do
    assert_raises(RuntimeError) { warn 'no location prefix' }
  end

  # RubyGems installs a Kernel#warn shim that is active on JRuby but not CRuby, so on
  # JRuby it sits between the caller and this hook.  Treating it as the origin
  # attributed every Kernel#warn to RubyGems and silently disabled the fallback.
  describe 'warning machinery frames' do
    it 'skips RubyGems Kernel#warn shim frames' do
      assert Warning.send(:warn_machinery_frame?,
                          '/opt/jruby-10.1.1.0/lib/ruby/stdlib/rubygems/core_ext/kernel_warn.rb')
    end

    it 'skips interpreter-internal frames' do
      assert Warning.send(:warn_machinery_frame?, '<internal:warning>')
    end

    it 'skips frames from the hook itself' do
      assert Warning.send(:warn_machinery_frame?, File.expand_path('support/strict_warnings.rb', __dir__))
    end

    it 'does not skip ordinary caller frames' do
      refute Warning.send(:warn_machinery_frame?, File.expand_path('../lib/rack/session/dalli.rb', __dir__))
    end

    # Reproduces JRuby's stack topology on any Ruby: a Kernel#warn call routed
    # through a file at RubyGems' shim path must still be attributed to the caller
    # below it.  Without the shim skip this passes the warning through instead.
    it 'attributes through a shim frame to the real caller' do
      dir = Dir.mktmpdir
      shim_dir = File.join(dir, 'rubygems', 'core_ext')
      FileUtils.mkdir_p(shim_dir)
      File.write(File.join(shim_dir, 'kernel_warn.rb'), "def warn_via_shim(msg)\n  warn(msg)\nend\n")
      require File.join(shim_dir, 'kernel_warn.rb')

      assert_raises(RuntimeError) { warn_via_shim('routed through the shim') }
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end

  it 'passes through intentional deprecation warnings' do
    _, err = capture_subprocess_io { Warning.warn("[DEPRECATION] this is intentional\n") }

    assert_equal "[DEPRECATION] this is intentional\n", err
  end

  # Backtrace paths are not always absolute.  Rake hands test files to the loader
  # as relative paths and JRuby reports them that way (CRuby fills in
  # absolute_path, JRuby leaves it nil), so attribution must resolve them.
  describe 'source attribution' do
    it 'recognizes a relative path under test/ as ours' do
      assert Warning.send(:own_source?, 'test/test_strict_warnings.rb')
    end

    it 'recognizes a relative path under lib/ as ours' do
      assert Warning.send(:own_source?, 'lib/dalli/client.rb')
    end

    it 'recognizes an absolute path under lib/ as ours' do
      assert Warning.send(:own_source?, File.expand_path('../lib/dalli/client.rb', __dir__))
    end

    it 'does not claim a relative path outside the repository' do
      refute Warning.send(:own_source?, '../elsewhere/lib/thing.rb')
    end

    it 'does not claim a gem path' do
      refute Warning.send(:own_source?, '/app/vendor/bundle/gems/json-2.21.2/lib/json/ext/generator/state.rb')
    end
  end

  it 'does not treat a path merely containing the repo name as ours' do
    msg = "/somewhere/else/dalli-mimic/lib/thing.rb:1: warning: nope\n"

    _, err = capture_subprocess_io { Warning.warn(msg) }

    assert_equal msg, err
  end
end
