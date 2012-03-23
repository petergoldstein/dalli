Performance
====================

Caching is all about performance, so I carefully track Dalli performance to ensure no regressions.
You can optionally use kgio to give Dalli a 10-20% performance boost: `gem install kgio`.

Note I've added some benchmarks over time to Dalli that the other libraries don't necessarily have.

memcache-client
---------------

Testing 1.8.5 with ruby 1.9.3p0 (2011-10-30 revision 33570) [x86_64-darwin11.2.0]

                                          user     system      total        real
    set:plain:memcache-client         1.860000   0.310000   2.170000 (  2.188030)
    set:ruby:memcache-client          1.830000   0.290000   2.120000 (  2.130212)
    get:plain:memcache-client         1.830000   0.340000   2.170000 (  2.176156)
    get:ruby:memcache-client          1.900000   0.330000   2.230000 (  2.235045)
    multiget:ruby:memcache-client     0.860000   0.120000   0.980000 (  0.987348)
    missing:ruby:memcache-client      1.630000   0.320000   1.950000 (  1.954867)
    mixed:ruby:memcache-client        3.690000   0.670000   4.360000 (  4.364469)


dalli
-----

Testing with Rails 3.2.1
Using kgio socket IO
Testing 2.0.0 with ruby 1.9.3p125 (2012-02-16 revision 34643) [x86_64-darwin11.3.0]

                                          user     system      total        real
    mixed:rails:dalli                 1.580000   0.570000   2.150000 (  3.008839)
    set:plain:dalli                   0.730000   0.300000   1.030000 (  1.567098)
    setq:plain:dalli                  0.520000   0.120000   0.640000 (  0.634402)
    set:ruby:dalli                    0.800000   0.300000   1.100000 (  1.640348)
    get:plain:dalli                   0.840000   0.330000   1.170000 (  1.668425)
    get:ruby:dalli                    0.850000   0.330000   1.180000 (  1.665716)
    multiget:ruby:dalli               0.700000   0.260000   0.960000 (  0.965423)
    missing:ruby:dalli                0.720000   0.320000   1.040000 (  1.511720)
    mixed:ruby:dalli                  1.660000   0.640000   2.300000 (  3.320743)
    mixedq:ruby:dalli                 1.630000   0.510000   2.140000 (  2.629734)
    incr:ruby:dalli                   0.270000   0.100000   0.370000 (  0.547618)
