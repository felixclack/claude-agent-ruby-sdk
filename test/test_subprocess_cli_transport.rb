# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "open3"
require "tempfile"
require "tmpdir"

class TestSubprocessCLITransport < Minitest::Test
  def build_options(overrides = {})
    ClaudeAgentSDK::ClaudeAgentOptions.new(**{
      tools: ["Read", "Write"],
      allowed_tools: ["Read"],
      system_prompt: "hi",
      mcp_servers: { "server" => { "type" => "stdio", "command" => "echo" } },
      permission_mode: "acceptEdits",
      continue_conversation: true,
      resume: "resume",
      max_turns: 2,
      max_budget_usd: 1.5,
      disallowed_tools: ["Bash"],
      model: "claude",
      fallback_model: "fallback",
      betas: ["context-1m-2025-08-07"],
      permission_prompt_tool_name: "stdio",
      cli_path: "/bin/echo",
      settings: "{\"foo\":\"bar\"}",
      add_dirs: ["/tmp"],
      env: { "FOO" => "bar" },
      extra_args: { "debug-to-stderr" => nil, "flag" => "value" },
      include_partial_messages: true,
      fork_session: true,
      agents: { "agent" => ClaudeAgentSDK::AgentDefinition.new(description: "d", prompt: "p") },
      setting_sources: ["user"],
      plugins: [{ "type" => "local", "path" => "/tmp" }],
      sandbox: { "enabled" => true },
      max_thinking_tokens: 10,
      output_format: { "type" => "json_schema", "schema" => { "type" => "object" } },
    }.merge(overrides))
  end

  def test_build_command_with_string_prompt
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    cmd = transport.send(:build_command)

    assert_includes cmd, "--print"
    assert_includes cmd, "hi"
    assert_includes cmd, "--permission-mode"
    assert_includes cmd, "acceptEdits"
  end

  def test_build_command_streaming
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: [], options: options)
    cmd = transport.send(:build_command)
    assert_includes cmd, "--input-format"
    assert_includes cmd, "stream-json"
  end

  def test_build_command_with_presets_and_sdk_mcp
    tools_preset = ClaudeAgentSDK::ToolsPreset.new(type: "preset", preset: "claude_code")
    system_prompt_preset = ClaudeAgentSDK::SystemPromptPreset.new(type: "preset", preset: "claude_code", append: "extra")
    sdk_server = ClaudeAgentSDK.create_sdk_mcp_server(name: "tools", tools: [])

    options = build_options(
      tools: tools_preset,
      system_prompt: system_prompt_preset,
      mcp_servers: { "tools" => sdk_server },
    )

    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    cmd = transport.send(:build_command)

    assert_includes cmd, "--tools"
    assert_includes cmd, "default"
    assert_includes cmd, "--append-system-prompt"
    assert_includes cmd, "extra"

    mcp_index = cmd.index("--mcp-config")
    mcp_config = JSON.parse(cmd[mcp_index + 1])
    assert_equal "sdk", mcp_config["mcpServers"]["tools"]["type"]
    refute mcp_config["mcpServers"]["tools"].key?("instance")
  end

  def test_build_command_with_empty_tools_and_nil_system_prompt
    options = build_options(tools: [], system_prompt: nil, mcp_servers: nil)
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    cmd = transport.send(:build_command)

    system_index = cmd.index("--system-prompt")
    assert_equal "", cmd[system_index + 1]

    tools_index = cmd.index("--tools")
    assert_equal "", cmd[tools_index + 1]
  end

  def test_build_command_with_mcp_config_path
    options = build_options(mcp_servers: "/tmp/mcp.json")
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    cmd = transport.send(:build_command)

    mcp_index = cmd.index("--mcp-config")
    assert_equal "/tmp/mcp.json", cmd[mcp_index + 1]
  end

  def test_build_command_with_invalid_plugin_type
    options = build_options(plugins: [{ "type" => "bad", "path" => "/tmp" }])
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_raises(ArgumentError) { transport.send(:build_command) }
  end

  def test_build_settings_value_returns_nil_without_settings_or_sandbox
    options = build_options(settings: nil, sandbox: nil)
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_nil transport.send(:build_settings_value)
  end

  def test_build_settings_value_merges_sandbox
    options = build_options(settings: "{\"a\":1}", sandbox: { "enabled" => true })
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    settings = transport.send(:build_settings_value)

    parsed = JSON.parse(settings)
    assert_equal 1, parsed["a"]
    assert_equal true, parsed.dig("sandbox", "enabled")
  end

  def test_build_settings_value_from_file
    file = Tempfile.new("settings")
    file.write(JSON.generate({ "x" => 1 }))
    file.close

    options = build_options(settings: file.path, sandbox: { "enabled" => true })
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)
    settings = transport.send(:build_settings_value)

    parsed = JSON.parse(settings)
    assert_equal 1, parsed["x"]
    assert_equal true, parsed.dig("sandbox", "enabled")
  ensure
    file.unlink if file
  end

  def test_optimize_command_length_uses_tempfile
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    original_limit = ClaudeAgentSDK::Transport::SubprocessCLITransport.const_get(:CMD_LENGTH_LIMIT)
    ClaudeAgentSDK::Transport::SubprocessCLITransport.send(:remove_const, :CMD_LENGTH_LIMIT)
    ClaudeAgentSDK::Transport::SubprocessCLITransport.const_set(:CMD_LENGTH_LIMIT, 10)

    cmd = transport.send(:build_command)
    agents_index = cmd.index("--agents")
    assert_match(/^@/, cmd[agents_index + 1])
  ensure
    transport.send(:cleanup_temp_files) if transport
    ClaudeAgentSDK::Transport::SubprocessCLITransport.send(:remove_const, :CMD_LENGTH_LIMIT)
    ClaudeAgentSDK::Transport::SubprocessCLITransport.const_set(:CMD_LENGTH_LIMIT, original_limit)
  end

  def test_check_claude_version_warns
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stderr = StringIO.new
    original_stderr = $stderr
    $stderr = stderr

    Open3.stub(:capture3, ["1.0.0\n", "", Object.new]) do
      transport.send(:check_claude_version)
    end

    assert_includes stderr.string, "Warning"
  ensure
    $stderr = original_stderr
  end

  def test_handle_stderr_callback
    lines = []
    options = build_options(stderr: ->(line) { lines << line }, extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.instance_variable_set(:@stderr, StringIO.new("one\n"))
    transport.send(:handle_stderr)

    assert_equal ["one"], lines
  end

  def test_handle_stderr_debug_fallback
    buffer = StringIO.new
    options = build_options(stderr: nil, debug_stderr: buffer, extra_args: { "debug-to-stderr" => nil })
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.instance_variable_set(:@stderr, StringIO.new("debug\n"))
    transport.send(:handle_stderr)

    assert_includes buffer.string, "debug"
  end

  def test_connect_write_read_and_close
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("{\"type\":\"result\",\"subtype\":\"success\",\"duration_ms\":1,\"duration_api_ms\":1,\"is_error\":false,\"num_turns\":1,\"session_id\":\"s1\"}\n")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
      messages = transport.read_messages.to_a
      assert_equal "result", messages.first["type"]

      transport.close
      assert_equal true, transport.ready? == false
    end
  end

  def test_write_raises_when_not_ready
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_raises(ClaudeAgentSDK::CLIConnectionError) do
      transport.write("x")
    end
  end

  def test_read_messages_raises_when_not_connected
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_raises(ClaudeAgentSDK::CLIConnectionError) do
      transport.read_messages.to_a
    end
  end

  def test_connect_raises_for_missing_cli
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    Open3.stub(:popen3, proc { |_env, *_args, **_kwargs| raise Errno::ENOENT }) do
      assert_raises(ClaudeAgentSDK::CLINotFoundError) { transport.connect }
    end
  end

  def test_connect_raises_for_bad_cwd
    options = build_options(extra_args: {}, cwd: "/nope")
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    Open3.stub(:popen3, proc { |_env, *_args, **_kwargs| raise Errno::ENOENT }) do
      error = assert_raises(ClaudeAgentSDK::CLIConnectionError) { transport.connect }
      assert_includes error.message, "Working directory"
    end
  end

  def test_write_and_end_input_in_streaming_mode
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: [], options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
      transport.write("{\"type\":\"user\"}\n")
      assert_includes stdin.data, "user"

      transport.end_input
      assert stdin.closed?
    end
  end

  def test_normalize_hash
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    preset = ClaudeAgentSDK::SystemPromptPreset.new(type: "preset", preset: "claude_code", append: "x")
    normalized = transport.send(:normalize_hash, preset)
    assert_equal "preset", normalized["type"]
    assert_equal "claude_code", normalized["preset"]
  end

  def test_version_lt
    options = build_options
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_equal true, transport.send(:version_lt?, "1.0.0", "2.0.0")
    assert_equal false, transport.send(:version_lt?, "2.1.0", "2.0.0")
  end

  def test_connect_sets_checkpoint_env
    options = build_options(enable_file_checkpointing: true, extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)
    captured_env = nil

    Open3.stub(:popen3, proc { |env, *_args, **_opts|
      captured_env = env
      [stdin, stdout, stderr, wait_thread]
    }) do
      transport.connect
      assert_equal "true", captured_env["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"]
    end
  end

  def test_connect_user_resolution_sets_uid_gid
    options = build_options(user: "fake", extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)
    captured_opts = nil

    user_info = Struct.new(:uid, :gid).new(100, 200)
    Etc.stub(:getpwnam, user_info) do
      Open3.stub(:popen3, proc { |_env, *_args, **opts|
        captured_opts = opts
        [stdin, stdout, stderr, wait_thread]
      }) do
        transport.connect
      end
    end

    assert_equal 100, captured_opts[:uid]
    assert_equal 200, captured_opts[:gid]
  end

  def test_connect_user_resolution_warns_on_error
    options = build_options(user: "missing", extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    warnings = []
    Etc.stub(:getpwnam, proc { raise StandardError }) do
      transport.stub(:warn, proc { |msg| warnings << msg }) do
        Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
          transport.connect
        end
      end
    end

    assert warnings.any? { |msg| msg.include?("Unable to resolve user") }
  end

  def test_connect_raises_for_standard_error
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    Open3.stub(:popen3, proc { |_env, *_args, **_opts| raise StandardError, "boom" }) do
      error = assert_raises(ClaudeAgentSDK::CLIConnectionError) { transport.connect }
      assert_includes error.message, "Failed to start Claude Code"
    end
  end

  def test_write_raises_when_wait_thread_terminated
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: [], options: options)

    terminated_thread = Class.new do
      def join(_timeout) = true
      def value = Struct.new(:exitstatus).new(2)
    end.new

    transport.instance_variable_set(:@ready, true)
    transport.instance_variable_set(:@stdin, FakeStdin.new)
    transport.instance_variable_set(:@wait_thread, terminated_thread)

    error = assert_raises(ClaudeAgentSDK::CLIConnectionError) { transport.write("x") }
    assert_includes error.message, "exit code"
  end

  def test_write_raises_when_exit_error
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: [], options: options)

    transport.instance_variable_set(:@ready, true)
    transport.instance_variable_set(:@stdin, FakeStdin.new)
    transport.instance_variable_set(:@exit_error, ClaudeAgentSDK::CLIConnectionError.new("boom"))

    error = assert_raises(ClaudeAgentSDK::CLIConnectionError) { transport.write("x") }
    assert_includes error.message, "exited with error"
  end

  def test_read_messages_partial_json
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("{\"type\":")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
      assert_equal [], transport.read_messages.to_a
    end
  end

  def test_read_messages_buffer_overflow
    options = build_options(max_buffer_size: 5, extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("{\"type\":\"result\"}\n")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
      assert_raises(ClaudeAgentSDK::CLIJSONDecodeError) { transport.read_messages.to_a }
    end
  end

  def test_read_messages_exit_status_error
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 1)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
      assert_raises(ClaudeAgentSDK::ProcessError) { transport.read_messages.to_a }
    end
  end

  def test_close_handles_threads_and_streams
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: [], options: options)

    stdin = FakeStdin.new
    stdout = StringIO.new("")
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
    end

    fake_thread = Class.new do
      attr_reader :killed
      def join(_timeout) = true
      def alive? = true
      def kill = @killed = true
    end.new

    transport.instance_variable_set(:@stderr_thread, fake_thread)
    transport.close

    assert_equal true, fake_thread.killed
    assert stdin.closed?
  end

  def test_find_cli_bundled
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.stub(:find_bundled_cli, "/tmp/claude") do
      assert_equal "/tmp/claude", transport.send(:find_cli)
    end
  end

  def test_find_cli_from_path
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.stub(:find_bundled_cli, nil) do
      transport.stub(:which, "/bin/claude") do
        assert_equal "/bin/claude", transport.send(:find_cli)
      end
    end
  end

  def test_find_cli_from_locations
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.stub(:find_bundled_cli, nil) do
      transport.stub(:which, nil) do
        File.stub(:file?, proc { |path| path.end_with?("claude") }) do
          assert_includes transport.send(:find_cli), "claude"
        end
      end
    end
  end

  def test_find_cli_missing
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    transport.stub(:find_bundled_cli, nil) do
      transport.stub(:which, nil) do
        File.stub(:file?, false) do
          assert_raises(ClaudeAgentSDK::CLINotFoundError) { transport.send(:find_cli) }
        end
      end
    end
  end

  def test_find_bundled_cli
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    File.stub(:file?, true) do
      assert_includes transport.send(:find_bundled_cli), "claude"
    end
  end

  def test_build_settings_value_parse_error_path
    options = build_options(settings: "{bad}", sandbox: { "enabled" => true })
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    File.stub(:file?, true) do
      File.stub(:read, JSON.generate({ "x" => 1 })) do
        settings = transport.send(:build_settings_value)
        parsed = JSON.parse(settings)
        assert_equal 1, parsed["x"]
      end
    end
  end

  def test_build_settings_value_missing_file_warns
    options = build_options(settings: "missing.json", sandbox: { "enabled" => true })
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    warnings = []
    File.stub(:file?, false) do
      transport.stub(:warn, proc { |msg| warnings << msg }) do
        transport.send(:build_settings_value)
      end
    end

    assert warnings.any? { |msg| msg.include?("Settings file not found") }
  end

  def test_normalize_hash_non_hash
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    assert_equal 123, transport.send(:normalize_hash, 123)
  end

  def test_which_returns_executable
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    dir = Dir.mktmpdir
    exe = File.join(dir, "claude")
    File.write(exe, "#!/bin/sh\n")
    File.chmod(0o755, exe)

    ENV.stub(:fetch, proc { |_key, _default = nil| dir }) do
      assert_equal exe, transport.send(:which, "claude")
    end
  ensure
    File.delete(exe) if exe && File.exist?(exe)
    Dir.rmdir(dir) if dir && Dir.exist?(dir)
  end

  def test_check_claude_version_handles_error
    options = build_options(extra_args: {})
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    Open3.stub(:capture3, proc { raise StandardError }) do
      assert_nil transport.send(:check_claude_version)
    end
  end
end
