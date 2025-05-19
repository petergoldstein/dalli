# frozen_string_literal: true

require_relative 'helper'

require 'json'
require 'rack/session/dalli'
require 'rack/lint'
require 'rack/mock'
describe Rack::Session::Dalli do
  before do
    @port = 19_129
    memcached_persistent(:binary, port_or_socket: @port)
    Rack::Session::Dalli::DEFAULT_DALLI_OPTIONS[:memcache_server] = "localhost:#{@port}"

    # test memcache connection
    Rack::Session::Dalli.new(incrementor)
  end

  let(:session_key) { Rack::Session::Dalli::DEFAULT_OPTIONS[:key] }
  let(:session_match) do
    /#{session_key}=([0-9a-fA-F]+);/
  end
  let(:incrementor_proc) do
    lambda do |env|
      env['rack.session']['counter'] ||= 0
      env['rack.session']['counter'] += 1
      Rack::Response.new(env['rack.session'].inspect).to_a
    end
  end
  let(:drop_session) do
    Rack::Lint.new(proc do |env|
                     env['rack.session.options'][:drop] = true
                     incrementor_proc.call(env)
                   end)
  end
  let(:renew_session) do
    Rack::Lint.new(proc do |env|
                     env['rack.session.options'][:renew] = true
                     incrementor_proc.call(env)
                   end)
  end
  let(:defer_session) do
    Rack::Lint.new(proc do |env|
                     env['rack.session.options'][:defer] = true
                     incrementor_proc.call(env)
                   end)
  end
  let(:skip_session) do
    Rack::Lint.new(proc do |env|
                     env['rack.session.options'][:skip] = true
                     incrementor_proc.call(env)
                   end)
  end
  let(:user_id_session) do
    Rack::Lint.new(proc do |env|
                     session = env['rack.session']

                     case env['PATH_INFO']
                     when '/login'
                       session[:user_id] = 1
                     when '/logout'
                       raise 'User not logged in' if session[:user_id].nil?

                       session.delete(:user_id)
                       session.options[:renew] = true
                     when '/slow'
                       Fiber.yield
                     end

                     Rack::Response.new(session.inspect).to_a
                   end)
  end
  let(:incrementor) { Rack::Lint.new(incrementor_proc) }

  it 'faults on no connection' do
    rsd = Rack::Session::Dalli.new(incrementor, memcache_server: 'nosuchserver')
    assert_raises Dalli::RingError do
      rsd.data.with { |c| c.set('ping', '') }
    end
  end

  it 'connects to existing server' do
    rsd = Rack::Session::Dalli.new(incrementor, namespace: 'test:rack:session')
    assert_silent do
      rsd.data.with { |c| c.set('ping', '') }
    end
  end

  it 'passes options to MemCache' do
    opts = {
      namespace: 'test:rack:session',
      compression_min_size: 1234
    }

    rsd = Rack::Session::Dalli.new(incrementor, opts)

    assert_equal(opts[:namespace], rsd.data.with { |c| c.instance_eval { @options[:namespace] } })
    assert_equal(opts[:compression_min_size], rsd.data.with { |c| c.instance_eval { @options[:compression_min_size] } })
  end

  it 'rejects a :cache option' do
    server = Rack::Session::Dalli::DEFAULT_DALLI_OPTIONS[:memcache_server]
    cache = Dalli::Client.new(server, namespace: 'test:rack:session')
    assert_raises RuntimeError do
      Rack::Session::Dalli.new(incrementor, cache: cache, namespace: 'foobar')
    end
  end

  it 'generates sids without an existing Dalli::Client' do
    rsd = Rack::Session::Dalli.new(incrementor)

    assert rsd.send :generate_sid
  end

  it 'upgrades to a connection pool' do
    opts = {
      namespace: 'test:rack:session',
      pool_size: 10
    }

    with_connectionpool do
      rsd = Rack::Session::Dalli.new(incrementor, opts)

      assert_equal 10, rsd.data.available
      rsd.data.with do |mc|
        assert_equal(opts[:namespace], mc.instance_eval { @options[:namespace] })
      end
    end
  end

  it 'creates a new cookie' do
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd).get('/')

    assert_includes res['Set-Cookie'], "#{session_key}="
    assert_equal res.body, { 'counter' => 1 }.to_s
  end

  it 'determines session from a cookie' do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    res = req.get('/')
    cookie = res['Set-Cookie']

    assert_equal req.get('/', 'HTTP_COOKIE' => cookie).body, { 'counter' => 2 }.to_s
    assert_equal req.get('/', 'HTTP_COOKIE' => cookie).body, { 'counter' => 3 }.to_s
  end

  it 'determines session only from a cookie by default' do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    res = req.get('/')
    sid = res['Set-Cookie'][session_match, 1]

    assert_equal req.get("/?rack.session=#{sid}").body, { 'counter' => 1 }.to_s
    assert_equal req.get("/?rack.session=#{sid}").body, { 'counter' => 1 }.to_s
  end

  it 'determines session from params' do
    rsd = Rack::Session::Dalli.new(incrementor, cookie_only: false)
    req = Rack::MockRequest.new(rsd)
    res = req.get('/')
    sid = res['Set-Cookie'][session_match, 1]

    assert_equal req.get("/?rack.session=#{sid}").body, { 'counter' => 2 }.to_s
    assert_equal req.get("/?rack.session=#{sid}").body, { 'counter' => 3 }.to_s
  end

  it 'survives nonexistant cookies' do
    bad_cookie = 'rack.session=blarghfasel'
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd)
                           .get('/', 'HTTP_COOKIE' => bad_cookie)

    assert_equal res.body, { 'counter' => 1 }.to_s
    cookie = res['Set-Cookie'][session_match]

    refute_match(/#{bad_cookie}/, cookie)
  end

  it 'survives nonexistant blank cookies' do
    bad_cookie = 'rack.session='
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd)
                           .get('/', 'HTTP_COOKIE' => bad_cookie)
    cookie = res['Set-Cookie'][session_match]

    refute_match(/#{bad_cookie}$/, cookie)
  end

  it 'sets an expiration on new sessions' do
    rsd = Rack::Session::Dalli.new(incrementor, expire_after: 3)
    res = Rack::MockRequest.new(rsd).get('/')

    assert_includes res.body, { 'counter' => 1 }.to_s
    cookie = res['Set-Cookie']
    puts 'Sleeping to expire session' if $DEBUG
    sleep 4
    res = Rack::MockRequest.new(rsd).get('/', 'HTTP_COOKIE' => cookie)

    refute_equal cookie, res['Set-Cookie']
    assert_includes res.body, { 'counter' => 1 }.to_s
  end

  it 'maintains freshness of existing sessions' do
    rsd = Rack::Session::Dalli.new(incrementor, expire_after: 3)
    res = Rack::MockRequest.new(rsd).get('/')

    assert_includes res.body, { 'counter' => 1 }.to_s
    cookie = res['Set-Cookie']
    res = Rack::MockRequest.new(rsd).get('/', 'HTTP_COOKIE' => cookie)

    assert_equal cookie, res['Set-Cookie']
    assert_includes res.body, { 'counter' => 2 }.to_s
    puts 'Sleeping to expire session' if $DEBUG
    sleep 4
    res = Rack::MockRequest.new(rsd).get('/', 'HTTP_COOKIE' => cookie)

    refute_equal cookie, res['Set-Cookie']
    assert_includes res.body, { 'counter' => 1 }.to_s
  end

  it 'does not send the same session id if it did not change' do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)

    res0 = req.get('/')
    cookie = res0['Set-Cookie'][session_match]

    assert_equal res0.body, { 'counter' => 1 }.to_s

    res1 = req.get('/', 'HTTP_COOKIE' => cookie)

    assert_nil res1['Set-Cookie']
    assert_equal res1.body, { 'counter' => 2 }.to_s

    res2 = req.get('/', 'HTTP_COOKIE' => cookie)

    assert_nil res2['Set-Cookie']
    assert_equal res2.body, { 'counter' => 3 }.to_s
  end

  it 'deletes cookies with :drop option' do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    drop = Rack::Utils::Context.new(rsd, drop_session)
    dreq = Rack::MockRequest.new(drop)

    res1 = req.get('/')
    session = (cookie = res1['Set-Cookie'])[session_match]

    assert_equal res1.body, { 'counter' => 1 }.to_s

    res2 = dreq.get('/', 'HTTP_COOKIE' => cookie)

    assert_nil res2['Set-Cookie']
    assert_equal res2.body, { 'counter' => 2 }.to_s

    res3 = req.get('/', 'HTTP_COOKIE' => cookie)

    refute_equal session, res3['Set-Cookie'][session_match]
    assert_equal res3.body, { 'counter' => 1 }.to_s
  end

  it 'provides new session id with :renew option' do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    renew = Rack::Utils::Context.new(rsd, renew_session)
    rreq = Rack::MockRequest.new(renew)

    res1 = req.get('/')
    session = (cookie = res1['Set-Cookie'])[session_match]

    assert_equal res1.body, { 'counter' => 1 }.to_s

    res2 = rreq.get('/', 'HTTP_COOKIE' => cookie)
    new_cookie = res2['Set-Cookie']
    new_session = new_cookie[session_match]

    refute_equal session, new_session
    assert_equal res2.body, { 'counter' => 2 }.to_s

    res3 = req.get('/', 'HTTP_COOKIE' => new_cookie)

    assert_equal res3.body, { 'counter' => 3 }.to_s

    # Old cookie was deleted
    res4 = req.get('/', 'HTTP_COOKIE' => cookie)

    assert_equal res4.body, { 'counter' => 1 }.to_s
  end

  it 'omits cookie with :defer option but still updates the state' do
    rsd = Rack::Session::Dalli.new(incrementor)
    count = Rack::Utils::Context.new(rsd, incrementor)
    defer = Rack::Utils::Context.new(rsd, defer_session)
    dreq = Rack::MockRequest.new(defer)
    creq = Rack::MockRequest.new(count)

    res0 = dreq.get('/')

    assert_nil res0['Set-Cookie']
    assert_equal res0.body, { 'counter' => 1 }.to_s

    res0 = creq.get('/')
    res1 = dreq.get('/', 'HTTP_COOKIE' => res0['Set-Cookie'])

    assert_equal res1.body, { 'counter' => 2 }.to_s
    res2 = dreq.get('/', 'HTTP_COOKIE' => res0['Set-Cookie'])

    assert_equal res2.body, { 'counter' => 3 }.to_s
  end

  it 'omits cookie and state update with :skip option' do
    rsd = Rack::Session::Dalli.new(incrementor)
    count = Rack::Utils::Context.new(rsd, incrementor)
    skip = Rack::Utils::Context.new(rsd, skip_session)
    sreq = Rack::MockRequest.new(skip)
    creq = Rack::MockRequest.new(count)

    res0 = sreq.get('/')

    assert_nil res0['Set-Cookie']
    assert_equal res0.body, { 'counter' => 1 }.to_s

    res0 = creq.get('/')
    res1 = sreq.get('/', 'HTTP_COOKIE' => res0['Set-Cookie'])

    assert_equal res1.body, { 'counter' => 2 }.to_s
    res2 = sreq.get('/', 'HTTP_COOKIE' => res0['Set-Cookie'])

    assert_equal res2.body, { 'counter' => 2 }.to_s
  end

  it 'updates deep hashes correctly' do
    hash_check = proc do |env|
      session = env['rack.session']
      if session.include? 'test'
        session[:f][:g][:h] = :j
      else
        session.update :a => :b, :c => { d: :e },
                       :f => { g: { h: :i } }, 'test' => true
      end
      [200, {}, [session.to_h.to_json]]
    end
    rsd = Rack::Session::Dalli.new(hash_check)
    req = Rack::MockRequest.new(rsd)

    res0 = req.get('/')
    cookie = res0['Set-Cookie']
    ses0 = JSON.parse(res0.body)

    refute_nil ses0
    h = { 'a' => 'b', 'c' => { 'd' => 'e' }, 'f' => { 'g' => { 'h' => 'i' } }, 'test' => true }

    assert_equal h.to_s, ses0.to_s

    res1 = req.get('/', 'HTTP_COOKIE' => cookie)
    ses1 = JSON.parse(res1.body)

    refute_nil ses1
    h = { 'a' => 'b', 'c' => { 'd' => 'e' }, 'f' => { 'g' => { 'h' => 'j' } }, 'test' => true }

    assert_equal h.to_s, ses1.to_s

    refute_equal ses0, ses1
  end

  it "doesn't allow session id to be reused" do
    rsd = Rack::Session::Dalli.new(user_id_session)

    login_response = Rack::MockRequest.new(rsd).get('/login')
    login_cookie = login_response['Set-Cookie']

    slow_request = Fiber.new do
      Rack::MockRequest.new(rsd).get('/slow', 'HTTP_COOKIE' => login_cookie)
    end
    slow_request.resume

    # Check that the session is valid:
    response = Rack::MockRequest.new(rsd).get('/', 'HTTP_COOKIE' => login_cookie)

    assert_equal response.body, { 'user_id' => 1 }.to_s

    logout_response = Rack::MockRequest.new(rsd).get('/logout', 'HTTP_COOKIE' => login_cookie)
    logout_cookie = logout_response['Set-Cookie']

    # Check that the session id is different after logout:
    refute_equal login_cookie[session_match], logout_cookie[session_match]

    slow_response = slow_request.resume

    assert_equal 401, slow_response.status
    assert_equal 'Wrong session ID', slow_response.body

    # Check that the cookie can't be reused:
    response = Rack::MockRequest.new(rsd).get('/', 'HTTP_COOKIE' => login_cookie)

    assert_equal '{}', response.body
  end
end
