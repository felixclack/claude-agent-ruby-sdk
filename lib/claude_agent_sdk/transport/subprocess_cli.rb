# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "timeout"
require "rbconfig"
require "etc"

module ClaudeAgentSDK
  class Transport
    class SubprocessCLITransport < Transport
      DEFAULT_MAX_BUFFER_SIZE = 1024 * 1024
      MINIMUM_CLAUDE_CODE_VERSION = "2.0.0"
      CMD_LENGTH_LIMIT = Gem.win_platform? ? 8000 : 100_000

      def initialize(prompt:, options:)
        @prompt = prompt
        @is_streaming = !prompt.is_a?(String)
        @options = options
        @cli_path = options.cli_path ? options.cli_path.to_s : find_cli
        @cwd = options.cwd ? options.cwd.to_s : nil

        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @stderr_thread = nil

        @ready = false
        @exit_error = nil
        @max_buffer_size = options.max_buffer_size || DEFAULT_MAX_BUFFER_SIZE
        @temp_files = []
        @write_lock = Mutex.new
      end

      def connect
        return if @wait_thread

        check_claude_version unless ENV["CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"]

        cmd = build_command
        process_env = ENV.to_h.merge(@options.env || {})
        process_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-rb"
        process_env["CLAUDE_AGENT_SDK_VERSION"] = ClaudeAgentSDK::VERSION
        if @options.enable_file_checkpointing
          process_env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "true"
        end
        process_env["PWD"] = @cwd if @cwd

        spawn_opts = {}
        if @cwd
          spawn_opts[:chdir] = @cwd
        end

        if @options.user
          begin
            user_info = Etc.getpwnam(@options.user)
            spawn_opts[:uid] = user_info.uid
            spawn_opts[:gid] = user_info.gid
          rescue StandardError
            warn("Unable to resolve user '#{@options.user}', running as current user")
          end
        end

        should_pipe_stderr = @options.stderr || (@options.extra_args || {}).key?("debug-to-stderr")

        begin
          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(process_env, *cmd, **spawn_opts)
        rescue Errno::ENOENT => e
          if @cwd && !Dir.exist?(@cwd)
            @exit_error = CLIConnectionError.new("Working directory does not exist: #{@cwd}")
            raise @exit_error
          end
          @exit_error = CLINotFoundError.new("Claude Code not found at: #{@cli_path}")
          raise @exit_error
        rescue StandardError => e
          @exit_error = CLIConnectionError.new("Failed to start Claude Code: #{e.message}")
          raise @exit_error
        end

        unless should_pipe_stderr
          @stderr.close if @stderr
          @stderr = nil
        end

        if should_pipe_stderr && @stderr
          @stderr_thread = Thread.new { handle_stderr }
        end

        if @is_streaming
          @stdin.sync = true if @stdin
        else
          @stdin.close if @stdin
          @stdin = nil
        end

        @ready = true
      end

      def write(data)
        @write_lock.synchronize do
          unless @ready && @stdin
            raise CLIConnectionError, "Process transport is not ready for writing"
          end

          if @wait_thread && @wait_thread.join(0)
            raise CLIConnectionError, "Cannot write to terminated process (exit code: #{@wait_thread.value.exitstatus})"
          end

          if @exit_error
            raise CLIConnectionError, "Cannot write to process that exited with error: #{@exit_error}"
          end

          @stdin.write(data)
          @stdin.flush
        rescue StandardError => e
          @ready = false
          @exit_error = CLIConnectionError.new("Failed to write to process stdin: #{e.message}")
          raise @exit_error
        end
      end

      def end_input
        @write_lock.synchronize do
          if @stdin
            @stdin.close
            @stdin = nil
          end
        end
      end

      def read_messages
        Enumerator.new do |yielder|
          raise CLIConnectionError, "Not connected" unless @stdout && @wait_thread

        json_buffer = +""

          begin
            @stdout.each_line do |line|
              line_str = line.strip
              next if line_str.empty?

              line_str.split("\n").each do |json_line|
                json_line = json_line.strip
                next if json_line.empty?

                json_buffer << json_line

                if json_buffer.bytesize > @max_buffer_size
                  buffer_length = json_buffer.bytesize
                  json_buffer = ""
                  raise CLIJSONDecodeError.new(
                    "JSON message exceeded maximum buffer size of #{@max_buffer_size} bytes",
                    StandardError.new("Buffer size #{buffer_length} exceeds limit #{@max_buffer_size}"),
                  )
                end

                begin
                  data = JSON.parse(json_buffer)
                  json_buffer = ""
                  yielder << data
                rescue JSON::ParserError
                  next
                end
              end
            end
          rescue IOError, SystemCallError
            # ignore closed streams
          end

          status = @wait_thread.value rescue nil
          if status && !status.success?
            @exit_error = ProcessError.new(
              "Command failed with exit code #{status.exitstatus}",
              exit_code: status.exitstatus,
              stderr: "Check stderr output for details",
            )
            raise @exit_error
          end
        end
      end

      def close
        cleanup_temp_files

        @write_lock.synchronize do
          @ready = false
          if @stdin
            @stdin.close
            @stdin = nil
          end
        end

        @stdout.close if @stdout && !@stdout.closed?
        @stdout = nil

        @stderr.close if @stderr && !@stderr.closed?
        @stderr = nil

        if @stderr_thread
          @stderr_thread.join(0.1)
          @stderr_thread.kill if @stderr_thread.alive?
          @stderr_thread = nil
        end

        if @wait_thread
          begin
            Process.kill("TERM", @wait_thread.pid) if @wait_thread.alive?
          rescue StandardError
            # ignore
          end
          @wait_thread.join(0.2)
          @wait_thread = nil
        end

        @exit_error = nil
      end

      def ready?
        @ready
      end

      private

      def handle_stderr
        @stderr.each_line do |line|
          line_str = line.rstrip
          next if line_str.empty?

          if @options.stderr
            @options.stderr.call(line_str)
          elsif (@options.extra_args || {}).key?("debug-to-stderr") && @options.debug_stderr
            @options.debug_stderr.write(line_str + "\n")
            @options.debug_stderr.flush if @options.debug_stderr.respond_to?(:flush)
          end
        end
      rescue IOError
        # ignore closed stderr
      end

      def find_cli
        bundled = find_bundled_cli
        return bundled if bundled

        from_path = which("claude")
        return from_path if from_path

        locations = [
          File.join(Dir.home, ".npm-global/bin/claude"),
          "/usr/local/bin/claude",
          File.join(Dir.home, ".local/bin/claude"),
          File.join(Dir.home, "node_modules/.bin/claude"),
          File.join(Dir.home, ".yarn/bin/claude"),
          File.join(Dir.home, ".claude/local/claude"),
        ]

        locations.each do |path|
          return path if File.file?(path)
        end

        raise CLINotFoundError.new(
          "Claude Code not found. Install with:\n" \
          "  npm install -g @anthropic-ai/claude-code\n" \
          "\nIf already installed locally, try:\n" \
          '  export PATH="$HOME/node_modules/.bin:$PATH"\n' \
          "\nOr provide the path via ClaudeAgentOptions:\n" \
          "  ClaudeAgentOptions.new(cli_path: '/path/to/claude')",
        )
      end

      def find_bundled_cli
        cli_name = Gem.win_platform? ? "claude.exe" : "claude"
        bundled_path = File.expand_path("../_bundled/#{cli_name}", __dir__)
        return bundled_path if File.file?(bundled_path)

        nil
      end

      def build_settings_value
        has_settings = !@options.settings.nil?
        has_sandbox = !@options.sandbox.nil?
        return nil unless has_settings || has_sandbox

        return @options.settings if has_settings && !has_sandbox

        settings_obj = {}

        if has_settings
          settings_str = @options.settings.to_s.strip
          if settings_str.start_with?("{") && settings_str.end_with?("}")
            begin
              settings_obj = JSON.parse(settings_str)
            rescue JSON::ParserError
              if File.file?(settings_str)
                settings_obj = JSON.parse(File.read(settings_str))
              end
            end
          elsif File.file?(settings_str)
            settings_obj = JSON.parse(File.read(settings_str))
          else
            warn("Settings file not found: #{settings_str}")
          end
        end

        settings_obj["sandbox"] = @options.sandbox if has_sandbox
        JSON.generate(settings_obj)
      end

      def build_command
        cmd = [@cli_path, "--output-format", "stream-json", "--verbose"]

        if @options.system_prompt.nil?
          cmd.concat(["--system-prompt", ""])
        elsif @options.system_prompt.is_a?(String)
          cmd.concat(["--system-prompt", @options.system_prompt])
        else
          prompt_hash = normalize_hash(@options.system_prompt)
          if prompt_hash["type"] == "preset" && prompt_hash.key?("append")
            cmd.concat(["--append-system-prompt", prompt_hash["append"]])
          end
        end

        if @options.tools
          if @options.tools.is_a?(Array)
            cmd.concat(["--tools", @options.tools.empty? ? "" : @options.tools.join(",")])
          else
            cmd.concat(["--tools", "default"])
          end
        end

        cmd.concat(["--allowedTools", @options.allowed_tools.join(",")]) if @options.allowed_tools&.any?
        cmd.concat(["--max-turns", @options.max_turns.to_s]) if @options.max_turns
        cmd.concat(["--max-budget-usd", @options.max_budget_usd.to_s]) unless @options.max_budget_usd.nil?
        cmd.concat(["--disallowedTools", @options.disallowed_tools.join(",")]) if @options.disallowed_tools&.any?
        cmd.concat(["--model", @options.model]) if @options.model
        cmd.concat(["--fallback-model", @options.fallback_model]) if @options.fallback_model
        cmd.concat(["--betas", @options.betas.join(",")]) if @options.betas&.any?
        cmd.concat(["--permission-prompt-tool", @options.permission_prompt_tool_name]) if @options.permission_prompt_tool_name
        cmd.concat(["--permission-mode", @options.permission_mode]) if @options.permission_mode
        cmd << "--continue" if @options.continue_conversation
        cmd.concat(["--resume", @options.resume]) if @options.resume

        settings_value = build_settings_value
        cmd.concat(["--settings", settings_value]) if settings_value

        Array(@options.add_dirs).each do |directory|
          cmd.concat(["--add-dir", directory.to_s])
        end

        if @options.mcp_servers
          if @options.mcp_servers.is_a?(Hash)
            servers_for_cli = {}
            @options.mcp_servers.each do |name, config|
              if config.is_a?(Hash) && config["type"] == "sdk"
                sdk_config = config.reject { |key, _| key == "instance" }
                servers_for_cli[name] = sdk_config
              else
                servers_for_cli[name] = config
              end
            end

            unless servers_for_cli.empty?
              cmd.concat(["--mcp-config", JSON.generate({ "mcpServers" => servers_for_cli })])
            end
          else
            cmd.concat(["--mcp-config", @options.mcp_servers.to_s])
          end
        end

        cmd << "--include-partial-messages" if @options.include_partial_messages
        cmd << "--fork-session" if @options.fork_session

        if @options.agents
          agents_dict = {}
          @options.agents.each do |name, agent|
            agents_dict[name] = agent.respond_to?(:to_h) ? agent.to_h : agent
          end
          agents_json = JSON.generate(agents_dict)
          cmd.concat(["--agents", agents_json])
        end

        sources_value = @options.setting_sources ? Array(@options.setting_sources).join(",") : ""
        cmd.concat(["--setting-sources", sources_value])

        Array(@options.plugins).each do |plugin|
          if plugin["type"] == "local"
            cmd.concat(["--plugin-dir", plugin["path"]])
          else
            raise ArgumentError, "Unsupported plugin type: #{plugin["type"]}"
          end
        end

        (@options.extra_args || {}).each do |flag, value|
          if value.nil?
            cmd << "--#{flag}"
          else
            cmd.concat(["--#{flag}", value.to_s])
          end
        end

        cmd.concat(["--max-thinking-tokens", @options.max_thinking_tokens.to_s]) if @options.max_thinking_tokens

        if @options.output_format.is_a?(Hash) && @options.output_format["type"] == "json_schema"
          schema = @options.output_format["schema"]
          cmd.concat(["--json-schema", JSON.generate(schema)]) if schema
        end

        if @is_streaming
          cmd.concat(["--input-format", "stream-json"])
        else
          cmd.concat(["--print", "--", @prompt.to_s])
        end

        optimize_command_length(cmd)
      end

      def optimize_command_length(cmd)
        cmd_str = cmd.join(" ")
        return cmd if cmd_str.length <= CMD_LENGTH_LIMIT
        return cmd unless @options.agents

        begin
          agents_index = cmd.index("--agents")
          agents_json = cmd[agents_index + 1]

          temp_file = Tempfile.new(["claude-agent-sdk", ".json"])
          temp_file.write(agents_json)
          temp_file.close

          @temp_files << temp_file.path
          cmd[agents_index + 1] = "@#{temp_file.path}"
        rescue StandardError
          # ignore optimization failures
        end

        cmd
      end

      def cleanup_temp_files
        @temp_files.each do |path|
          begin
            File.delete(path) if File.exist?(path)
          rescue StandardError
            # ignore
          end
        end
        @temp_files.clear
      end

      def normalize_hash(value)
        if value.respond_to?(:to_h)
          value.to_h.transform_keys(&:to_s)
        else
          value
        end
      end

      def which(command)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |path|
          exe = File.join(path, command)
          return exe if File.executable?(exe) && !File.directory?(exe)
        end
        nil
      end

      def check_claude_version
        output = nil
        begin
          Timeout.timeout(2) do
            stdout, _stderr, _status = Open3.capture3(@cli_path.to_s, "-v")
            output = stdout.strip
          end
        rescue StandardError
          return
        end

        match = output&.match(/([0-9]+\.[0-9]+\.[0-9]+)/)
        return unless match

        version = match[1]
        if version_lt?(version, MINIMUM_CLAUDE_CODE_VERSION)
          warning = "Warning: Claude Code version #{version} is unsupported in the Agent SDK. " \
                    "Minimum required version is #{MINIMUM_CLAUDE_CODE_VERSION}. " \
                    "Some features may not work correctly."
          warn(warning)
        end
      end

      def version_lt?(current, minimum)
        current_parts = current.split(".").map(&:to_i)
        minimum_parts = minimum.split(".").map(&:to_i)
        (current_parts <=> minimum_parts) == -1
      end
    end
  end
end
