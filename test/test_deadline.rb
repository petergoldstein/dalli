# frozen_string_literal: true

require_relative 'helper'

describe Dalli::Deadline do
  it 'counts down the time left' do
    deadline = Dalli::Deadline.new(10)

    assert_operator deadline.remaining, :>, 9
    assert_operator deadline.remaining, :<=, 10
  end

  it 'clamps to the time left when that is shorter' do
    deadline = Dalli::Deadline.new(0.5)

    assert_in_delta 0.1, deadline.clamp(0.1)
    assert_operator deadline.clamp(5), :<=, 0.5
  end

  it 'raises once the deadline has passed' do
    deadline = Dalli::Deadline.new(0)

    assert_raises(Dalli::DeadlineExceededError) { deadline.clamp(1) }
  end

  # The same arguments as ActiveSupport::Deadline#clamp
  it 'takes minimum and error' do
    deadline = Dalli::Deadline.new(0.5)

    assert_raises(ArgumentError) { deadline.clamp(1, minimum: 1, error: ArgumentError) }
  end

  it 'rejects anything but a finite number of seconds' do
    [nil, '1', Float::NAN, Float::INFINITY].each do |seconds|
      assert_raises(ArgumentError) { Dalli::Deadline.new(seconds) }
    end
  end
end

describe 'Dalli::Client#with_deadline' do
  let(:client) { Dalli::Client.new('127.0.0.1:1') }

  def current_deadline(client)
    Thread.current[client.instance_variable_get(:@deadline_key)]
  end

  it "yields the client, returns the block's value and clears the deadline afterwards" do
    assert_equal :done, client.with_deadline(1) { |c|
      assert_same client, c
      :done
    }
    assert_nil current_deadline(client)
  end

  # ActiveSupport::Deadline#remaining returns infinity when there's no deadline
  it 'sets no deadline for Float::INFINITY, keeping an outer one' do
    assert_equal :done, client.with_deadline(Float::INFINITY) { |c|
      assert_same client, c
      assert_nil current_deadline(client)
      :done
    }

    client.with_deadline(1) do
      outer = current_deadline(client)

      client.with_deadline(Float::INFINITY) { assert_same outer, current_deadline(client) }
    end
  end

  it 'clears the deadline when the block raises' do
    assert_raises(RuntimeError) { client.with_deadline(1) { raise 'boom' } }
    assert_nil current_deadline(client)
  end

  it 'keeps the earlier deadline when nested' do
    client.with_deadline(0.5) do
      outer = current_deadline(client)

      client.with_deadline(10) { assert_same outer, current_deadline(client) }
      client.with_deadline(0.1) { assert_operator current_deadline(client).expires_at, :<, outer.expires_at }

      assert_same outer, current_deadline(client)
    end
  end

  it 'leaves an outer deadline alone when given an invalid one' do
    client.with_deadline(1) do
      outer = current_deadline(client)

      assert_raises(ArgumentError) { client.with_deadline(nil) { flunk } }
      assert_same outer, current_deadline(client)
    end
  end

  it 'applies only to the calling thread or fiber and to other clients not at all' do
    other = Dalli::Client.new('127.0.0.1:1')

    client.with_deadline(1) do
      refute_nil current_deadline(client)
      assert_nil current_deadline(other)
      assert_nil Thread.new { current_deadline(client) }.value
      assert_nil Fiber.new { current_deadline(client) }.resume
    end
  end
end
