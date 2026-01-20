# frozen_string_literal: true

module ClaudeAgentSDK
  module MessageParser
    module_function

    def parse_message(data)
      unless data.is_a?(Hash)
        raise MessageParseError.new(
          "Invalid message data type (expected Hash, got #{data.class})",
          data: data,
        )
      end

      message_type = data["type"]
      raise MessageParseError.new("Message missing 'type' field", data: data) unless message_type

      case message_type
      when "user"
        parse_user_message(data)
      when "assistant"
        parse_assistant_message(data)
      when "system"
        SystemMessage.new(subtype: data.fetch("subtype"), data: data)
      when "result"
        ResultMessage.new(
          subtype: data.fetch("subtype"),
          duration_ms: data.fetch("duration_ms"),
          duration_api_ms: data.fetch("duration_api_ms"),
          is_error: data.fetch("is_error"),
          num_turns: data.fetch("num_turns"),
          session_id: data.fetch("session_id"),
          total_cost_usd: data["total_cost_usd"],
          usage: data["usage"],
          result: data["result"],
          structured_output: data["structured_output"],
        )
      when "stream_event"
        StreamEvent.new(
          uuid: data.fetch("uuid"),
          session_id: data.fetch("session_id"),
          event: data.fetch("event"),
          parent_tool_use_id: data["parent_tool_use_id"],
        )
      else
        raise MessageParseError.new("Unknown message type: #{message_type}", data: data)
      end
    rescue KeyError => e
      raise MessageParseError.new("Missing required field in #{message_type} message: #{e.message}", data: data)
    end

    def parse_user_message(data)
      parent_tool_use_id = data["parent_tool_use_id"]
      uuid = data["uuid"]
      message = data.fetch("message")
      content = message.fetch("content")

      if content.is_a?(Array)
        blocks = content.map { |block| parse_content_block(block) }.compact
        UserMessage.new(content: blocks, uuid: uuid, parent_tool_use_id: parent_tool_use_id)
      else
        UserMessage.new(content: content, uuid: uuid, parent_tool_use_id: parent_tool_use_id)
      end
    end

    def parse_assistant_message(data)
      message = data.fetch("message")
      blocks = message.fetch("content").map { |block| parse_content_block(block) }.compact
      AssistantMessage.new(
        content: blocks,
        model: message.fetch("model"),
        parent_tool_use_id: data["parent_tool_use_id"],
        error: message["error"],
      )
    end

    def parse_content_block(block)
      case block["type"]
      when "text"
        TextBlock.new(text: block.fetch("text"))
      when "thinking"
        ThinkingBlock.new(thinking: block.fetch("thinking"), signature: block.fetch("signature"))
      when "tool_use"
        ToolUseBlock.new(id: block.fetch("id"), name: block.fetch("name"), input: block.fetch("input"))
      when "tool_result"
        ToolResultBlock.new(
          tool_use_id: block.fetch("tool_use_id"),
          content: block["content"],
          is_error: block["is_error"],
        )
      else
        nil
      end
    end
  end
end
