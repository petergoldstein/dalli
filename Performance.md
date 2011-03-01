Performance
====================

Caching is all about performance, so I carefully track Dalli performance to ensure no regressions.
Times are from a Unibody MBP 2.4Ghz Core i5 running Snow Leopard.

You can optionally use kgio to give Dalli a small, 10-20% performance boost: gem install kgio.

*memcache-client*:

	Testing 1.8.5 with ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0]
	                                     user     system      total        real
	set:plain:memcache               2.070000   0.340000   2.410000 (  2.611709)
	set:ruby:memcache                1.990000   0.330000   2.320000 (  2.869653)
	get:plain:memcache               2.290000   0.360000   2.650000 (  2.926425)
	get:ruby:memcache                2.360000   0.350000   2.710000 (  2.951604)
	multiget:ruby:memcache           1.050000   0.120000   1.170000 (  1.285787)
	missing:ruby:memcache            1.990000   0.330000   2.320000 (  2.567641)
	mixed:ruby:memcache              4.390000   0.670000   5.060000 (  5.721000)
	incr:ruby:memcache               0.700000   0.120000   0.820000 (  0.842896)

*libmemcached*:

	Testing 1.1.2 with ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0]
	                                     user     system      total        real
	set:plain:libm                   0.120000   0.220000   0.340000 (  0.847521)
	setq:plain:libm                  0.030000   0.000000   0.030000 (  0.126944)
	set:ruby:libm                    0.220000   0.250000   0.470000 (  1.102789)
	get:plain:libm                   0.140000   0.230000   0.370000 (  0.813998)
	get:ruby:libm                    0.210000   0.240000   0.450000 (  1.025994)
	multiget:ruby:libm               0.100000   0.080000   0.180000 (  0.322217)
	missing:ruby:libm                0.250000   0.240000   0.490000 (  1.049972)
	mixed:ruby:libm                  0.400000   0.410000   0.810000 (  2.172349)
	mixedq:ruby:libm                 0.410000   0.360000   0.770000 (  1.516718)
	incr:ruby:libm                   0.080000   0.340000   0.420000 (  1.685931)

*dalli*:

	Using kgio socket IO
	Testing 1.0.2 with ruby 1.9.2p136 (2010-12-25 revision 30365) [x86_64-darwin10.6.0]
	                                     user     system      total        real
	set:plain:dalli                  0.850000   0.320000   1.170000 (  1.691393)
	setq:plain:dalli                 0.500000   0.130000   0.630000 (  0.651227)
	set:ruby:dalli                   0.900000   0.330000   1.230000 (  1.865228)
	get:plain:dalli                  0.990000   0.390000   1.380000 (  1.929994)
	get:ruby:dalli                   0.950000   0.370000   1.320000 (  1.844251)
	multiget:ruby:dalli              0.790000   0.300000   1.090000 (  1.227073)
	missing:ruby:dalli               0.810000   0.370000   1.180000 (  1.627039)
	mixed:ruby:dalli                 1.850000   0.710000   2.560000 (  3.555032)
	mixedq:ruby:dalli                1.840000   0.610000   2.450000 (  2.945982)
	incr:ruby:dalli                  0.310000   0.120000   0.430000 (  0.616465)

Testing 1.0.2 with rubinius 1.3.0dev (1.8.7 382e813f xxxx-xx-xx JI) [x86_64-apple-darwin10.6.0]
	                                     user     system      total        real
	set:plain:dalli                  2.800581   0.329360   3.129941 (  5.186546)
	setq:plain:dalli                 1.064253   0.138044   1.202297 (  1.280355)
	set:ruby:dalli                   2.220885   0.262619   2.483504 (  2.778118)
	get:plain:dalli                  2.291344   0.280490   2.571834 (  2.948004)
	get:ruby:dalli                   2.148900   0.274477   2.423377 (  2.425808)
	multiget:ruby:dalli              1.724193   0.249145   1.973338 (  2.158673)
	missing:ruby:dalli               1.881502   0.272610   2.154112 (  2.208384)
	mixed:ruby:dalli                 4.292620   0.533768   4.826388 (  4.830238)
	mixedq:ruby:dalli                4.076032   0.501442   4.577474 (  4.583800)
	incr:ruby:dalli                  0.691467   0.091475   0.782942 (  0.931674)

Testing 1.0.2 with rubinius 1.2.0 (1.8.7 release 2010-12-21 JI) [x86_64-apple-darwin10.6.0]
	                                     user     system      total        real
	set:plain:dalli                  6.586927   0.331545   6.918472 (  4.628652)
	setq:plain:dalli                 0.930905   0.129008   1.059913 (  1.016105)
	set:ruby:dalli                   2.702486   0.283004   2.985490 (  2.690442)
	get:plain:dalli                  2.740202   0.291353   3.031555 (  2.722746)
	get:ruby:dalli                   1.979379   0.282986   2.262365 (  2.264118)
	multiget:ruby:dalli              1.887086   0.249799   2.136885 (  1.803230)
	missing:ruby:dalli               1.882662   0.278019   2.160681 (  2.113429)
	mixed:ruby:dalli                 3.969242   0.553361   4.522603 (  4.524504)
	mixedq:ruby:dalli                3.520755   0.475669   3.996424 (  3.997405)
	incr:ruby:dalli                  0.849998   0.094012   0.944010 (  0.884001)
