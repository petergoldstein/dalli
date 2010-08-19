dalli
=========

Dalli is a high performance pure Ruby client for accessing memcached servers.  It works with memcached 1.4+ as it uses the newer binary protocol.  The API tries to be mostly compatible with memcache-client with the goal being to make it a drop-in replacement for Rails.

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

Design
------------

I decided to write Dalli after maintaining memcache-client for the last two years for a few specific reasons:

 1. The code is mostly old and gross.  The bulk of the code is a single 1000 line .rb file.
 2. It has a lot of options that are infrequently used which complicate the codebase.
 3. The implementation has no single point to attach monitoring hooks.

So a few notes:

 0. Dalli uses the exact same algorithm to choose a server so existing memcached clusters with TBs of data will work identically to memcache-client.
 1. Dalli does not support multiple namespaces or any of the more esoteric features in MemCache.
 2. Dalli is approximately 2x faster than memcache-client (which itself was heavily optimized) simply due to the decrease in code and use of the new binary protocol.
 3. There are explicit "chokepoint" methods which handle all requests; these can be hooked into by monitoring tools (NewRelic, Rack::Bug, etc) to track memcached usage.
 4. Dalli comes with hooks to replace memcache-client in Rails 3.0.
 5. I'm not supporting Rails 2.x or Ruby 1.8.  I'm not explicitly disallowing them but I don't test with them.  memcache-client is stable and works - use it for existing applications.  Use Dalli with your new applications.

Installation and Usage
------------------------

    gem install dalli

    require 'dalli'
    dc = Dalli::Client.new('localhost:11211')
    dc.set('abc', 123)
    value = dc.get('abc')

Installation with Rails
---------------------------

In your Gemfile:

    gem 'dalli'

In `config/environments/production.rb`:

    config.cache_store = :dalli_store, 'localhost:11211'


Author
----------

Mike Perham, mperham@gmail.com, [mikeperham.com](http://mikeperham.com), [@mperham](http://twitter.com/mperham)


Copyright
-----------

Copyright (c) 2010 Mike Perham. See LICENSE for details.
