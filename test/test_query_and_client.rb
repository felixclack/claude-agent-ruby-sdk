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
    options = ClaudeAgentSDK::Options.new

    messages = ClaudeAgentSDK.query("hi", options: options, transport: transport).to_a
    assert_equal 2, messages.size
  end

  def test_query_helper_with_block
    transport = FakeTransport.new(messages: build_messages)
    options = ClaudeAgentSDK::Options.new
    collected = []

    ClaudeAgentSDK.query(prompt: "hi", options: options, transport: transport) do |message|
      collected << message
    end

    assert_equal 2, collected.size
  end

  def test_query_helper_requires_prompt
    assert_raises(ArgumentError) { ClaudeAgentSDK.query(nil) }
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

    client = ClaudeAgentSDK::Client.new(transport: transport)
    client.connect

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    client.query("Hello")
    assert_includes transport.writes.last, "Hello"

    response = client.each_response.to_a
    assert_equal 2, response.size
    assert_instance_of ClaudeAgentSDK::ResultMessage, response.last
    assert_equal({ "commands" => [] }, client.get_server_info)
    assert_equal true, client.connected?
    client.close
    assert_equal false, client.connected?
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

    client = ClaudeAgentSDK::Client.new(transport: transport)
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
    client = ClaudeAgentSDK::Client.new

    assert_raises(ClaudeAgentSDK::CLIConnectionError) { client.query("Hi") }
    assert_raises(ClaudeAgentSDK::CLIConnectionError) { client.receive_messages.to_a }
    assert_raises(ClaudeAgentSDK::CLIConnectionError) { client.each_message.to_a }
  end

  def test_client_connect_requires_streaming_for_can_use_tool
    options = ClaudeAgentSDK::Options.new(can_use_tool: ->(_n, _i, _c) { nil })
    client = ClaudeAgentSDK::Client.new(options: options)

    error = assert_raises(ArgumentError) do
      client.connect(prompt: "hi")
    end
    assert_includes error.message, "streaming"
  end

  def test_client_connect_requires_permission_prompt_tool_name_exclusive
    options = ClaudeAgentSDK::Options.new(
      can_use_tool: ->(_n, _i, _c) { nil },
      permission_prompt_tool_name: "stdio",
    )
    client = ClaudeAgentSDK::Client.new(options: options)

    error = assert_raises(ArgumentError) do
      client.connect(prompt: [])
    end
    assert_includes error.message, "permission_prompt_tool_name"
  end

  def test_client_open_block
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

    client = ClaudeAgentSDK::Client.new(transport: transport)
    client.open do |instance|
      assert_same client, instance
      transport.finish
    end

    assert transport.closed
  end

  def test_client_with_alias
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

    client = ClaudeAgentSDK::Client.new(transport: transport)
    client.with do |instance|
      assert_same client, instance
      transport.finish
    end

    assert transport.closed
  end

  def test_client_aliases_and_enumerators
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

    client = ClaudeAgentSDK::Client.new(transport: transport)
    client.connect

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    client.ask("Hello")
    client.send_message("Hello again")

    assert_kind_of Enumerator, client.messages
    assert_kind_of Enumerator, client.responses

    assert_equal 2, client.each_message.to_a.size
  ensure
    client.disconnect if client
  end

  def test_client_streaming_prompt_and_blocks
    tool = ClaudeAgentSDK.tool("noop", "Noop", { "x" => String }) { |_args| { "content" => [] } }
    sdk_server = ClaudeAgentSDK.create_sdk_mcp_server(name: "tools", tools: [tool])

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

    options = ClaudeAgentSDK::Options.new(
      can_use_tool: ->(_n, _i, _c) { ClaudeAgentSDK::PermissionResultAllow.new },
      mcp_servers: { "tools" => sdk_server },
    )

    prompt = [{ "type" => "user", "message" => { "role" => "user", "content" => "Ping" } }]
    client = ClaudeAgentSDK::Client.new(options: options, transport: transport)
    client.connect(prompt: prompt)

    streamed_prompt = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Followup" } },
    ]
    client.query(streamed_prompt)

    sleep 0.01
    assert transport.writes.any? { |entry| entry.include?("\"type\":\"user\"") }

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    seen = []
    client.each_message { |msg| seen << msg }
    assert_equal 2, seen.size

    client.disconnect

    transport2 = FakeTransport.new(auto_end: false) do |data, fake|
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

    client2 = ClaudeAgentSDK::Client.new(transport: transport2)
    client2.connect
    build_messages.each { |msg| transport2.push_message(msg) }
    transport2.finish

    response = []
    client2.each_response { |msg| response << msg }
    assert_equal 2, response.size
  ensure
    client.disconnect if client
    client2.disconnect if client2
  end

  def test_module_open_returns_client
    client = ClaudeAgentSDK.open
    assert_instance_of ClaudeAgentSDK::Client, client
  end

  def test_module_open_with_block
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

    ClaudeAgentSDK.open(transport: transport) do |client|
      assert client.connected?
      transport.finish
    end

    assert transport.closed
  end
end
