#!/bin/bash

version=$MEMCACHED_VERSION


sudo apt-get -y remove memcached
sudo apt-get install libevent-dev libsasl2-dev sasl2-bin

echo Installing Memcached version ${version}

# Install memcached with SASL and TLS support
wget https://memcached.org/files/memcached-${version}.tar.gz
tar -zxvf memcached-${version}.tar.gz
cd memcached-${version}
./configure --enable-sasl --enable-tls
make
sudo mv memcached /usr/local/bin/

echo Memcached version ${version} installation complete

echo Configuring SASL

# Create SASL credentials for testing
echo 'mech_list: plain' | sudo tee -a /usr/lib/sasl2/memcached.conf > /dev/null

echo testtest | sudo saslpasswd2 -a memcached -c testuser -p
sudo chmod 644 /etc/sasldb2

echo SASL configuration complete
