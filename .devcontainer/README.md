# Dalli Development Container

This directory contains configuration for a development container that provides a consistent environment for working on Dalli.

## Features

- Ruby 4.0 on Debian 13 (trixie)
- Memcached 1.6.45 built with TLS support, matching the latest version tested in GitHub Actions CI
- The Ruby LSP VS Code extension, with RuboCop formatting

## Setup Process

When the container is built and started, the following setup occurs:

1. The container is built with necessary dependencies but without memcached
2. The `setup.sh` script runs after the container is created which:
   - Builds memcached 1.6.45 using the same script used in GitHub Actions
   - Installs gem dependencies

## Running Tests

Once the container is running, you can run tests with:

```bash
bundle exec rake test
```

To run specific test files:

```bash
bundle exec ruby -Itest test/path/to/test_file.rb
```

The tests start their own memcached instances on random ports, so there is no
memcached service to start or forward.

## Troubleshooting

If you encounter issues with tests:

1. Check that memcached is on the path and the expected version: `memcached --version`
2. Check that it was built with TLS support: `memcached -h | grep -i tls`
3. Look for stray memcached processes left over from an interrupted run: `ps aux | grep memcached`
