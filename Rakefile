require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'test'
  test.pattern = 'test/**/test_*.rb'
end

Rake::TestTask.new(:bench) do |test|
  test.libs << 'test'
  test.pattern = 'test/benchmark_test.rb'
end

task :default => :test