Dalli
=========

Dalli is a high performance pure Ruby client for accessing memcached servers.  It works with memcached 1.4+ as it uses the newer binary protocol.  The API tries to be mostly compatible with memcache-client with the goal being to make it a drop-in replacement for Rails.

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

Design
------------

I decided to write Dalli after maintaining memcache-client for the last two years for a few specific reasons:

 0. The code is mostly old and gross.  The bulk of the code is a single 1000 line .rb file.
 1. It has a lot of options that are infrequently used which complicate the codebase.
 2. The implementation has no single point to attach monitoring hooks.
 3. Uses the old text protocol, which hurts raw performance.

So a few notes.  Dalli:

 0. uses the exact same algorithm to choose a server so existing memcached clusters with TBs of data will work identically to memcache-client.
 1. is approximately 2x faster than memcache-client (which itself was heavily optimized) simply due to the decrease in code and use of the new binary protocol.
 2. contains explicit "chokepoint" methods which handle all requests; these can be hooked into by monitoring tools (NewRelic, Rack::Bug, etc) to track memcached usage.
 3. comes with hooks to replace memcache-client in Rails.

Installation and Usage
------------------------

    gem install dalli

    require 'dalli'
    dc = Dalli::Client.new('localhost:11211')
    dc.set('abc', 123)
    value = dc.get('abc')

Usage with Rails
---------------------------

In your Gemfile:

    gem 'dalli'

In `config/environments/production.rb`:

    config.cache_store = :dalli_store, 'localhost:11211'


Features and Changes
------------------------

memcache-client allowed developers to store either raw or marshalled values with each API call.  I feel this is needless complexity; Dalli allows you to control marshalling per-Client with the `:marshal => false` flag but you cannot explicitly set the raw flag for each API call.  By default, marshalling is enabled.

ActiveSupport::Cache implements several esoteric features so there is no need for Dalli to reinvent them.  Specifically, key namespaces and automatic pruning of keys longer than 250 characters.

By default, Dalli is thread-safe.  Disable thread-safety at your own peril.


Author
----------

Mike Perham, mperham@gmail.com, [mikeperham.com](http://mikeperham.com), [@mperham](http://twitter.com/mperham)


Copyright
-----------

Copyright (c) 2010 Mike Perham. See LICENSE for details.
