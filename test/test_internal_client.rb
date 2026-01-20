# frozen_string_literal: true

require_relative "test_helper"

class TestInternalClient < Minitest::Test
  def build_messages
    [
      {
        "type" => "assistant",
        "message" => { "model" => "claude", "content" => [{ "type" => "text", "text" => "Hi" }] },
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

  def test_process_query_requires_streaming_for_can_use_tool
    options = ClaudeAgentSDK::Options.new(can_use_tool: ->(_n, _i, _c) { nil })
    client = ClaudeAgentSDK::Internal::Client.new

    error = assert_raises(ArgumentError) do
      client.process_query(prompt: "hi", options: options)
    end
    assert_includes error.message, "streaming"
  end

  def test_process_query_requires_permission_prompt_tool_name_exclusive
    options = ClaudeAgentSDK::Options.new(
      can_use_tool: ->(_n, _i, _c) { nil },
      permission_prompt_tool_name: "stdio",
    )
    client = ClaudeAgentSDK::Internal::Client.new

    error = assert_raises(ArgumentError) do
      client.process_query(prompt: [], options: options)
    end
    assert_includes error.message, "permission_prompt_tool_name"
  end

  def test_process_query_with_string_prompt
    transport = FakeTransport.new(messages: build_messages)
    options = ClaudeAgentSDK::Options.new

    client = ClaudeAgentSDK::Internal::Client.new
    messages = client.process_query(prompt: "hi", options: options, transport: transport).to_a

    assert_equal 2, messages.size
    assert_instance_of ClaudeAgentSDK::AssistantMessage, messages.first
    assert_instance_of ClaudeAgentSDK::ResultMessage, messages.last
  end

  def test_process_query_with_streaming_prompt
    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      if request["type"] == "control_request" && request.dig("request", "subtype") == "initialize"
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

    options = ClaudeAgentSDK::Options.new
    prompt = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } },
    ]

    client = ClaudeAgentSDK::Internal::Client.new
    enumerator = client.process_query(prompt: prompt, options: options, transport: transport)

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    messages = enumerator.to_a

    assert_equal 2, messages.size
    assert transport.ended
  end

  def test_process_query_with_can_use_tool_and_sdk_mcp
    tool = ClaudeAgentSDK.tool("noop", "Noop", { "x" => String }) { |_args| { "content" => [] } }
    sdk_server = ClaudeAgentSDK.create_sdk_mcp_server(name: "tools", tools: [tool])

    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      if request["type"] == "control_request" && request.dig("request", "subtype") == "initialize"
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
    prompt = [{ "type" => "user", "message" => { "role" => "user", "content" => "Hello" } }]

    client = ClaudeAgentSDK::Internal::Client.new
    enumerator = client.process_query(prompt: prompt, options: options, transport: transport)

    build_messages.each { |msg| transport.push_message(msg) }
    transport.finish

    assert_equal 2, enumerator.to_a.size
  end
end
