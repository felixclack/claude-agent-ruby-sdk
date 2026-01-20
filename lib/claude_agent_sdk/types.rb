# frozen_string_literal: true

module ClaudeAgentSDK
  # Permission modes
  PERMISSION_MODES = %w[default acceptEdits plan bypassPermissions].freeze

  # SDK beta features
  SDK_BETAS = %w[context-1m-2025-08-07].freeze

  # Agent definitions
  SETTING_SOURCES = %w[user project local].freeze

  SystemPromptPreset = Struct.new(:type, :preset, :append, keyword_init: true)
  ToolsPreset = Struct.new(:type, :preset, keyword_init: true)

  AgentDefinition = Struct.new(:description, :prompt, :tools, :model, keyword_init: true) do
    def to_h
      {
        "description" => description,
        "prompt" => prompt,
        "tools" => tools,
        "model" => model,
      }.compact
    end
  end

  PermissionRuleValue = Struct.new(:tool_name, :rule_content, keyword_init: true) do
    def to_h
      {
        "toolName" => tool_name,
        "ruleContent" => rule_content,
      }
    end
  end

  class PermissionUpdate
    attr_reader :type, :rules, :behavior, :mode, :directories, :destination

    def initialize(type:, rules: nil, behavior: nil, mode: nil, directories: nil, destination: nil)
      @type = type
      @rules = rules
      @behavior = behavior
      @mode = mode
      @directories = directories
      @destination = destination
    end

    def to_h
      result = { "type" => type }
      result["destination"] = destination if destination

      case type
      when "addRules", "replaceRules", "removeRules"
        if rules
          result["rules"] = rules.map { |rule| rule.respond_to?(:to_h) ? rule.to_h : rule }
        end
        result["behavior"] = behavior if behavior
      when "setMode"
        result["mode"] = mode if mode
      when "addDirectories", "removeDirectories"
        result["directories"] = directories if directories
      end

      result
    end
  end

  ToolPermissionContext = Struct.new(:signal, :suggestions, keyword_init: true)

  class PermissionResultAllow
    attr_reader :behavior, :updated_input, :updated_permissions

    def initialize(updated_input: nil, updated_permissions: nil)
      @behavior = "allow"
      @updated_input = updated_input
      @updated_permissions = updated_permissions
    end
  end

  class PermissionResultDeny
    attr_reader :behavior, :message, :interrupt

    def initialize(message: "", interrupt: false)
      @behavior = "deny"
      @message = message
      @interrupt = interrupt
    end
  end

  HookMatcher = Struct.new(:matcher, :hooks, :timeout, keyword_init: true) do
    def initialize(matcher: nil, hooks: [], timeout: nil)
      super
    end
  end

  # Content block types
  TextBlock = Struct.new(:text, keyword_init: true)
  ThinkingBlock = Struct.new(:thinking, :signature, keyword_init: true)
  ToolUseBlock = Struct.new(:id, :name, :input, keyword_init: true)
  ToolResultBlock = Struct.new(:tool_use_id, :content, :is_error, keyword_init: true)

  # Message types
  UserMessage = Struct.new(:content, :uuid, :parent_tool_use_id, keyword_init: true)
  AssistantMessage = Struct.new(:content, :model, :parent_tool_use_id, :error, keyword_init: true)
  SystemMessage = Struct.new(:subtype, :data, keyword_init: true)
  ResultMessage = Struct.new(
    :subtype,
    :duration_ms,
    :duration_api_ms,
    :is_error,
    :num_turns,
    :session_id,
    :total_cost_usd,
    :usage,
    :result,
    :structured_output,
    keyword_init: true
  )
  StreamEvent = Struct.new(:uuid, :session_id, :event, :parent_tool_use_id, keyword_init: true)

  class ClaudeAgentOptions
    attr_accessor :tools,
                  :allowed_tools,
                  :system_prompt,
                  :mcp_servers,
                  :permission_mode,
                  :continue_conversation,
                  :resume,
                  :max_turns,
                  :max_budget_usd,
                  :disallowed_tools,
                  :model,
                  :fallback_model,
                  :betas,
                  :permission_prompt_tool_name,
                  :cwd,
                  :cli_path,
                  :settings,
                  :add_dirs,
                  :env,
                  :extra_args,
                  :max_buffer_size,
                  :debug_stderr,
                  :stderr,
                  :can_use_tool,
                  :hooks,
                  :user,
                  :include_partial_messages,
                  :fork_session,
                  :agents,
                  :setting_sources,
                  :sandbox,
                  :plugins,
                  :max_thinking_tokens,
                  :output_format,
                  :enable_file_checkpointing

    def initialize(
      tools: nil,
      allowed_tools: [],
      system_prompt: nil,
      mcp_servers: {},
      permission_mode: nil,
      continue_conversation: false,
      resume: nil,
      max_turns: nil,
      max_budget_usd: nil,
      disallowed_tools: [],
      model: nil,
      fallback_model: nil,
      betas: [],
      permission_prompt_tool_name: nil,
      cwd: nil,
      cli_path: nil,
      settings: nil,
      add_dirs: [],
      env: {},
      extra_args: {},
      max_buffer_size: nil,
      debug_stderr: $stderr,
      stderr: nil,
      can_use_tool: nil,
      hooks: nil,
      user: nil,
      include_partial_messages: false,
      fork_session: false,
      agents: nil,
      setting_sources: nil,
      sandbox: nil,
      plugins: [],
      max_thinking_tokens: nil,
      output_format: nil,
      enable_file_checkpointing: false
    )
      @tools = tools
      @allowed_tools = allowed_tools
      @system_prompt = system_prompt
      @mcp_servers = mcp_servers
      @permission_mode = permission_mode
      @continue_conversation = continue_conversation
      @resume = resume
      @max_turns = max_turns
      @max_budget_usd = max_budget_usd
      @disallowed_tools = disallowed_tools
      @model = model
      @fallback_model = fallback_model
      @betas = betas
      @permission_prompt_tool_name = permission_prompt_tool_name
      @cwd = cwd
      @cli_path = cli_path
      @settings = settings
      @add_dirs = add_dirs
      @env = env
      @extra_args = extra_args
      @max_buffer_size = max_buffer_size
      @debug_stderr = debug_stderr
      @stderr = stderr
      @can_use_tool = can_use_tool
      @hooks = hooks
      @user = user
      @include_partial_messages = include_partial_messages
      @fork_session = fork_session
      @agents = agents
      @setting_sources = setting_sources
      @sandbox = sandbox
      @plugins = plugins
      @max_thinking_tokens = max_thinking_tokens
      @output_format = output_format
      @enable_file_checkpointing = enable_file_checkpointing
    end

    def merge(overrides = nil, **kwargs)
      updates = {}
      updates.merge!(overrides) if overrides.is_a?(Hash)
      updates.merge!(kwargs) if kwargs.any?

      duped = dup
      updates.each do |key, value|
        writer = "#{key}="
        duped.public_send(writer, value) if duped.respond_to?(writer)
      end
      duped
    end

    alias with merge
  end
end
