#!/bin/bash

set -euo pipefail

version=$MEMCACHED_VERSION

sudo apt-get -y remove memcached
# Refresh the runner image's package index first: when Ubuntu replaces a package
# version, the stale index points at files the mirrors no longer serve (404).
sudo apt-get update
sudo apt-get -y install libevent-dev

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
