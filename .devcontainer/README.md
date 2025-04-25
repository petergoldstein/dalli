# Dalli Development Container

This directory contains configuration for a development container that provides a consistent environment for working on Dalli.

## Features

- Ruby 3.2 environment with all necessary dependencies
- Memcached 1.6.34 installed with SASL and TLS support, matching the GitHub Actions CI environment
- Configuration for testing, including SASL authentication setup
- VS Code extensions for Ruby development

## Setup Process

When the container is built and started, the following setup occurs:

1. The container is built with necessary dependencies but without memcached
2. The `setup.sh` script runs after the container is created which:
   - Installs memcached 1.6.34 using the same script used in GitHub Actions
   - Configures SASL authentication for testing
   - Sets up environment variables needed for tests
   - Installs gem dependencies

## Running Tests

Once the container is running, you can run tests with:

```bash
bundle exec rake test
```

To run specific test files:

```bash
bundle exec ruby -Ilib:test test/path/to/test_file.rb
```

## Troubleshooting

If you encounter issues with tests:

1. Verify memcached is running: `ps aux | grep memcached`
2. Check memcached version: `memcached -h | head -1`
3. Verify SASL is configured: `cat /usr/lib/sasl2/memcached.conf`
4. Try restarting memcached: `sudo service memcached restart`
5. Check logs for any errors: `sudo journalctl -u memcached`

## Port Forwarding

The following memcached ports are forwarded for testing:
- 11211 - Default memcached port
- 11212-11215 - Additional ports used by tests

## Environment Variables

- `RUN_SASL_TESTS=1` - Enables SASL authentication tests