Dalli Changelog
=====================

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
