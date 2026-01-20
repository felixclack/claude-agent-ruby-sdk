# frozen_string_literal: true

module ClaudeAgentSDK
  module Internal
    class Client
      def process_query(prompt:, options:, transport: nil)
        configured_options = options

        if options.can_use_tool
          if prompt.is_a?(String)
            raise ArgumentError, "can_use_tool callback requires streaming mode. Please provide prompt as an Enumerable instead of a string."
          end

          if options.permission_prompt_tool_name
            raise ArgumentError, "can_use_tool callback cannot be used with permission_prompt_tool_name. Please use one or the other."
          end

          configured_options = options.merge(permission_prompt_tool_name: "stdio")
        end

        chosen_transport = transport || Transport::SubprocessCLITransport.new(prompt: prompt, options: configured_options)
        chosen_transport.connect

        sdk_mcp_servers = {}
        if configured_options.mcp_servers.is_a?(Hash)
          configured_options.mcp_servers.each do |name, config|
            if config.is_a?(Hash) && config["type"] == "sdk"
              sdk_mcp_servers[name] = config["instance"]
            end
          end
        end

        is_streaming = !prompt.is_a?(String)
        query = Internal::Query.new(
          transport: chosen_transport,
          is_streaming_mode: is_streaming,
          can_use_tool: configured_options.can_use_tool,
          hooks: configured_options.hooks,
          sdk_mcp_servers: sdk_mcp_servers,
        )

        query.start
        query.initialize_protocol if is_streaming

        if is_streaming && prompt.respond_to?(:each)
          Thread.new { query.stream_input(prompt) }
        end

        Enumerator.new do |yielder|
          begin
            query.receive_messages.each do |data|
              yielder << MessageParser.parse_message(data)
            end
          ensure
            query.close
          end
        end
      end
    end
  end
end
