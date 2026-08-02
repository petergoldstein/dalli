# frozen_string_literal: true

# Turns warnings into test failures, but only for warnings that originate in
# Dalli's own code.  `Warning.singleton_class.prepend` is global, so without this
# scoping a warning emitted while loading any third-party gem aborts the entire
# suite before a single test runs.  That is not hypothetical: json 2.21.2's
# pure-Ruby generator (used on JRuby, where the C extension is unavailable) warns
# 'method redefined; discarding old to_hash' at require time, which took CI red
# with no change to Dalli.
module StrictWarnings
  ROOT = File.expand_path('../..', __dir__)
  # Only lib/ and test/ are ours.  Bundler installs gems under vendor/ in CI, so
  # allowlisting the repository root would not be enough.
  OWN_SOURCE_PREFIXES = [File.join(ROOT, 'lib', ''), File.join(ROOT, 'test', '')].freeze

  # Ruby prefixes interpreter-generated warnings with the location of the offending
  # code: "path/to/file.rb:12: warning: ...".
  MESSAGE_ORIGIN = /\A(.+?):\d+: warning:/

  # RubyGems Kernel#warn shim, active on JRuby but not CRuby.
  RUBYGEMS_WARN_SHIM = 'rubygems/core_ext/kernel_warn.rb'

  def warn(msg, **, &)
    # Allow intentional deprecation warnings from Dalli
    return super if msg.to_s.start_with?('[DEPRECATION]')
    return super unless dalli_source?(msg)

    raise RuntimeError, msg, caller(1)
  end

  private

  # Attribution comes from the message itself when Ruby provides it, because the
  # call stack at that point describes the require chain rather than the code that
  # triggered the warning -- for a warning raised while loading a gem, the stack
  # bottoms out in whichever test file happened to require it.  Only warnings with
  # no embedded location (Kernel#warn calls, e.g. lib/rack/session/dalli.rb) fall
  # back to the caller.  A warning we cannot attribute is passed through rather
  # than raised.
  def dalli_source?(msg)
    location = msg.to_s[MESSAGE_ORIGIN, 1] || warn_origin_from_stack
    return false unless location

    own_source?(location)
  end

  # Resolved against ROOT because the location is not always absolute: rake passes
  # test files to the loader as relative paths, and JRuby reports them that way in
  # backtraces (CRuby fills in absolute_path, JRuby leaves it nil).  Expanding an
  # already-absolute path is a no-op, so this is safe for both.
  def own_source?(location)
    expanded = File.expand_path(location, ROOT)

    OWN_SOURCE_PREFIXES.any? { |prefix| expanded.start_with?(prefix) }
  end

  # Walks the stack rather than indexing it at a fixed depth: Ruby 3.3 and 3.4 push
  # an `<internal:warning>` frame for Kernel#warn that 4.0 does not, so any fixed
  # offset is correct on one version and wrong on another.  Skips the warning
  # machinery, then takes the first real caller.
  def warn_origin_from_stack
    caller_locations(1)&.each do |frame|
      path = frame.absolute_path || frame.path
      next if warn_machinery_frame?(path)

      return path
    end
    nil
  end

  # Frames that sit between the code which called Kernel#warn and this hook, and so
  # must not be mistaken for the origin: this file, interpreter-internal frames
  # (`<internal:warning>`), and RubyGems' Kernel#warn shim.  That shim is active on
  # JRuby but not CRuby, which is why a scan that stopped at the first non-internal
  # frame attributed every Kernel#warn to RubyGems there and to the real caller here.
  def warn_machinery_frame?(path)
    return true if path.nil?

    path.start_with?('<') || path == __FILE__ || path.end_with?(RUBYGEMS_WARN_SHIM)
  end
end

Warning.singleton_class.prepend(StrictWarnings)
