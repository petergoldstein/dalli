#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the CHANGELOG section for a single version, for use as GitHub release
# notes.  Exits non-zero with a message on stderr if the version has no section,
# so a release workflow fails loudly rather than publishing empty notes.
#
#   ruby scripts/changelog_section.rb 5.0.6
#
# Sections are setext headings: a title line followed by a line of '=' characters.
# The section runs until the next heading of any kind.

CHANGELOG = File.expand_path('../CHANGELOG.md', __dir__)

def heading_at?(lines, index)
  underline = lines[index + 1]
  return false if underline.nil?

  !lines[index].empty? && underline.match?(/\A=+\z/)
end

def section_for(lines, version)
  start = (0...lines.size).find { |i| lines[i] == version && heading_at?(lines, i) }
  return nil unless start

  body_start = start + 2
  body_end = ((body_start + 1)...lines.size).find { |i| heading_at?(lines, i) } || lines.size

  lines[body_start...body_end]
end

version = ARGV[0].to_s.strip
abort 'usage: changelog_section.rb VERSION' if version.empty?

lines = File.readlines(CHANGELOG, chomp: true)
section = section_for(lines, version)
abort "No CHANGELOG section found for version #{version}" if section.nil?

# Trailing blank lines separate this section from the next heading; leading ones
# are an artifact of the heading underline.
body = section.join("\n").strip
abort "CHANGELOG section for version #{version} is empty" if body.empty?

puts body
