# Claude Agent SDK for Ruby

Ruby SDK for Claude Agent. This SDK wraps the Claude Code CLI and provides a Ruby-friendly API for one-shot queries and interactive sessions.

## Installation

```bash
gem install claude-agent-sdk
```

**Prerequisites:**

- Ruby 3.1+
- Claude Code CLI available on your PATH (`claude`) or provided via
  `ClaudeAgentSDK::Options.new(cli_path: "/path/to/claude")`.

## Quick Start

```ruby
require "claude_agent_sdk"

ClaudeAgentSDK.query("What is 2 + 2?").each do |message|
  puts message.inspect
end
```

## Examples

There is a runnable example app in `examples/example_app` that uses the
local SDK via Bundler.

```bash
cd examples/example_app
bundle install
bundle exec ruby app.rb
bundle exec ruby streaming.rb
bundle exec ruby mcp_tool.rb
```

If the CLI is not on `PATH`, set it for these scripts:

```bash
CLAUDE_CLI_PATH=/path/to/claude bundle exec ruby app.rb
```

## Basic Usage: `query`

`ClaudeAgentSDK.query` returns an `Enumerator` of message objects and also
accepts a block.

```ruby
options = ClaudeAgentSDK::Options.new(
  system_prompt: "You are a helpful assistant",
  max_turns: 1,
)

ClaudeAgentSDK.query("Tell me a joke", options: options).each do |message|
  puts message.inspect
end
```

Or with a block:

```ruby
ClaudeAgentSDK.query("Tell me a joke", options: options) do |message|
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

## Interactive Sessions (`ClaudeAgentSDK::Client`)

`ClaudeAgentSDK::Client` (aliased as `ClaudeSDKClient`) supports
bidirectional conversations, interrupts, and hooks.

```ruby
ClaudeAgentSDK::Client.new.open do |client|
  client.query("Hello Claude")
  client.each_response { |message| puts message.inspect }
end
```

Or using module-level `open`:

```ruby
ClaudeAgentSDK.open do |client|
  client.query("Hello")
  client.each_response { |message| puts message.inspect }
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

options = ClaudeAgentSDK::Options.new(
  mcp_servers: { "tools" => server },
  allowed_tools: ["mcp__tools__greet"],
)

ClaudeAgentSDK::Client.new(options: options).open do |client|
  client.query("Greet Alice")
  client.receive_response.each { |msg| puts msg.inspect }
end
```

## Working Directory

```ruby
options = ClaudeAgentSDK::Options.new(cwd: "/path/to/project")
ClaudeAgentSDK.query("List files", options: options).each do |message|
  puts message.inspect
end
```

## License

MIT
