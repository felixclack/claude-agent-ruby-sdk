# frozen_string_literal: true

require_relative "claude_agent_sdk/version"
require_relative "claude_agent_sdk/errors"
require_relative "claude_agent_sdk/cli_version"
require_relative "claude_agent_sdk/types"
require_relative "claude_agent_sdk/mcp"
require_relative "claude_agent_sdk/transport"
require_relative "claude_agent_sdk/transport/subprocess_cli"
require_relative "claude_agent_sdk/message_parser"
require_relative "claude_agent_sdk/internal/query"
require_relative "claude_agent_sdk/internal/client"
require_relative "claude_agent_sdk/query"
require_relative "claude_agent_sdk/client"

module ClaudeAgentSDK
  Client = ClaudeSDKClient
  Options = ClaudeAgentOptions

  def self.open(options: nil, transport: nil, prompt: nil)
    client = ClaudeSDKClient.new(options: options, transport: transport)
    return client unless block_given?

    client.connect(prompt: prompt)
    begin
      yield client
    ensure
      client.disconnect
    end
  end
end
