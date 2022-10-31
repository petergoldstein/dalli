# frozen_string_literal: true

require_relative '../helper'
require 'json'

describe 'memcached admin commands' do
  MemcachedManager.supported_protocols.each do |p|
    describe "using the #{p} protocol" do
      describe 'stats' do
        it 'support stats' do
          memcached_persistent(p) do |dc|
            # make sure that get_hits would not equal 0
            dc.set(:a, '1234567890' * 100_000)
            dc.get(:a)

            stats = dc.stats
            servers = stats.keys

            assert(servers.any? do |s|
              stats[s]['get_hits'].to_i != 0
            end, 'general stats failed')

            stats_items = dc.stats(:items)
            servers = stats_items.keys

            assert(servers.all? do |s|
              stats_items[s].keys.any? do |key|
                key =~ /items:[0-9]+:number/
              end
            end, 'stats items failed')

            stats_slabs = dc.stats(:slabs)
            servers = stats_slabs.keys

            assert(servers.all? do |s|
              stats_slabs[s].keys.any?('active_slabs')
            end, 'stats slabs failed')

            # reset_stats test
            results = dc.reset_stats

            assert(results.all? { |x| x })
            stats = dc.stats
            servers = stats.keys

            # check if reset was performed
            servers.each do |s|
              assert_equal 0, dc.stats[s]['get_hits'].to_i
            end
          end
        end
      end

      describe 'version' do
        it 'support version operation' do
          memcached_persistent(p) do |dc|
            v = dc.version
            servers = v.keys

            assert(servers.any? do |s|
              !v[s].nil?
            end, 'version failed')
          end
        end
      end
    end
  end
end
