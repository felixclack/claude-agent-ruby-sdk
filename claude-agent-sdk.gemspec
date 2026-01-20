# frozen_string_literal: true

require_relative "lib/claude_agent_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "claude-agent-sdk"
  spec.version = ClaudeAgentSDK::VERSION
  spec.summary = "Ruby SDK for Claude Agent CLI"
  spec.description = "Ruby SDK for interacting with Claude Code via the Claude Agent CLI."
  spec.authors = ["Anthropic"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "homepage_uri" => "https://github.com/anthropics/claude-agent-sdk-python",
    "source_code_uri" => "https://github.com/anthropics/claude-agent-sdk-python",
  }
end
