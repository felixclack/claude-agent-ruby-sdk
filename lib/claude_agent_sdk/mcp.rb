# frozen_string_literal: true

require "json"

module ClaudeAgentSDK
  SdkMcpTool = Struct.new(:name, :description, :input_schema, :handler, keyword_init: true)

  def self.tool(name, description, input_schema, &handler)
    raise ArgumentError, "tool requires a handler block" unless handler

    SdkMcpTool.new(
      name: name,
      description: description,
      input_schema: input_schema,
      handler: handler,
    )
  end

  class SdkMcpServer
    attr_reader :name, :version, :tools

    def initialize(name, version: "1.0.0", tools: [])
      @name = name
      @version = version
      @tools = tools
      @tool_map = tools.to_h { |tool| [tool.name, tool] }
    end

    def list_tools
      tools.map do |tool|
        {
          "name" => tool.name,
          "description" => tool.description,
          "inputSchema" => self.class.schema_for(tool.input_schema),
        }
      end
    end

    def tool_for(name)
      @tool_map[name]
    end

    def call_tool(name, arguments)
      tool = tool_for(name)
      raise ArgumentError, "Tool '#{name}' not found" unless tool

      tool.handler.call(arguments)
    end

    def self.schema_for(input_schema)
      return {} if input_schema.nil?

      if input_schema.is_a?(Hash)
        if input_schema.key?("type") && input_schema.key?("properties")
          input_schema
        else
          properties = {}
          input_schema.each do |param_name, param_type|
            properties[param_name] = { "type" => type_to_json(param_type) }
          end
          {
            "type" => "object",
            "properties" => properties,
            "required" => properties.keys,
          }
        end
      else
        { "type" => "object", "properties" => {} }
      end
    end

    def self.type_to_json(param_type)
      case param_type
      when String, :string
        "string"
      when Integer, :integer
        "integer"
      when Float, :number
        "number"
      when TrueClass, FalseClass, :boolean
        "boolean"
      else
        "string"
      end
    end
  end

  def self.create_sdk_mcp_server(name:, version: "1.0.0", tools: [])
    server = SdkMcpServer.new(name, version: version, tools: tools || [])
    { "type" => "sdk", "name" => name, "instance" => server }
  end
end
