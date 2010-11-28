Dalli
=========

Dalli is a high performance pure Ruby client for accessing memcached servers.  It works with memcached 1.4+ only as it uses the newer binary protocol.  It should be considered a replacement for the memcache-client gem.  The API tries to be mostly compatible with memcache-client with the goal being to make it a drop-in replacement for Rails.

The name is a variant of Salvador Dali for his famous painting [The Persistence of Memory](http://en.wikipedia.org/wiki/The_Persistence_of_Memory).

![Persistence of Memory](http://www.virtualdali.com/assets/paintings/31PersistenceOfMemory.jpg)

Dalli's development is sponsored by [Membase](http://www.membase.com/).  Many thanks to them!


Design
------------

I decided to write Dalli after maintaining memcache-client for the last two years for a few specific reasons:

 0. The code is mostly old and gross.  The bulk of the code is a single 1000 line .rb file.
 1. It has a lot of options that are infrequently used which complicate the codebase.
 2. The implementation has no single point to attach monitoring hooks.
 3. Uses the old text protocol, which hurts raw performance.

So a few notes.  Dalli:

 0. uses the exact same algorithm to choose a server so existing memcached clusters with TBs of data will work identically to memcache-client.
 1. is approximately 20% faster than memcache-client (which itself was heavily optimized) in Ruby 1.9.2.
 2. contains explicit "chokepoint" methods which handle all requests; these can be hooked into by monitoring tools (NewRelic, Rack::Bug, etc) to track memcached usage.
 3. comes with hooks to replace memcache-client in Rails.
 4. is approx 700 lines of Ruby.  memcache-client is approx 1250 lines.
 5. supports SASL for use in managed environments, e.g. Heroku.
 6. provides proper failover with recovery and adjustable timeouts


Installation and Usage
------------------------

Remember, Dalli **requires** memcached 1.4+.  You can check the version with `memcached -h`.

    gem install dalli

    require 'dalli'
    dc = Dalli::Client.new('localhost:11211')
    dc.set('abc', 123)
    value = dc.get('abc')

The test suite requires memcached 1.4.3+ with SASL enabled (./configure --enable-sasl).  Currently only supports the PLAIN mechanism.

Dalli has no runtime dependencies and never will.  You can optionally install the 'kgio' gem to
give Dalli a 10-20% performance boost.


Usage with Rails 3.0
---------------------------

In your Gemfile:

    gem 'dalli'

In `config/environments/production.rb`:

    config.cache_store = :dalli_store

A more comprehensive example (note that we are setting a reasonable default for maximum cache entry lifetime (one day), enabling compression for large values, and namespacing all entries for this rails app.  Remove the namespace if you have multiple apps which share cached values):

    config.cache_store = :dalli_store, 'cache-1.example.com', 'cache-2.example.com',
        { :namespace => NAME_OF_RAILS_APP, :expires_in => 1.day, :compress => true, :compress_threshold => 64*1024 }

To use Dalli for Rails session storage, in `config/initializers/session_store.rb`:

    require 'action_dispatch/middleware/session/dalli_store'
    Rails.application.config.session_store :dalli_store, :memcache_server => ['host1', 'host2'], :namespace => 'sessions', :key => '_foundation_session', :expire_after => 30.minutes


Usage with Rails 2.3.x
----------------------------

In `config/environment.rb`:

    config.gem 'dalli'

In `config/environments/production.rb`:

    # Object cache
    require 'active_support/cache/dalli_store23'
    config.cache_store = :dalli_store

In `config/initializers/session_store.rb`:

    # Session cache
    ActionController::Base.session = {
      :namespace   => 'sessions',
      :expire_after => 20.minutes.to_i,
      :memcache_server => ['server-1:11211', 'server-2:11211'],
      :key         => ...,
      :secret      => ...
    }
    
    require 'action_controller/session/dalli_store'
    ActionController::Base.session_store = :dalli_store


Usage with Passenger
------------------------

Put this at the bottom of `config/environment.rb`:

    if defined?(PhusionPassenger)
      PhusionPassenger.on_event(:starting_worker_process) do |forked|
        # Only works with DalliStore
        Rails.cache.reset if forked
      end
    end


Configuration
------------------------
Dalli::Client accepts the following options. All times are in seconds.

**expires_in**: Global default for key TTL.  No default.

**failover**: Boolean, if true Dalli will failover to another server if the main server for a key is down.

**compression**: Boolean, if true Dalli will gzip-compress values larger than 1K.

**socket_timeout**: Timeout for all socket operations (connect, read, write). Default is 0.5.

**socket_max_failures**: When a socket operation fails after socket_timeout, the same operation is retried. This is to not immediately mark a server down when there's a very slight network problem. Default is 2.

**socket_failure_delay**: Before retrying a socket operation, the process sleeps for this amount of time. Default is 0.01.  Set to nil for no delay.

**down_retry_delay**: When a server has been marked down due to many failures, the server will be checked again for being alive only after this amount of time. Don't set this value to low, otherwise each request which tries the failed server might hang for the maximum timeout (see below). Default is 1 second.


Features and Changes
------------------------

Dalli is **NOT** 100% API compatible with memcache-client.  If you have code which uses the MemCache API directly, it will likely need small tweaks.  Method parameters and return values changed slightly.  See Upgrade.md for more detail.

By default, Dalli is thread-safe.  Disable thread-safety at your own peril.

Note that Dalli does not require ActiveSupport or Rails.  You can safely use it in your own Ruby projects.


Helping Out
-------------

If you have a fix you wish to provide, please fork the code, fix in your local project and then send a pull request on github.  Please ensure that you include a test which verifies your fix and update History.md with a one sentence description of your fix so you get credit as a contributor.


Thanks
------------

Eric Wong - for help using his [kgio](http://unicorn.bogomips.org/kgio/index.html) library.

Brian Mitchell - for his remix-stash project which was helpful when implementing and testing the binary protocol support.

[Membase](http://membase.com) - for their project sponsorship

[Bootspring](http://bootspring.com) is my Ruby and Rails consulting company.  We specialize in Ruby infrastructure, performance and scalability tuning for Rails applications.  If you need help, please [contact us](mailto:info@bootspring.com) today.


Author
----------

Mike Perham, mperham@gmail.com, [mikeperham.com](http://mikeperham.com), [@mperham](http://twitter.com/mperham)  If you like and use this project, please give me a recommendation at [WWR](http://workingwithrails.com/person/10797-mike-perham).  Happy caching!


Copyright
-----------

Copyright (c) 2010 Mike Perham. See LICENSE for details.
