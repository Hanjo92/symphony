defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.{InternalTool, McpBridge, McpRegistry}

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    cond do
      InternalTool.supports?(tool) ->
        InternalTool.execute(tool, arguments, opts)

      match?({:ok, _}, McpRegistry.lookup_tool(tool, opts)) ->
        McpBridge.execute(tool, arguments, opts)

      true ->
        unsupported_tool_response(tool)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    InternalTool.tool_specs() ++ McpRegistry.tool_specs()
  end

  defp unsupported_tool_response(tool) do
    %{
      "success" => false,
      "output" =>
        Jason.encode!(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
            "supportedTools" => supported_tool_names()
          }
        }),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" =>
            Jason.encode!(%{
              "error" => %{
                "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
                "supportedTools" => supported_tool_names()
              }
            })
        }
      ]
    }
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
