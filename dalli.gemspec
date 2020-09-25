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
end

