Performance
====================

Caching is all about performance, so I carefully track Dalli performance to ensure no regressions.

	Testing 1.8.5 with ruby 1.9.2p0 (2010-08-18 revision 29036) [x86_64-darwin10.4.0]
	                                     user     system      total        real
	set:plain:memcache-client        1.600000   0.390000   1.990000 (  2.020491)
	set:ruby:memcache-client         1.680000   0.390000   2.070000 (  2.108217)
	get:plain:memcache-client        1.740000   0.250000   1.990000 (  2.018315)
	get:ruby:memcache-client         1.790000   0.250000   2.040000 (  2.065529)
	multiget:ruby:memcache-client    0.800000   0.090000   0.890000 (  0.914336)
	missing:ruby:memcache-client     1.480000   0.250000   1.730000 (  1.761555)
	mixed:ruby:memcache-client       3.470000   0.640000   4.110000 (  4.195236)

	Testing 0.1.0 with ruby 1.9.2p0 (2010-08-18 revision 29036) [x86_64-darwin10.4.0]
	                                     user     system      total        real
	set:plain:dalli                  0.430000   0.180000   0.610000 (  1.051395)
	set:ruby:dalli                   0.490000   0.180000   0.670000 (  1.124848)
	get:plain:dalli                  0.490000   0.210000   0.700000 (  1.141887)
	get:ruby:dalli                   0.540000   0.200000   0.740000 (  1.188353)
	multiget:ruby:dalli              0.510000   0.200000   0.710000 (  0.772860)
	missing:ruby:dalli               0.450000   0.210000   0.660000 (  1.070748)
	mixed:ruby:dalli                 1.050000   0.390000   1.440000 (  2.304933)