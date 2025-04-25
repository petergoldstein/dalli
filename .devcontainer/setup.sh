#!/bin/bash
set -e

echo "Setting up Dalli development environment..."

# Install memcached using the script from scripts directory
echo "Installing memcached..."
cd /workspace
export MEMCACHED_VERSION=1.6.34
chmod +x scripts/install_memcached.sh
scripts/install_memcached.sh

# Clean up memcached installation files
echo "Cleaning up memcached installation files..."
rm -f memcached-${MEMCACHED_VERSION}.tar.gz
rm -rf memcached-${MEMCACHED_VERSION}

# Create symlink for memcached-tool if needed
if [ ! -f /usr/local/bin/memcached-tool ]; then
  echo "Creating symlink for memcached-tool..."
  sudo ln -sf /usr/share/memcached/scripts/memcached-tool /usr/local/bin/memcached-tool
fi

echo "Setting up environment variables..."
# Ensure test environment is properly configured
cat >> ~/.bashrc << EOF

# Dalli test environment
export RUN_SASL_TESTS=1
EOF

# Fix permissions
sudo chown -R vscode:vscode /usr/local/bundle
echo "Installing dependencies..."
cd /workspace
bundle install

echo "Environment setup complete!"
echo "You can now run tests with: bundle exec rake test"
echo "To run a specific test file: bundle exec ruby -Ilib:test test/integration/test_fork.rb"
