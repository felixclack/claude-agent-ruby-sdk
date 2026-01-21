# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
ENV["CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"] = "1"

require "minitest/autorun"
begin
  require "minitest/mock"
rescue LoadError
  # Minitest 6 no longer ships mock; provide a minimal stub helper below.
end
require "json"
require "thread"
require "coverage"

Coverage.start(lines: true)

Minitest.after_run do
  result = Coverage.result
  lib_root = File.expand_path("../lib", __dir__)
  missed = {}

  result.each do |path, data|
    next unless path.start_with?(lib_root)

    lines = if data.is_a?(Hash)
              data[:lines] || data["lines"]
            else
              data
            end
    next unless lines

    lines.each_with_index do |count, idx|
      next if count.nil?
      if count.zero?
        (missed[path] ||= []) << (idx + 1)
      end
    end
  end

  if missed.any?
    warn "Coverage check failed. Missed lines:"
    missed.each do |path, lines|
      warn "#{path}:#{lines.join(',')}"
    end
    exit 1
  end
end

require_relative "../lib/claude_agent_sdk"

unless Object.method_defined?(:stub)
  class Object
    def stub(method_name, new_value, &block)
      eigen = class << self; self; end
      had_singleton = eigen.method_defined?(method_name) || eigen.private_method_defined?(method_name)
      original = eigen.instance_method(method_name) if had_singleton

      eigen.define_method(method_name) do |*args, **kwargs, &method_block|
        if new_value.respond_to?(:call)
          if kwargs.empty?
            new_value.call(*args, &method_block)
          else
            new_value.call(*args, **kwargs, &method_block)
          end
        else
          new_value
        end
      end

      begin
        block.call
      ensure
        if had_singleton
          eigen.define_method(method_name, original)
        else
          eigen.send(:remove_method, method_name)
        end
      end
    end
  end
end

class FakeTransport < ClaudeAgentSDK::Transport
  attr_reader :writes, :ended, :closed

  def initialize(messages: [], auto_end: true, &write_handler)
    @incoming = Queue.new
    messages.each { |msg| @incoming << msg }
    @auto_end = auto_end
    finish if auto_end
    @writes = []
    @write_handler = write_handler
    @ready = false
  end

  def connect
    @ready = true
  end

  def write(data)
    @writes << data
    @write_handler.call(data, self) if @write_handler
  end

  def read_messages
    Enumerator.new do |yielder|
      loop do
        msg = @incoming.pop
        break if msg == :end

        yielder << msg
      end
    end
  end

  def push_message(message)
    @incoming << message
  end

  def finish
    @incoming << :end
  end

  def end_input
    @ended = true
  end

  def close
    @closed = true
  end

  def ready?
    @ready
  end
end

class FakeStdin
  attr_reader :data

  def initialize
    @data = +""
    @closed = false
  end

  def write(value)
    @data << value
  end

  def flush; end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  def sync=(_value); end
end

class FakeWaitThread
  FakeStatus = Struct.new(:exitstatus) do
    def success?
      exitstatus == 0
    end
  end

  attr_reader :pid

  def initialize(exitstatus: 0)
    @status = FakeStatus.new(exitstatus)
    @pid = 12_345
  end

  def value
    @status
  end

  def join(_timeout = nil)
    nil
  end

  def alive?
    false
  end
end
