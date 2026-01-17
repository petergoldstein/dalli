# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'benchmark'
  gem 'cgi'
  gem 'connection_pool'
  gem 'debug' unless RUBY_PLATFORM == 'java'
  gem 'minitest', '~> 6'
  gem 'minitest-mock'
  gem 'rack', '~> 3'
  gem 'rack-session'
  gem 'rake', '~> 13.0'
  gem 'rubocop'
  gem 'rubocop-minitest'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'simplecov'
end

group :test do
  gem 'ruby-prof', platform: :mri
end
