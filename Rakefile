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
