# frozen_string_literal: true

require "claude_agent_sdk"

options = ClaudeAgentSDK::Options.new(
  cli_path: ENV["CLAUDE_CLI_PATH"],
  system_prompt: "Be concise",
  max_turns: 1,
)

ClaudeAgentSDK.query("What is 2 + 2?", options: options).each do |message|
  puts message.inspect
end
