#!/bin/bash
set -e

echo "Setting up Dalli development environment..."

# Install memcached using the script from scripts directory
echo "Installing memcached..."
cd /workspace
export MEMCACHED_VERSION=1.6.45
bash scripts/install_memcached.sh

# Clean up memcached installation files
echo "Cleaning up memcached installation files..."
rm -f memcached-${MEMCACHED_VERSION}.tar.gz
rm -rf memcached-${MEMCACHED_VERSION}

# Fix permissions
sudo chown -R vscode:vscode /usr/local/bundle
echo "Installing dependencies..."
cd /workspace
bundle install

echo "Environment setup complete!"
echo "You can now run tests with: bundle exec rake test"
echo "To run a specific test file: bundle exec ruby -Itest test/integration/test_fork.rb"
