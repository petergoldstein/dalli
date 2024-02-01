# frozen_string_literal: true

require './lib/dalli/version'

Gem::Specification.new do |s|
  s.name = 'dalli'
  s.version = Dalli::VERSION
  s.license = 'MIT'

  s.authors = ['Peter M. Goldstein', 'Mike Perham']
  s.description = s.summary = 'High performance memcached client for Ruby'
  s.email = ['peter.m.goldstein@gmail.com', 'mperham@gmail.com']
  s.files = Dir.glob('lib/**/*') + [
    'LICENSE',
    'README.md',
    'CHANGELOG.md',
    'Gemfile'
  ]
  s.homepage = 'https://github.com/petergoldstein/dalli'
  s.required_ruby_version = '>= 2.6'

  s.metadata = {
    'rubygems_mfa_required' => 'true'
  }
end
