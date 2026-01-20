# Claude Agent SDK for Ruby

Ruby SDK for Claude Agent. This SDK wraps the Claude Code CLI and provides a Ruby-friendly API for one-shot queries and interactive sessions.

## Installation

```bash
gem install claude-agent-sdk
```

**Prerequisites:**

- Ruby 3.1+
- Claude Code CLI available on your PATH (`claude`) or provided via `ClaudeAgentOptions`.

## Quick Start

```ruby
require "claude_agent_sdk"

ClaudeAgentSDK.query(prompt: "What is 2 + 2?").each do |message|
  puts message.inspect
end
```

## Basic Usage: `query`

`ClaudeAgentSDK.query` returns an `Enumerator` of message objects.

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  system_prompt: "You are a helpful assistant",
  max_turns: 1,
)

ClaudeAgentSDK.query(prompt: "Tell me a joke", options: options).each do |message|
  puts message.inspect
end
```

### Streaming Mode (unidirectional)

Pass an enumerable of message hashes to stream multiple prompts in a single session:

```ruby
prompts = [
  { "type" => "user", "message" => { "role" => "user", "content" => "Hello" } },
  { "type" => "user", "message" => { "role" => "user", "content" => "How are you?" } },
]

ClaudeAgentSDK.query(prompt: prompts).each do |message|
  puts message.inspect
end
```

## ClaudeSDKClient (interactive sessions)

`ClaudeSDKClient` supports bidirectional conversations, interrupts, and hooks.

```ruby
client = ClaudeAgentSDK::ClaudeSDKClient.new
client.connect

client.query("Hello Claude")
client.receive_response.each do |message|
  puts message.inspect
end

client.disconnect
```

Or using a convenience block:

```ruby
ClaudeAgentSDK::ClaudeSDKClient.new.with do |client|
  client.query("Hello")
  client.receive_response.each do |message|
    puts message.inspect
  end
end
```

## Custom Tools (SDK MCP Servers)

Define tools in Ruby and register them as an in-process MCP server:

```ruby
greet = ClaudeAgentSDK.tool("greet", "Greet a user", { "name" => String }) do |args|
  {
    "content" => [
      { "type" => "text", "text" => "Hello, #{args["name"]}!" }
    ]
  }
end

server = ClaudeAgentSDK.create_sdk_mcp_server(
  name: "my-tools",
  tools: [greet],
)

options = ClaudeAgentSDK::ClaudeAgentOptions.new(
  mcp_servers: { "tools" => server },
  allowed_tools: ["mcp__tools__greet"],
)

ClaudeAgentSDK::ClaudeSDKClient.new(options: options).with do |client|
  client.query("Greet Alice")
  client.receive_response.each { |msg| puts msg.inspect }
end
```

## Working Directory

```ruby
options = ClaudeAgentSDK::ClaudeAgentOptions.new(cwd: "/path/to/project")
ClaudeAgentSDK.query(prompt: "List files", options: options).each do |message|
  puts message.inspect
end
```

## License

MIT
