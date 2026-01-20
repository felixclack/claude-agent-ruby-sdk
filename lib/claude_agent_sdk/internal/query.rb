# frozen_string_literal: true

require "json"
require "timeout"
require "securerandom"

module ClaudeAgentSDK
  module Internal
    class Query
      DEFAULT_STREAM_CLOSE_TIMEOUT_MS = 60_000

      def initialize(transport:, is_streaming_mode:, can_use_tool: nil, hooks: nil, sdk_mcp_servers: nil, initialize_timeout: 60.0)
        @transport = transport
        @is_streaming_mode = is_streaming_mode
        @can_use_tool = can_use_tool
        @hooks = hooks || {}
        @sdk_mcp_servers = sdk_mcp_servers || {}
        @initialize_timeout = initialize_timeout

        @pending_control_responses = {}
        @pending_control_mutex = Mutex.new
        @hook_callbacks = {}
        @next_callback_id = 0
        @request_counter = 0

        @message_queue = Queue.new
        @reader_thread = nil
        @initialized = false
        @closed = false
        @initialization_result = nil

        @first_result_mutex = Mutex.new
        @first_result_cv = ConditionVariable.new
        @first_result = false
        @stream_close_timeout = (ENV.fetch("CLAUDE_CODE_STREAM_CLOSE_TIMEOUT", DEFAULT_STREAM_CLOSE_TIMEOUT_MS.to_s).to_f / 1000.0)
      end

      attr_reader :initialization_result

      def initialize_protocol
        return nil unless @is_streaming_mode

        hooks_config = build_hooks_config
        request = { "subtype" => "initialize", "hooks" => hooks_config.empty? ? nil : hooks_config }

        response = send_control_request(request, timeout: @initialize_timeout)
        @initialized = true
        @initialization_result = response
        response
      end

      def start
        return if @reader_thread

        @reader_thread = Thread.new { read_messages }
      end

      def read_messages
        @transport.read_messages.each do |message|
          break if @closed

          msg_type = message["type"]

          case msg_type
          when "control_response"
            handle_control_response(message)
            next
          when "control_request"
            Thread.new { handle_control_request(message) }
            next
          when "control_cancel_request"
            next
          end

          if msg_type == "result"
            signal_first_result
          end

          @message_queue << message
        end
      rescue StandardError => e
        fail_pending_control_requests(e)
        @message_queue << e
      ensure
        @message_queue << :end
      end

      def handle_control_response(message)
        response = message["response"] || {}
        request_id = response["request_id"]
        return unless request_id

        queue = nil
        @pending_control_mutex.synchronize do
          queue = @pending_control_responses.delete(request_id)
        end
        return unless queue

        if response["subtype"] == "error"
          queue << StandardError.new(response["error"] || "Unknown error")
        else
          queue << response
        end
      end

      def handle_control_request(request)
        request_id = request["request_id"]
        request_data = request["request"] || {}
        subtype = request_data["subtype"]

        response_data = {}

        case subtype
        when "can_use_tool"
          raise StandardError, "canUseTool callback is not provided" unless @can_use_tool

          original_input = request_data["input"]
          context = ToolPermissionContext.new(
            signal: nil,
            suggestions: request_data["permission_suggestions"] || [],
          )

          response = @can_use_tool.call(request_data["tool_name"], request_data["input"], context)

          if response.is_a?(PermissionResultAllow)
            response_data = {
              "behavior" => "allow",
              "updatedInput" => response.updated_input || original_input,
            }
            if response.updated_permissions
              response_data["updatedPermissions"] = response.updated_permissions.map do |permission|
                permission.respond_to?(:to_h) ? permission.to_h : permission
              end
            end
          elsif response.is_a?(PermissionResultDeny)
            response_data = { "behavior" => "deny", "message" => response.message }
            response_data["interrupt"] = true if response.interrupt
          else
            raise TypeError, "Tool permission callback must return PermissionResultAllow or PermissionResultDeny"
          end

        when "hook_callback"
          callback_id = request_data["callback_id"]
          callback = @hook_callbacks[callback_id]
          raise StandardError, "No hook callback found for ID: #{callback_id}" unless callback

          hook_output = callback.call(request_data["input"], request_data["tool_use_id"], { "signal" => nil })
          response_data = convert_hook_output_for_cli(hook_output || {})

        when "mcp_message"
          server_name = request_data["server_name"]
          mcp_message = request_data["message"]
          raise StandardError, "Missing server_name or message for MCP request" unless server_name && mcp_message

          response_data = { "mcp_response" => handle_sdk_mcp_request(server_name, mcp_message) }
        else
          raise StandardError, "Unsupported control request subtype: #{subtype}"
        end

        success_response = {
          "type" => "control_response",
          "response" => {
            "subtype" => "success",
            "request_id" => request_id,
            "response" => response_data,
          },
        }
        @transport.write(success_response.to_json + "\n")
      rescue StandardError => e
        error_response = {
          "type" => "control_response",
          "response" => {
            "subtype" => "error",
            "request_id" => request_id,
            "error" => e.message,
          },
        }
        @transport.write(error_response.to_json + "\n")
      end

      def send_control_request(request, timeout: 60.0)
        raise StandardError, "Control requests require streaming mode" unless @is_streaming_mode

        @request_counter += 1
        request_id = "req_#{@request_counter}_#{SecureRandom.hex(4)}"

        queue = Queue.new
        @pending_control_mutex.synchronize do
          @pending_control_responses[request_id] = queue
        end

        control_request = {
          "type" => "control_request",
          "request_id" => request_id,
          "request" => request,
        }

        @transport.write(control_request.to_json + "\n")

        response = nil
        begin
          Timeout.timeout(timeout) { response = queue.pop }
        rescue Timeout::Error
          @pending_control_mutex.synchronize { @pending_control_responses.delete(request_id) }
          raise StandardError, "Control request timeout: #{request["subtype"]}"
        end

        if response.is_a?(Exception)
          raise response
        end

        response_data = response["response"]
        response_data.is_a?(Hash) ? response_data : {}
      end

      def handle_sdk_mcp_request(server_name, message)
        server = @sdk_mcp_servers[server_name]
        unless server
          return {
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "error" => { "code" => -32_601, "message" => "Server '#{server_name}' not found" },
          }
        end

        method = message["method"]
        params = message["params"] || {}

        case method
        when "initialize"
          return {
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => {
              "protocolVersion" => "2024-11-05",
              "capabilities" => { "tools" => {} },
              "serverInfo" => { "name" => server.name, "version" => server.version || "1.0.0" },
            },
          }
        when "tools/list"
          return {
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => { "tools" => server.list_tools },
          }
        when "tools/call"
          tool_name = params["name"]
          arguments = params["arguments"] || {}
          result = server.call_tool(tool_name, arguments)
          content = []
          if result.is_a?(Hash) && result["content"]
            result["content"].each do |item|
              case item["type"]
              when "text"
                content << { "type" => "text", "text" => item["text"] }
              when "image"
                content << { "type" => "image", "data" => item["data"], "mimeType" => item["mimeType"] }
              end
            end
          end

          response_data = { "content" => content }
          response_data["is_error"] = true if result.is_a?(Hash) && result["is_error"]

          return {
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => response_data,
          }
        when "notifications/initialized"
          return { "jsonrpc" => "2.0", "result" => {} }
        end

        {
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "error" => { "code" => -32_601, "message" => "Method '#{method}' not found" },
        }
      rescue StandardError => e
        {
          "jsonrpc" => "2.0",
          "id" => message["id"],
          "error" => { "code" => -32_603, "message" => e.message },
        }
      end

      def interrupt
        send_control_request({ "subtype" => "interrupt" })
      end

      def set_permission_mode(mode)
        send_control_request({ "subtype" => "set_permission_mode", "mode" => mode })
      end

      def set_model(model)
        send_control_request({ "subtype" => "set_model", "model" => model })
      end

      def rewind_files(user_message_id)
        send_control_request({ "subtype" => "rewind_files", "user_message_id" => user_message_id })
      end

      def stream_input(stream)
        stream.each do |message|
          break if @closed
          @transport.write(message.to_json + "\n")
        end

        has_hooks = !@hooks.empty?
        if @sdk_mcp_servers.any? || has_hooks
          wait_for_first_result
        end

        @transport.end_input
      rescue StandardError
        # ignore errors during streaming
      end

      def receive_messages
        Enumerator.new do |yielder|
          loop do
            message = @message_queue.pop
            case message
            when :end
              break
            when Exception
              raise message
            else
              yielder << message
            end
          end
        end
      end

      def close
        @closed = true
        @transport.close
        if @reader_thread
          @reader_thread.join(0.1)
          @reader_thread.kill if @reader_thread&.alive?
          @reader_thread = nil
        end
      end

      private

      def build_hooks_config
        hooks_config = {}
        @hooks.each do |event, matchers|
          event_name = event.to_s
          hooks_config[event_name] = []
          Array(matchers).each do |matcher|
            callback_ids = []
            matcher_hooks = if matcher.respond_to?(:hooks)
                              matcher.hooks
                            elsif matcher.is_a?(Hash)
                              matcher["hooks"]
                            end
            Array(matcher_hooks).each do |callback|
              callback_id = "hook_#{@next_callback_id}"
              @next_callback_id += 1
              @hook_callbacks[callback_id] = callback
              callback_ids << callback_id
            end

            hook_matcher_config = {
              "matcher" => matcher.respond_to?(:matcher) ? matcher.matcher : (matcher.is_a?(Hash) ? matcher["matcher"] : nil),
              "hookCallbackIds" => callback_ids,
            }
            timeout = matcher.respond_to?(:timeout) ? matcher.timeout : (matcher.is_a?(Hash) ? matcher["timeout"] : nil)
            hook_matcher_config["timeout"] = timeout if timeout

            hooks_config[event_name] << hook_matcher_config
          end
        end
        hooks_config
      end

      def convert_hook_output_for_cli(hook_output)
        converted = {}
        hook_output.each do |key, value|
          case key.to_s
          when "async_"
            converted["async"] = value
          when "continue_"
            converted["continue"] = value
          else
            converted[key.to_s] = value
          end
        end
        converted
      end

      def wait_for_first_result
        @first_result_mutex.synchronize do
          return if @first_result

          begin
            Timeout.timeout(@stream_close_timeout) do
              @first_result_cv.wait(@first_result_mutex) unless @first_result
            end
          rescue Timeout::Error
            # ignore timeout
          end
        end
      end

      def signal_first_result
        @first_result_mutex.synchronize do
          return if @first_result

          @first_result = true
          @first_result_cv.broadcast
        end
      end

      def fail_pending_control_requests(error)
        @pending_control_mutex.synchronize do
          @pending_control_responses.each_value { |queue| queue << error }
          @pending_control_responses.clear
        end
      end
    end
  end
end
