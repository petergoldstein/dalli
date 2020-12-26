#!/bin/bash


sudo apt-get -y remove memcached
sudo apt-get install libevent-dev
wget https://memcached.org/files/memcached-1.5.20.tar.gz
tar -zxvf memcached-1.5.20.tar.gz
cd memcached-1.5.20
./configure --enable-sasl
make
