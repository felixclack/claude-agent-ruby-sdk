# frozen_string_literal: true

require "claude_agent_sdk"

options = ClaudeAgentSDK::Options.new(cli_path: ENV["CLAUDE_CLI_PATH"])

ClaudeAgentSDK::Client.new(options: options).open do |client|
  client.query("Hello from the streaming client")
  client.each_response { |message| puts message.inspect }
end
