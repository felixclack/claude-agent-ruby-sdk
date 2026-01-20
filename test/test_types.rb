# frozen_string_literal: true

require_relative "test_helper"

class TestTypes < Minitest::Test
  def test_agent_definition_to_h
    agent = ClaudeAgentSDK::AgentDefinition.new(
      description: "Test",
      prompt: "Hello",
      tools: ["Bash"],
      model: nil,
    )

    assert_equal(
      {
        "description" => "Test",
        "prompt" => "Hello",
        "tools" => ["Bash"],
      },
      agent.to_h,
    )
  end

  def test_permission_rule_value_to_h
    rule = ClaudeAgentSDK::PermissionRuleValue.new(tool_name: "Bash", rule_content: "no")
    assert_equal({ "toolName" => "Bash", "ruleContent" => "no" }, rule.to_h)
  end

  def test_permission_update_variants
    rule = ClaudeAgentSDK::PermissionRuleValue.new(tool_name: "Read", rule_content: "deny")

    update = ClaudeAgentSDK::PermissionUpdate.new(
      type: "addRules",
      rules: [rule],
      behavior: "deny",
      destination: "session",
    )

    assert_equal(
      {
        "type" => "addRules",
        "destination" => "session",
        "rules" => [{ "toolName" => "Read", "ruleContent" => "deny" }],
        "behavior" => "deny",
      },
      update.to_h,
    )

    mode_update = ClaudeAgentSDK::PermissionUpdate.new(type: "setMode", mode: "default")
    assert_equal({ "type" => "setMode", "mode" => "default" }, mode_update.to_h)

    dir_update = ClaudeAgentSDK::PermissionUpdate.new(type: "addDirectories", directories: ["/tmp"])
    assert_equal({ "type" => "addDirectories", "directories" => ["/tmp"] }, dir_update.to_h)
  end

  def test_permission_results
    allow = ClaudeAgentSDK::PermissionResultAllow.new(updated_input: { "x" => 1 })
    assert_equal "allow", allow.behavior
    assert_equal({ "x" => 1 }, allow.updated_input)

    deny = ClaudeAgentSDK::PermissionResultDeny.new(message: "No", interrupt: true)
    assert_equal "deny", deny.behavior
    assert_equal "No", deny.message
    assert_equal true, deny.interrupt
  end

  def test_claude_agent_options_with
    options = ClaudeAgentSDK::ClaudeAgentOptions.new(system_prompt: "a", max_turns: 1)
    updated = options.with(system_prompt: "b", max_turns: 2)

    assert_equal "a", options.system_prompt
    assert_equal 1, options.max_turns
    assert_equal "b", updated.system_prompt
    assert_equal 2, updated.max_turns
  end
end
