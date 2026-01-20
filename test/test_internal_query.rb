# frozen_string_literal: true

require_relative "test_helper"

class TestInternalQuery < Minitest::Test
  def build_control_response(request_id, response: {})
    {
      "type" => "control_response",
      "response" => {
        "subtype" => "success",
        "request_id" => request_id,
        "response" => response,
      },
    }
  end

  def test_initialize_protocol_with_hooks
    hook = ->(_input, _tool_use_id, _context) { {} }
    matcher = ClaudeAgentSDK::HookMatcher.new(matcher: "Bash", hooks: [hook], timeout: 5)

    transport = FakeTransport.new(auto_end: false) do |data, fake|
      request = JSON.parse(data)
      if request["type"] == "control_request" && request.dig("request", "subtype") == "initialize"
        fake.push_message(build_control_response(request["request_id"], response: { "commands" => [] }))
      end
    end

    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
      hooks: { "PreToolUse" => [matcher] },
    )

    query.start
    response = query.initialize_protocol

    assert_equal({ "commands" => [] }, response)

    sent = JSON.parse(transport.writes.first)
    hooks = sent.dig("request", "hooks")
    assert hooks.key?("PreToolUse")
    assert_equal "Bash", hooks["PreToolUse"].first["matcher"]
  ensure
    transport.finish
    query.close
  end

  def test_build_hooks_config_with_hash
    hook = ->(_input, _tool_use_id, _context) { {} }

    query = ClaudeAgentSDK::Internal::Query.new(
      transport: FakeTransport.new,
      is_streaming_mode: true,
      hooks: {
        "PreToolUse" => [
          {
            "matcher" => "Write",
            "hooks" => [hook],
            "timeout" => 12,
          },
        ],
      },
    )

    config = query.send(:build_hooks_config)
    assert_equal "Write", config["PreToolUse"].first["matcher"]
    assert_equal 1, config["PreToolUse"].first["hookCallbackIds"].size
  end

  def test_handle_control_request_can_use_tool_allow
    permission = ClaudeAgentSDK::PermissionUpdate.new(type: "setMode", mode: "default")
    can_use_tool = lambda do |_name, _input, _context|
      ClaudeAgentSDK::PermissionResultAllow.new(updated_input: { "x" => 1 }, updated_permissions: [permission])
    end

    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
      can_use_tool: can_use_tool,
    )

    request = {
      "request_id" => "req1",
      "request" => {
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "input" => { "cmd" => "ls" },
        "permission_suggestions" => [],
      },
    }

    query.handle_control_request(request)
    response = JSON.parse(transport.writes.last)

    assert_equal "success", response.dig("response", "subtype")
    assert_equal "allow", response.dig("response", "response", "behavior")
    assert_equal({ "x" => 1 }, response.dig("response", "response", "updatedInput"))
    assert_equal "setMode", response.dig("response", "response", "updatedPermissions").first["type"]
  end

  def test_handle_control_request_can_use_tool_deny
    can_use_tool = lambda do |_name, _input, _context|
      ClaudeAgentSDK::PermissionResultDeny.new(message: "no", interrupt: true)
    end

    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
      can_use_tool: can_use_tool,
    )

    request = {
      "request_id" => "req2",
      "request" => {
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "input" => { "cmd" => "ls" },
        "permission_suggestions" => [],
      },
    }

    query.handle_control_request(request)
    response = JSON.parse(transport.writes.last)

    assert_equal "deny", response.dig("response", "response", "behavior")
    assert_equal "no", response.dig("response", "response", "message")
    assert_equal true, response.dig("response", "response", "interrupt")
  end

  def test_handle_control_request_hook_callback
    hook = lambda do |_input, _tool_use_id, _context|
      { "async_" => true, "continue_" => false }
    end

    query = ClaudeAgentSDK::Internal::Query.new(
      transport: FakeTransport.new,
      is_streaming_mode: true,
      hooks: { "PreToolUse" => [ClaudeAgentSDK::HookMatcher.new(matcher: "Bash", hooks: [hook])] },
    )

    query.send(:build_hooks_config)
    callback_id = query.instance_variable_get(:@hook_callbacks).keys.first

    request = {
      "request_id" => "req3",
      "request" => {
        "subtype" => "hook_callback",
        "callback_id" => callback_id,
        "input" => { "tool_name" => "Bash" },
        "tool_use_id" => nil,
      },
    }

    query.handle_control_request(request)
    response = JSON.parse(query.instance_variable_get(:@transport).writes.last)

    assert_equal true, response.dig("response", "response", "async")
    assert_equal false, response.dig("response", "response", "continue")
  end

  def test_handle_control_request_mcp_message
    tool = ClaudeAgentSDK.tool("add", "Add", { "a" => Integer, "b" => Integer }) do |args|
      { "content" => [{ "type" => "text", "text" => (args["a"] + args["b"]).to_s }] }
    end
    server = ClaudeAgentSDK::SdkMcpServer.new("calc", tools: [tool])

    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
      sdk_mcp_servers: { "calc" => server },
    )

    request = {
      "request_id" => "req4",
      "request" => {
        "subtype" => "mcp_message",
        "server_name" => "calc",
        "message" => { "method" => "tools/list", "id" => 1 },
      },
    }

    query.handle_control_request(request)
    response = JSON.parse(transport.writes.last)
    tools = response.dig("response", "response", "mcp_response", "result", "tools")
    assert_equal "add", tools.first["name"]
  end

  def test_handle_control_request_missing_can_use_tool
    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
    )

    request = {
      "request_id" => "req5",
      "request" => {
        "subtype" => "can_use_tool",
        "tool_name" => "Bash",
        "input" => { "cmd" => "ls" },
        "permission_suggestions" => [],
      },
    }

    query.handle_control_request(request)
    response = JSON.parse(transport.writes.last)
    assert_equal "error", response.dig("response", "subtype")
  end

  def test_handle_sdk_mcp_request_variants
    tool = ClaudeAgentSDK.tool("echo", "Echo", { "text" => String }) do |args|
      { "content" => [{ "type" => "text", "text" => args["text"] }] }
    end
    server = ClaudeAgentSDK::SdkMcpServer.new("echo", tools: [tool])
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: FakeTransport.new,
      is_streaming_mode: true,
      sdk_mcp_servers: { "echo" => server },
    )

    not_found = query.handle_sdk_mcp_request("missing", { "id" => 1, "method" => "tools/list" })
    assert_equal -32_601, not_found.dig("error", "code")

    init = query.handle_sdk_mcp_request("echo", { "id" => 2, "method" => "initialize" })
    assert_equal "echo", init.dig("result", "serverInfo", "name")

    list = query.handle_sdk_mcp_request("echo", { "id" => 3, "method" => "tools/list" })
    assert_equal "echo", list.dig("result", "tools").first["name"]

    call = query.handle_sdk_mcp_request(
      "echo",
      { "id" => 4, "method" => "tools/call", "params" => { "name" => "echo", "arguments" => { "text" => "hi" } } },
    )
    assert_equal "hi", call.dig("result", "content").first["text"]

    notif = query.handle_sdk_mcp_request("echo", { "method" => "notifications/initialized" })
    assert_equal({}, notif["result"])

    missing = query.handle_sdk_mcp_request("echo", { "id" => 6, "method" => "unknown" })
    assert_equal -32_601, missing.dig("error", "code")
  end

  def test_send_control_request_requires_streaming
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: FakeTransport.new,
      is_streaming_mode: false,
    )

    error = assert_raises(StandardError) do
      query.send_control_request({ "subtype" => "interrupt" })
    end
    assert_includes error.message, "streaming"
  end

  def test_stream_input_ends_input
    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
    )

    stream = [
      { "type" => "user", "message" => { "role" => "user", "content" => "Hi" } },
      { "type" => "user", "message" => { "role" => "user", "content" => "There" } },
    ]

    query.stream_input(stream)

    assert transport.ended
    assert_equal 2, transport.writes.size
  end

  def test_receive_messages_raises_on_error
    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
    )

    queue = query.instance_variable_get(:@message_queue)
    queue << StandardError.new("boom")
    queue << :end

    assert_raises(StandardError) do
      query.receive_messages.each { |_| }
    end
  end

  def test_close_calls_transport
    transport = FakeTransport.new
    query = ClaudeAgentSDK::Internal::Query.new(
      transport: transport,
      is_streaming_mode: true,
    )

    query.close
    assert transport.closed
  end
end
