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
    'History.md',
    'Gemfile'
  ]
  s.homepage = 'https://github.com/petergoldstein/dalli'
  s.required_ruby_version = '>= 2.5'

  s.add_development_dependency 'connection_pool'
  s.add_development_dependency 'rack', '~> 2.0', '>= 2.2.0'
  s.add_development_dependency 'rubocop'
  s.add_development_dependency 'rubocop-minitest'
  s.add_development_dependency 'rubocop-performance'
  s.add_development_dependency 'rubocop-rake'
  s.metadata = {
    'rubygems_mfa_required' => 'true'
  }
end
