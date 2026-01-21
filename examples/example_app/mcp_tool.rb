# frozen_string_literal: true

require "claude_agent_sdk"

add = ClaudeAgentSDK.tool("add", "Add two numbers", { "a" => Integer, "b" => Integer }) do |args|
  sum = args.fetch("a") + args.fetch("b")
  { "content" => [{ "type" => "text", "text" => "Sum: #{sum}" }] }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(name: "math", tools: [add])

options = ClaudeAgentSDK::Options.new(
  cli_path: ENV["CLAUDE_CLI_PATH"],
  mcp_servers: { "math" => server },
  allowed_tools: ["mcp__math__add"],
)

ClaudeAgentSDK::Client.new(options: options).open do |client|
  client.query("Add 2 and 3")
  client.each_response { |message| puts message.inspect }
end
