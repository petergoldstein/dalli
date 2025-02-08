# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'connection_pool'
  gem 'debug' unless RUBY_PLATFORM == 'java'
  gem 'minitest', '~> 5'
  gem 'rack', '~> 2.0', '>= 2.2.0'
  gem 'rake', '~> 13.0'
  gem 'rubocop'
  gem 'rubocop-minitest'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'simplecov'

  # For compatibility testing
  gem 'resolv-replace', require: false
end

group :test do
  gem 'ruby-prof', platform: :mri
end
