#!/bin/bash

set -euo pipefail

version=$MEMCACHED_VERSION

sudo apt-get -y remove memcached
sudo apt-get install libevent-dev

echo Installing Memcached version ${version}

# Install memcached with TLS support
wget https://memcached.org/files/memcached-${version}.tar.gz
tar -zxvf memcached-${version}.tar.gz
cd memcached-${version}

# Manual patch so 1.5 will compile
if [[ -f "../memcached_${version}.patch" ]]; then
  patch -p1 < "../memcached_${version}.patch"
fi

./configure --enable-tls
make
sudo mv memcached /usr/local/bin/

echo Memcached version ${version} installation complete
