#!/bin/bash

version="1.5.22"

sudo apt-get -y remove memcached
sudo apt-get install libevent-dev
sudo apt-get install libsasl2-dev
wget https://memcached.org/files/memcached-${version}.tar.gz
tar -zxvf memcached-${version}.tar.gz
cd memcached-${version}
./configure --enable-sasl --enable-tls
make
sudo mv memcached /usr/local/bin/
