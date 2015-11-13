require './lib/dalli/version'

Gem::Specification.new do |s|
  s.name = %q{dalli}
  s.version = Dalli::VERSION
  s.license = "MIT"

  s.authors = ["Mike Perham"]
  s.description = %q{High performance memcached client for Ruby}
  s.email = %q{mperham@gmail.com}
  s.files = Dir.glob("lib/**/*") + [
     "LICENSE",
     "README.md",
     "History.md",
     "Rakefile",
     "Gemfile",
     "dalli.gemspec",
     "Performance.md",
  ]
  s.homepage = %q{http://github.com/mperham/dalli}
  s.rdoc_options = ["--charset=UTF-8"]
  s.require_paths = ["lib"]
  s.summary = %q{High performance memcached client for Ruby}
  s.test_files = Dir.glob("test/**/*")
  s.add_development_dependency 'minitest', ">= 4.2.0"
  s.add_development_dependency 'mocha', ">= 0"
  s.add_development_dependency 'rails', "~> 4"
  s.add_development_dependency 'rake'
  s.add_development_dependency 'appraisal'
  s.add_development_dependency 'connection_pool'
  s.add_development_dependency 'rdoc'
  s.add_development_dependency 'simplecov'
  s.add_development_dependency 'metric_fu'
end

