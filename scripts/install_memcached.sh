#!/bin/bash

sudo apt-get -y remove memcached
sudo apt-get install libevent-dev
sudo apt-get install libsasl2-dev
wget https://memcached.org/files/memcached-1.6.9.tar.gz
tar -zxvf memcached-1.6.9.tar.gz
cd memcached-1.6.9
./configure --enable-sasl
make
sudo mv memcached /usr/local/bin/
