Dalli Changelog
=====================

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
 - Minor fix to set the continuum sorted by value.
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
