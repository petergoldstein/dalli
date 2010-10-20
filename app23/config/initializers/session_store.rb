# Be sure to restart your server when you modify this file.

# Your secret key for verifying cookie session data integrity.
# If you change this key, all old sessions will become invalid!
# Make sure the secret is at least 30 characters and all random, 
# no regular words or you'll be exposed to dictionary attacks.
ActionController::Base.session = {
  :key         => '_test23_session',
  :namespace   => 'sessions',
  :memcache_server => ['localhost', '127.0.0.1'],
  :expire_after => 10, # seconds
  :secret      => 'c3cf2f7ece3f0c0316147b64d88704b51cb2bd26114e1c06a24d58ea99f118a8f11892eda293975d5ae4de75a77266cd277f7364fbcae1eb580fc7e7311b40a7'
}

require 'action_controller/session/dalli_store'
ActionController::Base.session_store = :dalli_store
