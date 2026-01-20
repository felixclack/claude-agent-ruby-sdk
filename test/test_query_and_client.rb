# frozen_string_literal: true

require_relative "test_helper"

class TestQueryAndClient < Minitest::Test
  def build_messages
    [
      {
        "type" => "assistant",
        "message" => { "model" => "claude", "content" => [{ "type" => "text", "text" => "Hello" }] },
      },
      {
        "type" => "result",
        "subtype" => "success",
        "duration_ms" => 1,
        "duration_api_ms" => 1,
        "is_error" => false,
        "num_turns" => 1,
        "session_id" => "s1",
      },
    ]
  end

  def test_query_helper
    transport = FakeTransport.new(messages: build_messages)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new

    messages = ClaudeAgentSDK.query(prompt: "hi", options: options, transport: transport).to_a
    assert_equal 2, messages.size
  end

  def test_query_helper_with_block
    transport = FakeTransport.new(messages: build_messages)
    options = ClaudeAgentSDK::ClaudeAgentOptions.new
    collected = []

    ClaudeAgentSDK.query(prompt: "hi", options: options, transport: transport) do |message|
      collected << message
    end

    assert_equal 2, collected.size
  end

  def test_client_connect_and_query
    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      if request["type"] == "control_request"
        fake.push_message({
          "type" => "control_response",
          "response" => {
            "subtype" => "success",
            "request_id" => request["request_id"],
            "response" => { "commands" => [] },
          },
        })
      end
    end

    client = ClaudeAgentSDK::ClaudeSDKClient.new(transport: transport)
    client.connect

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    client.query("Hello")
    assert_includes transport.writes.last, "Hello"

    response = client.receive_response.to_a
    assert_equal 2, response.size
    assert_instance_of ClaudeAgentSDK::ResultMessage, response.last
    assert_equal({ "commands" => [] }, client.get_server_info)
  ensure
    client.disconnect if client
  end

  def test_client_control_methods
    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      next unless request["type"] == "control_request"

      fake.push_message({
        "type" => "control_response",
        "response" => {
          "subtype" => "success",
          "request_id" => request["request_id"],
          "response" => {},
        },
      })
    end

    client = ClaudeAgentSDK::ClaudeSDKClient.new(transport: transport)
    client.connect

    client.set_permission_mode("default")
    client.set_model("model")
    client.rewind_files("uuid")
    client.interrupt

    transport.finish

    control_writes = transport.writes.map { |entry| JSON.parse(entry) }.select { |msg| msg["type"] == "control_request" }
    subtypes = control_writes.map { |msg| msg.dig("request", "subtype") }

    assert_includes subtypes, "set_permission_mode"
    assert_includes subtypes, "set_model"
    assert_includes subtypes, "rewind_files"
    assert_includes subtypes, "interrupt"
  ensure
    client.disconnect if client
  end

  def test_client_errors_when_not_connected
    client = ClaudeAgentSDK::ClaudeSDKClient.new

    assert_raises(ClaudeAgentSDK::CLIConnectionError) { client.query("Hi") }
    assert_raises(ClaudeAgentSDK::CLIConnectionError) { client.receive_messages.to_a }
  end

  def test_client_connect_requires_streaming_for_can_use_tool
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(can_use_tool: ->(_n, _i, _c) { nil })
    client = ClaudeAgentSDK::ClaudeSDKClient.new(options: options)

    error = assert_raises(ArgumentError) do
      client.connect(prompt: "hi")
    end
    assert_includes error.message, "streaming"
  end

  def test_client_connect_requires_permission_prompt_tool_name_exclusive
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(
      can_use_tool: ->(_n, _i, _c) { nil },
      permission_prompt_tool_name: "stdio",
    )
    client = ClaudeAgentSDK::ClaudeSDKClient.new(options: options)

    error = assert_raises(ArgumentError) do
      client.connect(prompt: [])
    end
    assert_includes error.message, "permission_prompt_tool_name"
  end

  def test_client_with_block
    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      if request["type"] == "control_request"
        fake.push_message({
          "type" => "control_response",
          "response" => {
            "subtype" => "success",
            "request_id" => request["request_id"],
            "response" => { "commands" => [] },
          },
        })
      end
    end

    client = ClaudeAgentSDK::ClaudeSDKClient.new(transport: transport)
    client.with do |instance|
      assert_same client, instance
      transport.finish
    end

    assert transport.closed
  end
end
