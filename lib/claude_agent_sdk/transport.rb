# frozen_string_literal: true

module ClaudeAgentSDK
  class Transport
    def connect
      raise NotImplementedError, "connect must be implemented"
    end

    def write(_data)
      raise NotImplementedError, "write must be implemented"
    end

    def read_messages
      raise NotImplementedError, "read_messages must be implemented"
    end

    def close
      raise NotImplementedError, "close must be implemented"
    end

    def ready?
      raise NotImplementedError, "ready? must be implemented"
    end

    def is_ready
      ready?
    end

    def end_input
      raise NotImplementedError, "end_input must be implemented"
    end
  end
end
