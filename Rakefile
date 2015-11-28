require 'bundler/setup'
require 'bundler/gem_tasks'
require 'appraisal'
require 'rake/testtask'

Rake::TestTask.new(:test) do |test|
  test.pattern = 'test/**/test_*.rb'
  test.warning = true
  test.verbose = true
end
task :default => :test

Rake::TestTask.new(:bench) do |test|
  test.pattern = 'test/benchmark_test.rb'
end

require 'metric_fu'

task :test_all do
  system('rake test RAILS_VERSION="~> 3.0.0"')
  system('rake test RAILS_VERSION=">= 3.0.0"')
end

# 'gem install rdoc' to upgrade RDoc if this is giving you errors
require 'rdoc/task'
RDoc::Task.new do |rd|
  rd.rdoc_files.include("lib/**/*.rb")
end

require 'rake/clean'
CLEAN.include "**/*.rbc"
CLEAN.include "**/.DS_Store"
