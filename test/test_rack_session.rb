require 'helper'

require 'rack/session/dalli'
require 'rack/lint'
require 'rack/mock'
require 'thread'

describe Rack::Session::Dalli do
  Rack::Session::Dalli::DEFAULT_OPTIONS[:memcache_server] = 'localhost:19129'

  before do
    memcached(19129) do
    end

    # test memcache connection
    Rack::Session::Dalli.new(incrementor)
  end

  let(:session_key) { Rack::Session::Dalli::DEFAULT_OPTIONS[:key] }
  let(:session_match) do
    /#{session_key}=([0-9a-fA-F]+);/
  end
  let(:incrementor_proc) do
    lambda do |env|
      env["rack.session"]["counter"] ||= 0
      env["rack.session"]["counter"] += 1
      Rack::Response.new(env["rack.session"].inspect).to_a
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
  let(:incrementor) { Rack::Lint.new(incrementor_proc) }

  it "faults on no connection" do
    assert_raises Dalli::RingError do
      Rack::Session::Dalli.new(incrementor, :memcache_server => 'nosuchserver')
    end
  end

  it "connects to existing server" do
    assert_silent do
      rsd = Rack::Session::Dalli.new(incrementor, :namespace => 'test:rack:session')
      rsd.pool.set('ping', '')
    end
  end

  it "passes options to MemCache" do
    rsd = Rack::Session::Dalli.new(incrementor, :namespace => 'test:rack:session')
    assert_equal('test:rack:session', rsd.pool.instance_eval { @options[:namespace] })
  end

  it "creates a new cookie" do
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd).get("/")
    assert res["Set-Cookie"].include?("#{session_key}=")
    assert_equal '{"counter"=>1}', res.body
  end

  it "determines session from a cookie" do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    res = req.get("/")
    cookie = res["Set-Cookie"]
    assert_equal '{"counter"=>2}', req.get("/", "HTTP_COOKIE" => cookie).body
    assert_equal '{"counter"=>3}', req.get("/", "HTTP_COOKIE" => cookie).body
  end

  it "determines session only from a cookie by default" do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    res = req.get("/")
    sid = res["Set-Cookie"][session_match, 1]
    assert_equal '{"counter"=>1}', req.get("/?rack.session=#{sid}").body
    assert_equal '{"counter"=>1}', req.get("/?rack.session=#{sid}").body
  end

  it "determines session from params" do
    rsd = Rack::Session::Dalli.new(incrementor, :cookie_only => false)
    req = Rack::MockRequest.new(rsd)
    res = req.get("/")
    sid = res["Set-Cookie"][session_match, 1]
    assert_equal '{"counter"=>2}', req.get("/?rack.session=#{sid}").body
    assert_equal '{"counter"=>3}', req.get("/?rack.session=#{sid}").body
  end

  it "survives nonexistant cookies" do
    bad_cookie = "rack.session=blarghfasel"
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd).
      get("/", "HTTP_COOKIE" => bad_cookie)
    assert_equal '{"counter"=>1}', res.body
    cookie = res["Set-Cookie"][session_match]
    refute_match(/#{bad_cookie}/, cookie)
  end

  it "survives nonexistant blank cookies" do
    bad_cookie = "rack.session="
    rsd = Rack::Session::Dalli.new(incrementor)
    res = Rack::MockRequest.new(rsd).
      get("/", "HTTP_COOKIE" => bad_cookie)
    cookie = res["Set-Cookie"][session_match]
    refute_match(/#{bad_cookie}$/, cookie)
  end

  it "maintains freshness" do
    rsd = Rack::Session::Dalli.new(incrementor, :expire_after => 3)
    res = Rack::MockRequest.new(rsd).get('/')
    assert res.body.include?('"counter"=>1')
    cookie = res["Set-Cookie"]
    res = Rack::MockRequest.new(rsd).get('/', "HTTP_COOKIE" => cookie)
    assert_equal cookie, res["Set-Cookie"]
    assert res.body.include?('"counter"=>2')
    puts 'Sleeping to expire session' if $DEBUG
    sleep 4
    res = Rack::MockRequest.new(rsd).get('/', "HTTP_COOKIE" => cookie)
    refute_equal cookie, res["Set-Cookie"]
    assert res.body.include?('"counter"=>1')
  end

  it "does not send the same session id if it did not change" do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)

    res0 = req.get("/")
    cookie = res0["Set-Cookie"][session_match]
    assert_equal '{"counter"=>1}', res0.body

    res1 = req.get("/", "HTTP_COOKIE" => cookie)
    assert_nil res1["Set-Cookie"]
    assert_equal '{"counter"=>2}', res1.body

    res2 = req.get("/", "HTTP_COOKIE" => cookie)
    assert_nil res2["Set-Cookie"]
    assert_equal '{"counter"=>3}', res2.body
  end

  it "deletes cookies with :drop option" do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    drop = Rack::Utils::Context.new(rsd, drop_session)
    dreq = Rack::MockRequest.new(drop)

    res1 = req.get("/")
    session = (cookie = res1["Set-Cookie"])[session_match]
    assert_equal '{"counter"=>1}', res1.body

    res2 = dreq.get("/", "HTTP_COOKIE" => cookie)
    assert_nil res2["Set-Cookie"]
    assert_equal '{"counter"=>2}', res2.body

    res3 = req.get("/", "HTTP_COOKIE" => cookie)
    refute_equal session, res3["Set-Cookie"][session_match]
    assert_equal '{"counter"=>1}', res3.body
  end

  it "provides new session id with :renew option" do
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)
    renew = Rack::Utils::Context.new(rsd, renew_session)
    rreq = Rack::MockRequest.new(renew)

    res1 = req.get("/")
    session = (cookie = res1["Set-Cookie"])[session_match]
    assert_equal '{"counter"=>1}', res1.body

    res2 = rreq.get("/", "HTTP_COOKIE" => cookie)
    new_cookie = res2["Set-Cookie"]
    new_session = new_cookie[session_match]
    refute_equal session, new_session
    assert_equal '{"counter"=>2}', res2.body

    res3 = req.get("/", "HTTP_COOKIE" => new_cookie)
    assert_equal '{"counter"=>3}', res3.body

    # Old cookie was deleted
    res4 = req.get("/", "HTTP_COOKIE" => cookie)
    assert_equal '{"counter"=>1}', res4.body
  end

  it "omits cookie with :defer option but still updates the state" do
    rsd = Rack::Session::Dalli.new(incrementor)
    count = Rack::Utils::Context.new(rsd, incrementor)
    defer = Rack::Utils::Context.new(rsd, defer_session)
    dreq = Rack::MockRequest.new(defer)
    creq = Rack::MockRequest.new(count)

    res0 = dreq.get("/")
    assert_nil res0["Set-Cookie"]
    assert_equal '{"counter"=>1}', res0.body

    res0 = creq.get("/")
    res1 = dreq.get("/", "HTTP_COOKIE" => res0["Set-Cookie"])
    assert_equal '{"counter"=>2}', res1.body
    res2 = dreq.get("/", "HTTP_COOKIE" => res0["Set-Cookie"])
    assert_equal '{"counter"=>3}', res2.body
  end

  it "omits cookie and state update with :skip option" do
    rsd = Rack::Session::Dalli.new(incrementor)
    count = Rack::Utils::Context.new(rsd, incrementor)
    skip = Rack::Utils::Context.new(rsd, skip_session)
    sreq = Rack::MockRequest.new(skip)
    creq = Rack::MockRequest.new(count)

    res0 = sreq.get("/")
    assert_nil res0["Set-Cookie"]
    assert_equal '{"counter"=>1}', res0.body

    res0 = creq.get("/")
    res1 = sreq.get("/", "HTTP_COOKIE" => res0["Set-Cookie"])
    assert_equal '{"counter"=>2}', res1.body
    res2 = sreq.get("/", "HTTP_COOKIE" => res0["Set-Cookie"])
    assert_equal '{"counter"=>2}', res2.body
  end

  it "updates deep hashes correctly" do
    hash_check = proc do |env|
      session = env['rack.session']
      unless session.include? 'test'
        session.update :a => :b, :c => { :d => :e },
          :f => { :g => { :h => :i} }, 'test' => true
      else
        session[:f][:g][:h] = :j
      end
      [200, {}, [session.inspect]]
    end
    rsd = Rack::Session::Dalli.new(hash_check)
    req = Rack::MockRequest.new(rsd)

    res0 = req.get("/")
    session_id = (cookie = res0["Set-Cookie"])[session_match, 1]
    ses0 = rsd.pool.get(session_id, true)

    req.get("/", "HTTP_COOKIE" => cookie)
    ses1 = rsd.pool.get(session_id, true)

    refute_equal ses0, ses1
  end

  # anyone know how to do this better?
  it "cleanly merges sessions when multithreaded" do
    unless $DEBUG
      assert_equal 1, 1 # fake assertion to appease the mighty bacon
      next
    end
    warn 'Running multithread test for Session::Dalli'
    rsd = Rack::Session::Dalli.new(incrementor)
    req = Rack::MockRequest.new(rsd)

    res = req.get('/')
    assert_equal '{"counter"=>1}', res.body
    cookie = res["Set-Cookie"]
    session_id = cookie[session_match, 1]

    delta_incrementor = lambda do |env|
      # emulate disconjoinment of threading
      env['rack.session'] = env['rack.session'].dup
      Thread.stop
      env['rack.session'][(Time.now.usec*rand).to_i] = true
      incrementor.call(env)
    end
    tses = Rack::Utils::Context.new rsd, delta_incrementor
    treq = Rack::MockRequest.new(tses)
    tnum = rand(7).to_i+5
    r = Array.new(tnum) do
      Thread.new(treq) do |run|
        run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
      end
    end.reverse.map{|t| t.run.join.value }
    r.each do |request|
      assert_equal cookie, request['Set-Cookie']
      assert request.body.include?('"counter"=>2')
    end

    session = rsd.pool.get(session_id)
    assert_equal tnum+1, session.size  # counter
    assert_equal 2, session['counter'] # meeeh

    tnum = rand(7).to_i+5
    r = Array.new(tnum) do |i|
      app = Rack::Utils::Context.new rsd, time_delta
      req = Rack::MockRequest.new app
      Thread.new(req) do |run|
        run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
      end
    end.reverse.map{|t| t.run.join.value }
    r.each do |request|
      assert_equal cookie, request['Set-Cookie']
      assert request.body.include?('"counter"=>3')
    end

    session = rsd.pool.get(session_id)
    assert_equal tnum+1, session.size
    assert_equal 3, session['counter']

    drop_counter = proc do |env|
      env['rack.session'].delete 'counter'
      env['rack.session']['foo'] = 'bar'
      [200, {'Content-Type'=>'text/plain'}, env['rack.session'].inspect]
    end
    tses = Rack::Utils::Context.new rsd, drop_counter
    treq = Rack::MockRequest.new(tses)
    tnum = rand(7).to_i+5
    r = Array.new(tnum) do
      Thread.new(treq) do |run|
        run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
      end
    end.reverse.map{|t| t.run.join.value }
    r.each do |request|
      assert_equal cookie, request['Set-Cookie']
      assert request.body.include?('"foo"=>"bar"')
    end

    session = rsd.pool.get(session_id)
    assert_equal r.size+1, session.size
    assert_nil session['counter']
    assert_equal 'bar', session['foo']
  end
end
