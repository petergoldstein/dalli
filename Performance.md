Performance
====================

Caching is all about performance, so I carefully track Dalli performance to ensure no regressions.
Times are from a Unibody MBP 2.4Ghz Core 2 Duo running Snow Leopard.

    Testing 1.8.5 with ruby 1.9.2p0 (2010-08-18 revision 29036) [x86_64-darwin10.4.0]
                                         user     system      total        real
    set:plain:memcache-client        2.070000   0.590000   2.660000 (  2.669744)
    set:ruby:memcache-client         2.150000   0.570000   2.720000 (  2.734616)
    get:plain:memcache-client        2.240000   0.400000   2.640000 (  2.675747)
    get:ruby:memcache-client         2.290000   0.380000   2.670000 (  2.682108)
    multiget:ruby:memcache-client    1.030000   0.140000   1.170000 (  1.174503)
    missing:ruby:memcache-client     1.900000   0.370000   2.270000 (  2.282264)
    mixed:ruby:memcache-client       4.430000   0.950000   5.380000 (  5.420251)

    Testing 0.9.0 with ruby 1.9.2p0 (2010-08-18 revision 29036) [x86_64-darwin10.4.0]
                                         user     system      total        real
    set:plain:dalli                  1.610000   0.360000   1.970000 (  2.032947)
    set:ruby:dalli                   1.690000   0.360000   2.050000 (  2.108120)
    get:plain:dalli                  1.710000   0.400000   2.110000 (  2.123895)
    get:ruby:dalli                   1.760000   0.390000   2.150000 (  2.170964)
    multiget:ruby:dalli              0.950000   0.310000   1.260000 (  1.269679)
    missing:ruby:dalli               1.650000   0.380000   2.030000 (  2.054383)
    mixed:ruby:dalli                 3.470000   0.750000   4.220000 (  4.323265)

    Testing 0.9.4 with ruby 1.9.2p0 (2010-08-18 revision 29036) [x86_64-darwin10.4.0]
                                         user     system      total        real
    set:plain:dalli                  1.380000   0.350000   1.730000 (  1.818374)
    set:ruby:dalli                   1.460000   0.320000   1.780000 (  1.851925)
    get:plain:dalli                  1.420000   0.350000   1.770000 (  1.866443)
    get:ruby:dalli                   1.570000   0.380000   1.950000 (  2.028747)
    multiget:ruby:dalli              0.870000   0.300000   1.170000 (  1.295592)
    missing:ruby:dalli               1.420000   0.370000   1.790000 (  1.925094)
    mixed:ruby:dalli                 2.800000   0.680000   3.480000 (  3.820694)
