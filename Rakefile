require 'appraisal'
require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.warning = true
  test.verbose = true
end

Rake::TestTask.new(:bench) do |test|
  test.libs << 'test'
  test.pattern = 'test/benchmark_test.rb'
end

begin
  require 'metric_fu'
  MetricFu::Configuration.run do |config|
    config.rcov[:rcov_opts] << "-Itest:lib"
  end
rescue LoadError
end

task :default => :test

task :test_all do
  system('rake test RAILS_VERSION="~> 3.0.0"')
  system('rake test RAILS_VERSION=">= 3.0.0"')
end

# 'gem install rdoc' to upgrade RDoc if this is giving you errors
begin
  require 'rdoc/task'
  RDoc::Task.new do |rd|
    rd.rdoc_files.include("lib/**/*.rb")
  end
rescue LoadError
  puts "Unable to load rdoc, run 'gem install rdoc' to fix this."
end

require 'rake/clean'
CLEAN.include "**/*.rbc"
CLEAN.include "**/.DS_Store"
