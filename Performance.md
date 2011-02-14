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
