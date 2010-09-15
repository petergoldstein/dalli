Dalli Changelog
=====================

HEAD
-----

 - Major design change - raw support is back to maximize compatibility with Rails
 and the increment/decrement operations.  You can now pass :raw => true to most methods
 to bypass (un)marshalling.

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