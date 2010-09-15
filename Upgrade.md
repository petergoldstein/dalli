Upgrading from memcache-client
========

Dalli is not meant to be 100% compatible with memcache-client, there are a few minor differences in the API.


Marshalling
---------------

Dalli has changed the raw parameter to a :raw option.  The memcache-client API allowed you to control marshalling on a per-method basis using a boolean 'raw' parameter to several of the API methods:

    cache = MemCache.new
    cache.set('abc', 123, 0, true)
    cache.get('abc', true) => '123'

    cache.set('abc', 123, 0)
    cache.get('abc') => 123

Note that the last parameter is set to true in the first two API calls and so `get` returns a string, not an integer.  In the second example, we don't provide the raw parameter.  Since it defaults to false, it works exactly like Dalli.

If the code specifies raw as false, you can simply remove that parameter.  If the code is using raw = true, you will need to use the :raw option:

    cache.set('abc', 123, 0, :raw => true)


Return Values
----------------

In memcache-client, `set(key, value)` normally returns "STORED\r\n".  This is an artifact of the text protocol used in earlier versions of memcached.  Code that checks the return value will need to be updated.  Dalli raises errors for exceptional cases but otherwise returns true or false depending on whether the operation succeeded or not.  These methods are affected:

    set
    add
    replace
