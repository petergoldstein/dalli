require './lib/dalli/version'

Gem::Specification.new do |s|
  s.name = "dalli"
  s.version = Dalli::VERSION
  s.license = "MIT"

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
  s.rdoc_options = ["--charset=UTF-8"]
  s.add_development_dependency 'minitest', '>= 4.2.0'
  s.add_development_dependency 'mocha'
  s.add_development_dependency 'rails', '~> 5'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'appraisal'
  s.add_development_dependency 'connection_pool'
  s.add_development_dependency 'rdoc'
  s.add_development_dependency 'simplecov'
end

