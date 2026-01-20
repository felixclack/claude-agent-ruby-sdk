# frozen_string_literal: true

require_relative "test_helper"

class TestTransportBase < Minitest::Test
  def test_transport_abstract_methods
    transport = ClaudeAgentSDK::Transport.new

    assert_raises(NotImplementedError) { transport.connect }
    assert_raises(NotImplementedError) { transport.write("x") }
    assert_raises(NotImplementedError) { transport.read_messages }
    assert_raises(NotImplementedError) { transport.close }
    assert_raises(NotImplementedError) { transport.ready? }
    assert_raises(NotImplementedError) { transport.is_ready }
    assert_raises(NotImplementedError) { transport.end_input }
  end
end
