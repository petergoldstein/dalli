# frozen_string_literal: true

require 'openssl'

##
# Utility module for generating certificates used by a local Memcached server
# exposing a TLS/SSL interface in test.
##
module CertificateGenerator
  ROOT_CA_PK_PATH = '/tmp/root.key'
  ROOT_CA_CERT_PATH = '/tmp/root.crt'

  MEMCACHED_PK_PATH = '/tmp/memcached.key'
  MEMCACHED_CERT_PATH = '/tmp/memcached.crt'

  def self.generate
    issuer_cert, issuer_key = generate_root_certificate
    generate_server_certifcate(issuer_cert, issuer_key)
  end

  def self.ssl_args
    "-Z -o ssl_chain_cert=#{MEMCACHED_CERT_PATH} -o ssl_key=#{MEMCACHED_PK_PATH}"
  end

  def self.clean
    [ROOT_CA_CERT_PATH, ROOT_CA_PK_PATH, MEMCACHED_CERT_PATH, MEMCACHED_PK_PATH].each do |path|
      File.delete(path) if File.exist?(path)
    end
  end

  def self.ssl_context
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_context.ca_file = CertificateGenerator::ROOT_CA_CERT_PATH
    ssl_context.ssl_version = :SSLv23
    ssl_context.verify_hostname = true if ssl_context.respond_to?(:verify_hostname=)
    ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
    ssl_context
  end

  def self.generate_server_certifcate(issuer_cert, issuer_key)
    cert, key = generate_certificate_common('/CN=localhost', issuer_cert)
    cert.serial = 2

    ef = extension_factory(cert, issuer_cert)
    cert.add_extension(ef.create_extension('subjectAltName', 'DNS:localhost,IP:127.0.0.1', false))
    cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature', true))
    cert.sign(issuer_key, OpenSSL::Digest.new('SHA256'))

    File.write(MEMCACHED_PK_PATH, key)
    File.write(MEMCACHED_CERT_PATH, cert)
    [cert, key]
  end

  def self.generate_root_certificate
    cert, key = generate_certificate_common('/CN=Dalli CA')
    cert.serial = 1

    ef = extension_factory(cert, cert)
    cert.add_extension(ef.create_extension('basicConstraints', 'CA:TRUE', true))
    cert.add_extension(ef.create_extension('keyUsage', 'keyCertSign, cRLSign', true))
    cert.sign(key, OpenSSL::Digest.new('SHA256'))
    File.write(ROOT_CA_PK_PATH, key)
    File.write(ROOT_CA_CERT_PATH, cert)
    [cert, key]
  end

  def self.extension_factory(cert, issuer_cert)
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = issuer_cert
    cert.add_extension(ef.create_extension('subjectKeyIdentifier', 'hash', false))
    ef
  end

  def self.generate_certificate_common(subject_as_s, issuer_cert = nil)
    cert = base_cert(subject_as_s)

    # Self-sign unless there's an issuer cert
    cert.issuer = issuer_cert ? issuer_cert.subject : cert.subject

    [cert, pk_for_cert(cert)]
  end

  def self.base_cert(subject_as_s)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2 # cf. RFC 5280 - to make it a "v3" certificate
    cert.not_before = Time.now
    cert.not_after = cert.not_before + (2 * 365 * 24 * 60 * 60) # 2 years
    cert.subject = OpenSSL::X509::Name.parse(subject_as_s)
    cert
  end

  def self.pk_for_cert(cert)
    key = OpenSSL::PKey::RSA.new 2048 # the CA's public/private key
    cert.public_key = key.public_key
    key
  end
end
