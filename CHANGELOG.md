Dalli Changelog
=====================

Unreleased
==========

- Fix cannot read response data included terminator `\r\n` when use meta protocol (matsubara0507)
- Support SERVER_ERROR response from Memcached as per the [memcached spec](https://github.com/memcached/memcached/blob/e43364402195c8e822bb8f88755a60ab8bbed62a/doc/protocol.txt#L172) (grcooper)
- Update Socket timeout handling to use Socket#timeout= when available (nickamorim)
- Remove Socket#readfull and replace with standard read method (grcooper)

3.2.8
==========

- Handle IO::TimeoutError when establishing connection (eugeneius)
- Drop dependency on base64 gem (Earlopain)
- Address incompatibility with resolv-replace (y9v)
- Add rubygems.org metadata (m-nakamura145)

3.2.7
==========

- Fix cascading error when there's an underlying network error in a pipelined get (eugeneius)
- Ruby 3.4/head compatibility by adding base64 to gemspec (tagliala)
- Add Ruby 3.3 to CI (m-nakamura145)
- Use Socket's connect_timeout when available, and pass timeout to the socket's send and receive timeouts (mlarraz)

3.2.6
==========

- Rescue IO::TimeoutError raised by Ruby since 3.2.0 on blocking reads/writes (skaes)
- Fix rubydoc link (JuanitoFatas)

3.2.5
==========

- Better handle memcached requests being interrupted by Thread#raise or Thread#kill (byroot)
- Unexpected errors are no longer treated as `Dalli::NetworkError`, including errors raised by `Timeout.timeout` (byroot)

3.2.4
==========

- Cache PID calls for performance since glibc no longer caches in recent versions (byroot)
- Preallocate the read buffer in Socket#readfull (byroot)

3.2.3
==========

- Sanitize CAS inputs to ensure additional commands are not passed to memcached (xhzeem / petergoldstein)
- Sanitize input to flush command to ensure additional commands are not passed to memcached (xhzeem / petergoldstein)
- Namespaces passed as procs are now evaluated every time, as opposed to just on initialization (nrw505)
- Fix missing require of uri in ServerConfigParser (adam12)
- Fix link to the CHANGELOG.md file in README.md (rud)

3.2.2
==========

- Ensure apps are resilient against old session ids (kbrock)

3.2.1
==========

- Fix null replacement bug on some SASL-authenticated services (veritas1)

3.2.0
==========

- BREAKING CHANGE: Remove protocol_implementation client option (petergoldstein)
- Add protocol option with meta implementation (petergoldstein)

3.1.6
==========

- Fix bug with cas/cas! with "Not found" value (petergoldstein)
- Add Ruby 3.1 to CI (petergoldstein)
- Replace reject(&:nil?) with compact (petergoldstein)

3.1.5
==========

- Fix bug with get_cas key with "Not found" value (petergoldstein)
- Replace should return nil, not raise error, on miss (petergoldstein)

3.1.4
==========

- Improve response parsing performance (byroot)
- Reorganize binary protocol parsing a bit (petergoldstein)
- Fix handling of non-ASCII keys in get_multi (petergoldstein)

3.1.3
==========

- Restore falsey behavior on delete/delete_cas for nonexistent key (petergoldstein)

3.1.2
==========

- Make quiet? / multi? public on Dalli::Protocol::Binary (petergoldstein)

3.1.1
==========

- Add quiet support for incr, decr, append, depend, and flush (petergoldstein)
- Additional refactoring to allow reuse of connection behavior (petergoldstein)
- Fix issue in flush such that it wasn't passing the delay argument to memcached (petergoldstein)

3.1.0
==========

- BREAKING CHANGE: Update Rack::Session::Dalli to inherit from Abstract::PersistedSecure.  This will invalidate existing sessions (petergoldstein)
- BREAKING CHANGE: Use of unsupported operations in a multi block now raise an error. (petergoldstein)
- Extract PipelinedGetter from Dalli::Client (petergoldstein)
- Fix SSL socket so that it works with pipelined gets (petergoldstein)
- Additional refactoring to split classes (petergoldstein)

3.0.6
==========

- Fix regression in SASL authentication response parsing (petergoldstein)

3.0.5
==========

- Add Rubocop and fix most outstanding issues (petergoldstein)
- Extract a number of classes, to simplify the largest classes (petergoldstein)
- Ensure against socket corruption if an error occurs in a multi block (petergoldstein)

3.0.4
==========

- Clean connections and retry after NetworkError in get_multi (andrejbl)
- Internal refactoring and cleanup (petergoldstein)

3.0.3
==========

- Restore ability for `compress` to be disabled on a per request basis (petergoldstein)
- Fix broken image in README (deining)
- Use bundler-cache in CI (olleolleolle)
- Remove the OpenSSL extensions dependency (petergoldstein)
- Add Memcached 1.5.x to the CI matrix
- Updated compression documentation (petergoldstein)

3.0.2
==========

- Restore Windows compatibility (petergoldstein)
- Add JRuby to CI and make requisite changes (petergoldstein)
- Clarify documentation for supported rubies (petergoldstein)

3.0.1
==========

- Fix syntax error that prevented inclusion of Dalli::Server (ryanfb)
- Restore with method required by ActiveSupport::Cache::MemCacheStore

3.0.0
==========
- BREAKING CHANGES:

  * Removes :dalli_store.
    Use Rails' official :mem_cache_store instead.
    https://guides.rubyonrails.org/caching_with_rails.html
  * Attempting to store a larger value than allowed by memcached used to
    print a warning and truncate the value. This now raises an error to
    prevent silent data corruption.
  * Compression now defaults to `true` for large values (greater than 4KB).
    This is intended to minimize errors due to the previous note.
  * Errors marshalling values now raise rather than just printing an error.
  * The Rack session adapter has been refactored to remove support for thread-unsafe
    configurations. You will need to include the `connection_pool` gem in
    your Gemfile to ensure session operations are thread-safe.
  * When using namespaces, the algorithm for calculating truncated keys was
    changed.  Non-truncated keys and truncated keys for the non-namespace
    case were left unchanged.

- Raise NetworkError when multi response gets into corrupt state (mervync, #783)
- Validate servers argument (semaperepelitsa, petergoldstein, #776)
- Enable SSL support (bdunne, #775)
- Add gat operation (tbeauvais, #769)
- Removes inline native code, use Ruby 2.3+ support for bsearch instead. (mperham)
- Switch repo to Github Actions and upgrade Ruby versions (petergoldstein, bdunne, Fryguy)
- Update benchmark test for Rubyprof changes (nateberkopec)
- Remove support for the `kgio` gem, it is not relevant in Ruby 2.3+. (mperham)
- Remove inline native code, use Ruby 2.3+ support for bsearch instead. (mperham)


2.7.11
==========
- DEPRECATION: :dalli_store will be removed in Dalli 3.0.
  Use Rails' official :mem_cache_store instead.
  https://guides.rubyonrails.org/caching_with_rails.html
- Add new `digest_class` option to Dalli::Client [#724]
- Don't treat NameError as a network error [#728]
- Handle nested comma separated server strings (sambostock)

2.7.10
==========
- Revert frozen string change (schneems)
- Advertise supports_cached_versioning? in DalliStore (schneems)
- Better detection of fork support, to allow specs to run under Truffle Ruby (deepj)
- Update logging for over max size to log as error (aeroastro)

2.7.9
==========
- Fix behavior for Rails 5.2+ cache_versioning (GriwMF)
- Ensure fetch provides the key to the fallback block as an argument (0exp)
- Assorted performance improvements (schneems)

2.7.8
==========
- Rails 5.2 compatibility (pbougie)
- Fix Session Cache compatibility (pixeltrix)

2.7.7
==========
- Support large cache keys on fetch multi (sobrinho)
- Not found checks no longer trigger the result's equality method (dannyfallon)
- Use SVG build badges (olleolleolle)
- Travis updates (junaruga, tiarly, petergoldstein)
- Update default down_retry_delay (jaredhales)
- Close kgio socket after IO.select timeouts
- Documentation updates (tipair)
- Instrument DalliStore errors with instrument_errors configuration option. (btatnall)

2.7.6
==========
- Rails 5.0.0.beta2 compatibility (yui-knk, petergoldstein)
- Add cas!, a variant of the #cas method that yields to the block whether or not the key already exist (mwpastore)
- Performance improvements (nateberkopec)
- Add Ruby 2.3.0 to support matrix (tricknotes)

2.7.5
==========

- Support rcvbuff and sndbuff byte configuration. (btatnall)
- Add `:cache_nils` option to support nil values in `DalliStore#fetch` and `Dalli::Client#fetch` (wjordan, #559)
- Log retryable server errors with 'warn' instead of 'info' (phrinx)
- Fix timeout issue with Dalli::Client#get_multi_yielder (dspeterson)
- Escape namespaces with special regexp characters (Steven Peckins)
- Ensure LocalCache supports the `:raw` option and Entry unwrapping (sj26)
- Ensure bad ttl values don't cause Dalli::RingError (eagletmt, petergoldstein)
- Always pass namespaced key to instrumentation API (kaorimatz)
- Replace use of deprecated TimeoutError with Timeout::Error (eagletmt)
- Clean up gemspec, and use Bundler for loading (grosser)
- Dry up local cache testing (grosser)

2.7.4
==========

- Restore Windows compatibility (dfens, #524)

2.7.3
==========

- Assorted spec improvements
- README changes to specify defaults for failover and compress options (keen99, #470)
- SASL authentication changes to deal with Unicode characters (flypiggy, #477)
- Call to_i on ttl to accomodate ActiveSupport::Duration (#494)
- Change to implicit blocks for performance (glaucocustodio, #495)
- Change to each_key for performance (jastix, #496)
- Support stats settings - (dterei, #500)
- Raise DallError if hostname canno be parsed (dannyfallon, #501)
- Fix instrumentation for falsey values (AlexRiedler, #514)
- Support UNIX socket configurations (r-stu31, #515)

2.7.2
==========

- The fix for #423 didn't make it into the released 2.7.1 gem somehow.

2.7.1
==========

- Rack session will check if servers are up on initialization (arthurnn, #423)
- Add support for IPv6 addresses in hex form, ie: "[::1]:11211" (dplummer, #428)
- Add symbol support for namespace (jingkai #431)
- Support expiration intervals longer than 30 days (leonid-shevtsov #436)

2.7.0
==========

- BREAKING CHANGE:
  Dalli::Client#add and #replace now return a truthy value, not boolean true or false.
- Multithreading support with dalli\_store:
  Use :pool\_size to create a pool of shared, threadsafe Dalli clients in Rails:
```ruby
    config.cache_store = :dalli_store, "cache-1.example.com", "cache-2.example.com", :compress => true, :pool_size => 5, :expires_in => 300
```
  This will ensure the Rails.cache singleton does not become a source of contention.
  **PLEASE NOTE** Rails's :mem\_cache\_store does not support pooling as of
Rails 4.0.  You must use :dalli\_store.

- Implement `version` for retrieving version of connected servers [dterei, #384]
- Implement `fetch_multi` for batched read/write [sorentwo, #380]
- Add more support for safe updates with multiple writers: [philipmw, #395]
  `require 'dalli/cas/client'` augments Dalli::Client with the following methods:
  * Get value with CAS:            `[value, cas] = get_cas(key)`
                                   `get_cas(key) {|value, cas| ...}`
  * Get multiple values with CAS:  `get_multi_cas(k1, k2, ...) {|value, metadata| cas = metadata[:cas]}`
  * Set value with CAS:            `new_cas = set_cas(key, value, cas, ttl, options)`
  * Replace value with CAS:        `replace_cas(key, new_value, cas, ttl, options)`
  * Delete value with CAS:         `delete_cas(key, cas)`
- Fix bug with get key with "Not found" value [uzzz, #375]

2.6.4
=======

- Fix ADD command, aka `write(unless_exist: true)` (pitr, #365)
- Upgrade test suite from mini\_shoulda to minitest.
- Even more performance improvements for get\_multi (xaop, #331)

2.6.3
=======

- Support specific stats by passing `:items` or `:slabs` to `stats` method [bukhamseen]
- Fix 'can't modify frozen String' errors in `ActiveSupport::Cache::DalliStore` [dblock]
- Protect against objects with custom equality checking [theron17]
- Warn if value for key is too large to store [locriani]

2.6.2
=======

- Properly handle missing RubyInline

2.6.1
=======

- Add optional native C binary search for ring, add:

gem 'RubyInline'

  to your Gemfile to get a 10% speedup when using many servers.
  You will see no improvement if you are only using one server.

- More get_multi performance optimization [xaop, #315]
- Add lambda support for cache namespaces [joshwlewis, #311]

2.6.0
=======

- read_multi optimization, now checks local_cache [chendo, #306]
- Re-implement get_multi to be non-blocking [tmm1, #295]
- Add `dalli` accessor to dalli_store to access the underlying
Dalli::Client, for things like `get_multi`.
- Add `Dalli::GzipCompressor`, primarily for compatibility with nginx's HttpMemcachedModule using `memcached_gzip_flag`

2.5.0
=======

- Don't escape non-ASCII keys, memcached binary protocol doesn't care. [#257]
- :dalli_store now implements LocalCache [#236]
- Removed lots of old session_store test code, tests now all run without a default memcached server [#275]
- Changed Dalli ActiveSupport adapter to always attempt instrumentation [brianmario, #284]
- Change write operations (add/set/replace) to return false when value is too large to store [brianmario, #283]
- Allowing different compressors per client [naseem]

2.4.0
=======
- Added the ability to swap out the compressed used to [de]compress cache data [brianmario, #276]
- Fix get\_multi performance issues with lots of memcached servers [tmm1]
- Throw more specific exceptions [tmm1]
- Allowing different types of serialization per client [naseem]

2.3.0
=======
- Added the ability to swap out the serializer used to [de]serialize cache data [brianmario, #274]

2.2.1
=======

- Fix issues with ENV-based connections. [#266]
- Fix problem with SessionStore in Rails 4.0 [#265]

2.2.0
=======

- Add Rack session with\_lock helper, for Rails 4.0 support [#264]
- Accept connection string in the form of a URL (e.g., memcached://user:pass@hostname:port) [glenngillen]
- Add touch operation [#228, uzzz]

2.1.0
=======

- Add Railtie to auto-configure Dalli when included in Gemfile [#217, steveklabnik]

2.0.5
=======

- Create proper keys for arrays of objects passed as keys [twinturbo, #211]
- Handle long key with namespace [#212]
- Add NODELAY to TCP socket options [#206]

2.0.4
=======

- Dalli no longer needs to be reset after Unicorn/Passenger fork [#208]
- Add option to re-raise errors rescued in the session and cache stores. [pitr, #200]
- DalliStore#fetch called the block if the cached value == false [#205]
- DalliStore should have accessible options [#195]
- Add silence and mute support for DalliStore [#207]
- Tracked down and fixed socket corruption due to Timeout [#146]

2.0.3
=======

- Allow proper retrieval of stored `false` values [laserlemon, #197]
- Allow non-ascii and whitespace keys, only the text protocol has those restrictions [#145]
- Fix DalliStore#delete error-handling [#196]

2.0.2
=======

- Fix all dalli\_store operations to handle nil options [#190]
- Increment and decrement with :initial => nil now return nil (lawrencepit, #112)

2.0.1
=======

- Fix nil option handling in dalli\_store#write [#188]

2.0.0
=======

- Reimplemented the Rails' dalli\_store to remove use of
  ActiveSupport::Cache::Entry which added 109 bytes overhead to every
  value stored, was a performance bottleneck and duplicated a lot of
  functionality already in Dalli.  One benchmark went from 4.0 sec to 3.0
  sec with the new dalli\_store. [#173]
- Added reset\_stats operation [#155]
- Added support for configuring keepalive on TCP connections to memcached servers (@bianster, #180)

Notes:

  * data stored with dalli\_store 2.x is NOT backwards compatible with 1.x.
    Upgraders are advised to namespace their keys and roll out the 2.x
    upgrade slowly so keys do not clash and caches are warmed.
    `config.cache_store = :dalli_store, :expires_in => 24.hours.to_i, :namespace => 'myapp2'`
  * data stored with plain Dalli::Client API is unchanged.
  * removed support for dalli\_store's race\_condition\_ttl option.
  * removed support for em-synchrony and unix socket connection options.
  * removed support for Ruby 1.8.6
  * removed memcache-client compability layer and upgrade documentation.


1.1.5
=======

- Coerce input to incr/decr to integer via #to\_i [#165]
- Convert test suite to minitest/spec (crigor, #166)
- Fix encoding issue with keys [#162]
- Fix double namespacing with Rails and dalli\_store. [#160]

1.1.4
=======

- Use 127.0.0.1 instead of localhost as default to avoid IPv6 issues
- Extend DalliStore's :expires\_in when :race\_condition\_ttl is also used.
- Fix :expires\_in option not propogating from DalliStore to Client, GH-136
- Added support for native Rack session store.  Until now, Dalli's
  session store has required Rails.  Now you can use Dalli to store
  sessions for any Rack application.

    require 'rack/session/dalli'
    use Rack::Session::Dalli, :memcache_server => 'localhost:11211', :compression => true

1.1.3
=======

- Support Rails's autoloading hack for loading sessions with objects
  whose classes have not be required yet, GH-129
- Support Unix sockets for connectivity.  Shows a 2x performance
  increase but keep in mind they only work on localhost. (dfens)

1.1.2
=======

- Fix incompatibility with latest Rack session API when destroying
  sessions, thanks @twinge!

1.1.1
=======

v1.1.0 was a bad release.  Yanked.

1.1.0
=======

- Remove support for Rails 2.3, add support for Rails 3.1
- Fix socket failure retry logic, now you can restart memcached and Dalli won't complain!
- Add support for fibered operation via em-synchrony (eliaslevy)
- Gracefully handle write timeouts, GH-99
- Only issue bug warning for unexpected StandardErrors, GH-102
- Add travis-ci build support (ryanlecompte)
- Gracefully handle errors in get_multi (michaelfairley)
- Misc fixes from crash2burn, fphilipe, igreg, raggi

1.0.5
=======

- Fix socket failure retry logic, now you can restart memcached and Dalli won't complain!

1.0.4
=======

- Handle non-ASCII key content in dalli_store
- Accept key array for read_multi in dalli_store
- Fix multithreaded race condition in creation of mutex

1.0.3
=======

- Better handling of application marshalling errors
- Work around jruby IO#sysread compatibility issue


1.0.2
=======

 - Allow browser session cookies (blindsey)
 - Compatibility fixes (mwynholds)
 - Add backwards compatibility module for memcache-client, require 'dalli/memcache-client'.  It makes
   Dalli more compatible with memcache-client and prints out a warning any time you do something that
   is no longer supported so you can fix your code.

1.0.1
=======

 - Explicitly handle application marshalling bugs, GH-56
 - Add support for username/password as options, to allow multiple bucket access
   from the same Ruby process, GH-52
 - Add support for >1MB values with :value_max_bytes option, GH-54 (r-stu31)
 - Add support for default TTL, :expires_in, in Rails 2.3. (Steven Novotny)
   config.cache_store = :dalli_store, 'localhost:11211', {:expires_in => 4.hours}


1.0.0
=======

Welcome gucki as a Dalli committer!

 - Fix network and namespace issues in get_multi (gucki)
 - Better handling of unmarshalling errors (mperham)

0.11.2
=======

 - Major reworking of socket error and failover handling (gucki)
 - Add basic JRuby support (mperham)

0.11.1
======

 - Minor fixes, doc updates.
 - Add optional support for kgio sockets, gives a 10-15% performance boost.

0.11.0
======

Warning: this release changes how Dalli marshals data.  I do not guarantee compatibility until 1.0 but I will increment the minor version every time a release breaks compatibility until 1.0.

IT IS HIGHLY RECOMMENDED YOU FLUSH YOUR CACHE BEFORE UPGRADING.

 - multi() now works reentrantly.
 - Added new Dalli::Client option for default TTLs, :expires_in, defaults to 0 (aka forever).
 - Added new Dalli::Client option, :compression, to enable auto-compression of values.
 - Refactor how Dalli stores data on the server.  Values are now tagged
   as "marshalled" or "compressed" so they can be automatically deserialized
   without the client having to know how they were stored.

0.10.1
======

 - Prefer server config from environment, fixes Heroku session store issues (thanks JoshMcKin)
 - Better handling of non-ASCII values (size -> bytesize)
 - Assert that keys are ASCII only

0.10.0
======

Warning: this release changed how Rails marshals data with Dalli.  Unfortunately previous versions double marshalled values.  It is possible that data stored with previous versions of Dalli will not work with this version.

IT IS HIGHLY RECOMMENDED YOU FLUSH YOUR CACHE BEFORE UPGRADING.

 - Rework how the Rails cache store does value marshalling.
 - Rework old server version detection to avoid a socket read hang.
 - Refactor the Rails 2.3 :dalli\_store to be closer to :mem\_cache\_store.
 - Better documentation for session store config (plukevdh)

0.9.10
----

 - Better server retry logic (next2you)
 - Rails 3.1 compatibility (gucki)


0.9.9
----

 - Add support for *_multi operations for add, set, replace and delete.  This implements
   pipelined network operations; Dalli disables network replies so we're not limited by
   latency, allowing for much higher throughput.

    dc = Dalli::Client.new
    dc.multi do
      dc.set 'a', 1
      dc.set 'b', 2
      dc.set 'c', 3
      dc.delete 'd'
    end
 - Minor fix to set the continuum sorted by value (kangster)
 - Implement session store with Rails 2.3.  Update docs.

0.9.8
-----

 - Implement namespace support
 - Misc fixes


0.9.7
-----

 - Small fix for NewRelic integration.
 - Detect and fail on older memcached servers (pre-1.4).

0.9.6
-----

 - Patches for Rails 3.0.1 integration.

0.9.5
-----

 - Major design change - raw support is back to maximize compatibility with Rails
 and the increment/decrement operations.  You can now pass :raw => true to most methods
 to bypass (un)marshalling.
 - Support symbols as keys (ddollar)
 - Rails 2.3 bug fixes


0.9.4
-----

 - Dalli support now in rack-bug (http://github.com/brynary/rack-bug), give it a try!
 - Namespace support for Rails 2.3 (bpardee)
 - Bug fixes


0.9.3
-----

 - Rails 2.3 support (beanieboi)
 - Rails SessionStore support
 - Passenger integration
 - memcache-client upgrade docs, see Upgrade.md


0.9.2
----

 - Verify proper operation in Heroku.


0.9.1
----

 - Add fetch and cas operations (mperham)
 - Add incr and decr operations (mperham)
 - Initial support for SASL authentication via the MEMCACHE_{USERNAME,PASSWORD} environment variables, needed for Heroku (mperham)

0.9.0
-----

 - Initial gem release.
