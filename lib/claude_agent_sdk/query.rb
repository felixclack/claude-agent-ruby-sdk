# frozen_string_literal: true

module ClaudeAgentSDK
  def self.query(prompt = nil, options: nil, transport: nil, **kwargs, &block)
    prompt = kwargs.fetch(:prompt, prompt)
    options = kwargs.fetch(:options, options)
    transport = kwargs.fetch(:transport, transport)

    raise ArgumentError, "prompt is required" if prompt.nil?

    options ||= ClaudeAgentOptions.new
    ENV["CLAUDE_CODE_ENTRYPOINT"] = "sdk-rb"

    client = Internal::Client.new
    enumerator = client.process_query(prompt: prompt, options: options, transport: transport)

    return enumerator unless block

    enumerator.each(&block)
    nil
  end
end
