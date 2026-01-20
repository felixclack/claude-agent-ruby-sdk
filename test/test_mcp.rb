# frozen_string_literal: true

require_relative "test_helper"

class TestMcp < Minitest::Test
  def test_tool_requires_block
    error = assert_raises(ArgumentError) do
      ClaudeAgentSDK.tool("noop", "No block", {})
    end
    assert_includes error.message, "handler"
  end

  def test_tool_and_server
    greet = ClaudeAgentSDK.tool("greet", "Greet", { "name" => String }) do |args|
      { "content" => [{ "type" => "text", "text" => "Hello #{args["name"]}" }] }
    end

    server = ClaudeAgentSDK::SdkMcpServer.new("tools", tools: [greet])

    tools_list = server.list_tools
    assert_equal 1, tools_list.size
    assert_equal "greet", tools_list.first["name"]
    assert_equal "string", tools_list.first.dig("inputSchema", "properties", "name", "type")

    result = server.call_tool("greet", { "name" => "Ada" })
    assert_equal "Hello Ada", result["content"].first["text"]

    error = assert_raises(ArgumentError) { server.call_tool("missing", {}) }
    assert_includes error.message, "not found"
  end

  def test_tool_error_returns_is_error
    fail_tool = ClaudeAgentSDK.tool("fail", "Fail", {}) do |_args|
      raise "boom"
    end

    server = ClaudeAgentSDK::SdkMcpServer.new("tools", tools: [fail_tool])
    result = server.call_tool("fail", {})

    assert_equal true, result["is_error"]
    assert_equal "boom", result.dig("content", 0, "text")
  end

  def test_schema_for_json_schema_passthrough
    schema = { "type" => "object", "properties" => { "x" => { "type" => "string" } } }
    result = ClaudeAgentSDK::SdkMcpServer.schema_for(schema)
    assert_equal schema, result
  end

  def test_schema_for_symbol_keys
    schema = { type: "object", properties: { name: { type: "string" } } }
    result = ClaudeAgentSDK::SdkMcpServer.schema_for(schema)
    assert_equal "object", result["type"]
    assert_equal "string", result.dig("properties", "name", "type")
  end

  def test_type_to_json
    assert_equal "string", ClaudeAgentSDK::SdkMcpServer.type_to_json(String)
    assert_equal "integer", ClaudeAgentSDK::SdkMcpServer.type_to_json(Integer)
    assert_equal "number", ClaudeAgentSDK::SdkMcpServer.type_to_json(Float)
    assert_equal "boolean", ClaudeAgentSDK::SdkMcpServer.type_to_json(true)
    assert_equal "boolean", ClaudeAgentSDK::SdkMcpServer.type_to_json(FalseClass)
    assert_equal "string", ClaudeAgentSDK::SdkMcpServer.type_to_json(Object)
  end

  def test_schema_for_non_hash
    result = ClaudeAgentSDK::SdkMcpServer.schema_for("string")
    assert_equal({ "type" => "object", "properties" => {} }, result)
  end

  def test_create_sdk_mcp_server
    server = ClaudeAgentSDK.create_sdk_mcp_server(name: "tools", tools: [])
    assert_equal "sdk", server["type"]
    assert_equal "tools", server["name"]
    assert_instance_of ClaudeAgentSDK::SdkMcpServer, server["instance"]
  end
end
