# frozen_string_literal: true

require "json"

module ClaudeAgentSDK
  class ClaudeSDKClient
    attr_reader :options

    def initialize(options: nil, transport: nil)
      @options = options || ClaudeAgentOptions.new
      @custom_transport = transport
      @transport = nil
      @query = nil
      ENV["CLAUDE_CODE_ENTRYPOINT"] = "sdk-rb-client"
    end

    def connect(prompt: nil)
      actual_prompt = prompt.nil? ? [] : prompt

      if @options.can_use_tool
        if prompt.is_a?(String)
          raise ArgumentError, "can_use_tool callback requires streaming mode. Please provide prompt as an Enumerable instead of a string."
        end

        if @options.permission_prompt_tool_name
          raise ArgumentError, "can_use_tool callback cannot be used with permission_prompt_tool_name. Please use one or the other."
        end

        options = @options.merge(permission_prompt_tool_name: "stdio")
      else
        options = @options
      end

      @transport = @custom_transport || Transport::SubprocessCLITransport.new(prompt: actual_prompt, options: options)
      @transport.connect

      sdk_mcp_servers = {}
      if @options.mcp_servers.is_a?(Hash)
        @options.mcp_servers.each do |name, config|
          if config.is_a?(Hash) && config["type"] == "sdk"
            sdk_mcp_servers[name] = config["instance"]
          end
        end
      end

      initialize_timeout_ms = ENV.fetch("CLAUDE_CODE_STREAM_CLOSE_TIMEOUT", "60000").to_i
      initialize_timeout = [initialize_timeout_ms / 1000.0, 60.0].max

      @query = Internal::Query.new(
        transport: @transport,
        is_streaming_mode: true,
        can_use_tool: @options.can_use_tool,
        hooks: @options.hooks,
        sdk_mcp_servers: sdk_mcp_servers,
        initialize_timeout: initialize_timeout,
      )

      @query.start
      @query.initialize_protocol

      if !prompt.nil? && prompt.respond_to?(:each)
        Thread.new { @query.stream_input(prompt) }
      end

      self
    end

    def open(prompt: nil)
      connect(prompt: prompt)
      return self unless block_given?

      begin
        yield self
      ensure
        disconnect
      end
    end

    def receive_messages
      ensure_connected!
      Enumerator.new do |yielder|
        @query.receive_messages.each do |data|
          yielder << MessageParser.parse_message(data)
        end
      end
    end

    def each_message(&block)
      enum = receive_messages
      return enum unless block

      enum.each(&block)
    end
    alias messages each_message

    def receive_response
      ensure_connected!
      Enumerator.new do |yielder|
        receive_messages.each do |message|
          yielder << message
          break if message.is_a?(ResultMessage)
        end
      end
    end

    def each_response(&block)
      enum = receive_response
      return enum unless block

      enum.each(&block)
    end
    alias responses each_response

    def query(prompt, session_id: "default")
      ensure_connected!

      if prompt.is_a?(String)
        message = {
          "type" => "user",
          "message" => { "role" => "user", "content" => prompt },
          "parent_tool_use_id" => nil,
          "session_id" => session_id,
        }
        @transport.write(message.to_json + "\n")
      else
        prompt.each do |msg|
          msg["session_id"] ||= session_id
          @transport.write(msg.to_json + "\n")
        end
      end

      self
    end
    alias ask query
    alias send_message query

    def interrupt
      ensure_connected!
      @query.interrupt
    end

    def set_permission_mode(mode)
      ensure_connected!
      @query.set_permission_mode(mode)
    end

    def set_model(model = nil)
      ensure_connected!
      @query.set_model(model)
    end

    def rewind_files(user_message_id)
      ensure_connected!
      @query.rewind_files(user_message_id)
    end

    def get_server_info
      ensure_connected!
      @query.initialization_result
    end

    def disconnect
      @query&.close
      @query = nil
      @transport = nil
    end
    alias close disconnect

    def connected?
      !@query.nil?
    end

    alias with open

    private

    def ensure_connected!
      raise CLIConnectionError, "Not connected. Call connect() first." unless @query
    end
  end
end
