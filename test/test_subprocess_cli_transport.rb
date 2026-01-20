# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "open3"
require "tempfile"

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
end
