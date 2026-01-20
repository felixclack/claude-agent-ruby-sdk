# frozen_string_literal: true

require_relative "test_helper"

class TestErrors < Minitest::Test
  def test_cli_not_found_error_message
    error = ClaudeAgentSDK::CLINotFoundError.new("Missing", cli_path: "/tmp/claude")
    assert_includes error.message, "Missing"
    assert_includes error.message, "/tmp/claude"
  end

  def test_process_error_includes_exit_code_and_stderr
    error = ClaudeAgentSDK::ProcessError.new("Boom", exit_code: 2, stderr: "bad")
    assert_includes error.message, "exit code: 2"
    assert_includes error.message, "bad"
    assert_equal 2, error.exit_code
    assert_equal "bad", error.stderr
  end

  def test_cli_json_decode_error
    error = ClaudeAgentSDK::CLIJSONDecodeError.new("{bad", StandardError.new("nope"))
    assert_includes error.message, "Failed to decode JSON"
    assert_equal "{bad", error.line
  end

  def test_message_parse_error
    error = ClaudeAgentSDK::MessageParseError.new("oops", data: { "x" => 1 })
    assert_equal({ "x" => 1 }, error.data)
    assert_includes error.message, "oops"
  end
end
