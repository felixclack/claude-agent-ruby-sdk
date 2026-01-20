# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "open3"

class ChunkedStdout
  def initialize(chunks)
    @chunks = chunks
  end

  def each_line
    return enum_for(:each_line) unless block_given?

    @chunks.each { |chunk| yield chunk }
  end

  def close; end

  def closed?
    false
  end
end

class TestSubprocessBuffering < Minitest::Test
  DEFAULT_CLI_PATH = "/bin/echo"

  def build_options(overrides = {})
    ClaudeAgentSDK::ClaudeAgentOptions.new(**{ cli_path: DEFAULT_CLI_PATH, extra_args: {} }.merge(overrides))
  end

  def build_transport(stdout_chunks, max_buffer_size: nil)
    options = build_options(max_buffer_size: max_buffer_size)
    transport = ClaudeAgentSDK::Transport::SubprocessCLITransport.new(prompt: "hi", options: options)

    stdin = FakeStdin.new
    stdout = ChunkedStdout.new(stdout_chunks)
    stderr = StringIO.new("")
    wait_thread = FakeWaitThread.new(exitstatus: 0)

    Open3.stub(:popen3, [stdin, stdout, stderr, wait_thread]) do
      transport.connect
    end

    transport
  end

  def test_multiple_json_objects_on_single_line
    json1 = JSON.generate({ "type" => "message", "id" => "msg1", "content" => "First" })
    json2 = JSON.generate({ "type" => "result", "id" => "res1", "status" => "done" })
    transport = build_transport(["#{json1}\n#{json2}"])

    messages = transport.read_messages.to_a
    assert_equal 2, messages.size
    assert_equal "message", messages[0]["type"]
    assert_equal "result", messages[1]["type"]
  end

  def test_json_with_embedded_newlines
    json1 = JSON.generate({ "type" => "message", "content" => "Line 1\nLine 2" })
    json2 = JSON.generate({ "type" => "result", "data" => "Some\nContent" })
    transport = build_transport(["#{json1}\n#{json2}"])

    messages = transport.read_messages.to_a
    assert_equal "Line 1\nLine 2", messages[0]["content"]
    assert_equal "Some\nContent", messages[1]["data"]
  end

  def test_multiple_newlines_between_objects
    json1 = JSON.generate({ "type" => "message", "id" => "msg1" })
    json2 = JSON.generate({ "type" => "result", "id" => "res1" })
    transport = build_transport(["#{json1}\n\n\n#{json2}"])

    messages = transport.read_messages.to_a
    assert_equal 2, messages.size
    assert_equal "msg1", messages[0]["id"]
    assert_equal "res1", messages[1]["id"]
  end

  def test_split_json_across_multiple_reads
    json = JSON.generate({
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "x" * 1000 },
          { "type" => "tool_use", "id" => "tool_123", "name" => "Read", "input" => { "file_path" => "/test.txt" } },
        ],
      },
    })

    transport = build_transport([json[0, 100], json[100, 150], json[250..]])

    messages = transport.read_messages.to_a
    assert_equal 1, messages.size
    assert_equal "assistant", messages[0]["type"]
    assert_equal 2, messages[0].dig("message", "content").size
  end

  def test_large_minified_json
    large_data = { "data" => (0...1000).map { |i| { "id" => i, "value" => "x" * 100 } } }
    json = JSON.generate({
      "type" => "user",
      "message" => {
        "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "toolu_123", "content" => JSON.generate(large_data) },
        ],
      },
    })

    chunk_size = 64 * 1024
    chunks = json.scan(/.{1,#{chunk_size}}/m)
    transport = build_transport(chunks)

    messages = transport.read_messages.to_a
    assert_equal 1, messages.size
    assert_equal "user", messages[0]["type"]
    assert_equal "toolu_123", messages[0].dig("message", "content", 0, "tool_use_id")
  end

  def test_buffer_size_exceeded
    limit = 128
    huge_incomplete = "{\"data\":\"#{'x' * (limit + 10)}"
    transport = build_transport([huge_incomplete], max_buffer_size: limit)

    assert_raises(ClaudeAgentSDK::CLIJSONDecodeError) do
      transport.read_messages.to_a
    end
  end

  def test_mixed_complete_and_split_json
    msg1 = JSON.generate({ "type" => "system", "subtype" => "start" })
    large = JSON.generate({ "type" => "assistant", "message" => { "content" => [{ "type" => "text", "text" => "y" * 5000 }] } })
    msg3 = JSON.generate({ "type" => "system", "subtype" => "end" })

    chunks = [
      "#{msg1}\n",
      large[0, 1000],
      large[1000, 2000],
      "#{large[3000..]}\n#{msg3}",
    ]
    transport = build_transport(chunks)

    messages = transport.read_messages.to_a
    assert_equal 3, messages.size
    assert_equal "start", messages[0]["subtype"]
    assert_equal 5000, messages[1].dig("message", "content", 0, "text").size
    assert_equal "end", messages[2]["subtype"]
  end
end
