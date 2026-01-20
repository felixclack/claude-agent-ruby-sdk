# frozen_string_literal: true

module ClaudeAgentSDK
  def self.query(prompt:, options: nil, transport: nil, &block)
    options ||= ClaudeAgentOptions.new
    ENV["CLAUDE_CODE_ENTRYPOINT"] = "sdk-rb"

    client = Internal::Client.new
    enumerator = client.process_query(prompt: prompt, options: options, transport: transport)

    return enumerator unless block

    enumerator.each(&block)
    nil
  end
end
