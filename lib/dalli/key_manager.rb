# frozen_string_literal: true

require 'digest/md5'

module Dalli
  ##
  # This class manages and validates keys sent to Memcached, ensuring
  # that they meet Memcached key length requirements, and supporting
  # the implementation of optional namespaces on a per-Dalli client
  # basis.
  ##
  class KeyManager
    MAX_KEY_LENGTH = 250

    NAMESPACE_SEPARATOR = ':'

    # This is a hard coded md5 for historical reasons
    TRUNCATED_KEY_SEPARATOR = ':md5:'

    # This is 249 for historical reasons
    TRUNCATED_KEY_TARGET_SIZE = 249

    DEFAULTS = {
      digest_class: ::Digest::MD5
    }.freeze

    OPTIONS = %i[digest_class namespace].freeze

    attr_reader :namespace

    def initialize(client_options)
      @key_options =
        DEFAULTS.merge(client_options.select { |k, _| OPTIONS.include?(k) })
      validate_digest_class_option(@key_options)

      @namespace = namespace_from_options
    end

    ##
    # Validates the key, and transforms as needed.
    #
    # If the key is nil or empty, raises ArgumentError.  Whitespace
    # characters are allowed for historical reasons, but likely shouldn't
    # be used.
    # If the key (with namespace) is shorter than the memcached maximum
    # allowed key length, just returns the argument key
    # Otherwise computes a "truncated" key that uses a truncated prefix
    # combined with a 32-byte hex digest of the whole key.
    ##
    def validate_key(key)
      raise ArgumentError, 'key cannot be blank' unless key&.length&.positive?

      key = key_with_namespace(key)
      key.length > MAX_KEY_LENGTH ? truncated_key(key) : key
    end

    ##
    # Returns the key with the namespace prefixed, if a namespace is
    # defined.  Otherwise just returns the key
    ##
    def key_with_namespace(key)
      return key if namespace.nil?

      "#{namespace}#{NAMESPACE_SEPARATOR}#{key}"
    end

    def key_without_namespace(key)
      return key if namespace.nil?

      key.sub(namespace_regexp, '')
    end

    def digest_class
      @digest_class ||= @key_options[:digest_class]
    end

    def namespace_regexp
      @namespace_regexp ||= /\A#{Regexp.escape(namespace)}:/.freeze unless namespace.nil?
    end

    def validate_digest_class_option(opts)
      return if opts[:digest_class].respond_to?(:hexdigest)

      raise ArgumentError, 'The digest_class object must respond to the hexdigest method'
    end

    def namespace_from_options
      raw_namespace = @key_options[:namespace]
      return nil unless raw_namespace
      return raw_namespace.call.to_s if raw_namespace.is_a?(Proc)

      raw_namespace.to_s
    end

    ##
    # Produces a truncated key, if the raw key is longer than the maximum allowed
    # length.  The truncated key is produced by generating a hex digest
    # of the key, and appending that to a truncated section of the key.
    ##
    def truncated_key(key)
      digest = digest_class.hexdigest(key)
      "#{key[0, prefix_length(digest)]}#{TRUNCATED_KEY_SEPARATOR}#{digest}"
    end

    def prefix_length(digest)
      return TRUNCATED_KEY_TARGET_SIZE - (TRUNCATED_KEY_SEPARATOR.length + digest.length) if namespace.nil?

      # For historical reasons, truncated keys with namespaces had a length of 250 rather
      # than 249
      TRUNCATED_KEY_TARGET_SIZE + 1 - (TRUNCATED_KEY_SEPARATOR.length + digest.length)
    end
  end
end
