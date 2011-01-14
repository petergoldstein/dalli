Performance
====================

Caching is all about performance, so I carefully track Dalli performance to ensure no regressions.
Times are from a Unibody MBP 2.4Ghz Core i5 running Snow Leopard.

You can optionally use kgio to give Dalli a small, 10-20% performance boost: gem install kgio.

*memcache-client*:

	Testing 1.8.5 with ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0]
	                                     user     system      total        real
	set:plain:memcache-client        1.950000   0.320000   2.270000 (  2.271513)
	set:ruby:memcache-client         2.040000   0.310000   2.350000 (  2.355625)
	get:plain:memcache-client        2.160000   0.330000   2.490000 (  2.499911)
	get:ruby:memcache-client         2.310000   0.340000   2.650000 (  2.659208)
	multiget:ruby:memcache-client    1.050000   0.130000   1.180000 (  1.168383)
	missing:ruby:memcache-client     2.050000   0.320000   2.370000 (  2.384290)
	mixed:ruby:memcache-client       4.440000   0.660000   5.100000 (  5.148145)

*dalli*:

	Using kgio socket IO
	Testing 1.0.1 with ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0]
	                                     user     system      total        real
	set:plain:dalli                  0.840000   0.300000   1.140000 (  1.516160)
	setq:plain:dalli                 0.510000   0.120000   0.630000 (  0.634174)
	set:ruby:dalli                   0.880000   0.300000   1.180000 (  1.549591)
	get:plain:dalli                  0.970000   0.330000   1.300000 (  1.621385)
	get:ruby:dalli                   0.970000   0.340000   1.310000 (  1.622811)
	multiget:ruby:dalli              0.800000   0.250000   1.050000 (  1.453479)
	missing:ruby:dalli               0.820000   0.330000   1.150000 (  1.453847)
	mixed:ruby:dalli                 1.850000   0.640000   2.490000 (  3.189240)
	mixedq:ruby:dalli                1.820000   0.530000   2.350000 (  2.611830)
	incr:ruby:dalli                  0.310000   0.110000   0.420000 (  0.545641)
