# frozen_string_literal: true

require_relative "test_helper"

class TestMessageParser < Minitest::Test
  def test_parse_user_message_with_blocks
    data = {
      "type" => "user",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "Hi" },
          { "type" => "tool_use", "id" => "1", "name" => "Bash", "input" => { "cmd" => "ls" } },
          { "type" => "tool_result", "tool_use_id" => "1", "content" => "ok", "is_error" => false },
        ],
      },
      "uuid" => "u1",
      "parent_tool_use_id" => nil,
    }

    message = ClaudeAgentSDK::MessageParser.parse_message(data)
    assert_instance_of ClaudeAgentSDK::UserMessage, message
    assert_equal "u1", message.uuid
    assert_equal 3, message.content.size
  end

  def test_parse_assistant_message
    data = {
      "type" => "assistant",
      "message" => {
        "model" => "claude",
        "content" => [
          { "type" => "text", "text" => "Hello" },
          { "type" => "thinking", "thinking" => "...", "signature" => "sig" },
        ],
      },
    }

    message = ClaudeAgentSDK::MessageParser.parse_message(data)
    assert_instance_of ClaudeAgentSDK::AssistantMessage, message
    assert_equal "claude", message.model
    assert_equal 2, message.content.size
  end

  def test_parse_system_message
    data = { "type" => "system", "subtype" => "warning", "data" => { "x" => 1 } }
    message = ClaudeAgentSDK::MessageParser.parse_message(data)
    assert_instance_of ClaudeAgentSDK::SystemMessage, message
    assert_equal "warning", message.subtype
  end

  def test_parse_result_message
    data = {
      "type" => "result",
      "subtype" => "success",
      "duration_ms" => 10,
      "duration_api_ms" => 8,
      "is_error" => false,
      "num_turns" => 1,
      "session_id" => "s1",
      "total_cost_usd" => 0.01,
      "usage" => { "input_tokens" => 10 },
      "result" => "ok",
      "structured_output" => { "x" => 1 },
    }

    message = ClaudeAgentSDK::MessageParser.parse_message(data)
    assert_instance_of ClaudeAgentSDK::ResultMessage, message
    assert_equal "s1", message.session_id
  end

  def test_parse_stream_event
    data = {
      "type" => "stream_event",
      "uuid" => "u1",
      "session_id" => "s1",
      "event" => { "type" => "message_start" },
      "parent_tool_use_id" => nil,
    }

    message = ClaudeAgentSDK::MessageParser.parse_message(data)
    assert_instance_of ClaudeAgentSDK::StreamEvent, message
    assert_equal "u1", message.uuid
  end

  def test_invalid_message_type
    error = assert_raises(ClaudeAgentSDK::MessageParseError) do
      ClaudeAgentSDK::MessageParser.parse_message({ "type" => "unknown" })
    end
    assert_includes error.message, "Unknown"
  end

  def test_missing_type
    error = assert_raises(ClaudeAgentSDK::MessageParseError) do
      ClaudeAgentSDK::MessageParser.parse_message({})
    end
    assert_includes error.message, "missing 'type'"
  end

  def test_invalid_payload_type
    error = assert_raises(ClaudeAgentSDK::MessageParseError) do
      ClaudeAgentSDK::MessageParser.parse_message("nope")
    end
    assert_includes error.message, "Invalid message data type"
  end
end
