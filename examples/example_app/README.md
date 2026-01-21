# Example App

Minimal Bundler-based app that loads the local `claude-agent-sdk` gem.

## Prerequisites

- Ruby 3.1+
- Claude Code CLI on your PATH (`claude`), or set `CLAUDE_CLI_PATH`

## Setup

```bash
cd examples/example_app
bundle install
```

## Run examples

Simple one-shot query:

```bash
bundle exec ruby app.rb
```

Interactive session:

```bash
bundle exec ruby streaming.rb
```

Custom tool via SDK MCP server:

```bash
bundle exec ruby mcp_tool.rb
```

## Optional CLI path

If the CLI isn't on PATH, pass it via env:

```bash
CLAUDE_CLI_PATH=/path/to/claude bundle exec ruby app.rb
```
