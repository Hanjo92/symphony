defmodule SymphonyElixir.Codex.McpBridge do
  @moduledoc """
  Executes MCP-backed tool calls through a pluggable bridge executor.
  """

  alias SymphonyElixir.Codex.{McpHttpTransport, McpRegistry}

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool_name, arguments, opts \\ []) do
    case McpRegistry.lookup_tool(tool_name, opts) do
      {:ok, registration} ->
        executor = Keyword.get(opts, :mcp_executor, &default_executor/2)

        case executor.(registration, arguments) do
          {:ok, payload} -> success_response(payload)
          {:error, reason} -> failure_response(tool_error_payload(reason, registration))
          payload -> success_response(payload)
        end

      :error ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported MCP bridge tool: #{inspect(tool_name)}.",
            "supportedTools" => Enum.map(McpRegistry.tool_specs(opts), & &1["name"])
          }
        })
    end
  end

  defp default_executor(registration, arguments), do: McpHttpTransport.call_tool(registration, arguments)

  defp success_response(payload), do: dynamic_tool_response(true, encode_payload(payload))
  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:mcp_bridge_not_configured, registration) do
    %{
      "error" => %{
        "message" => "MCP bridge executor is not configured for #{tool_identity(registration)}."
      }
    }
  end

  defp tool_error_payload({:mcp_transport, reason}, registration) do
    %{
      "error" => %{
        "message" => "MCP bridge transport failed for #{tool_identity(registration)}.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:tool_error, payload}, registration) do
    %{
      "error" => %{
        "message" => "MCP bridge tool returned an error for #{tool_identity(registration)}.",
        "details" => payload
      }
    }
  end

  defp tool_error_payload(reason, registration) do
    %{
      "error" => %{
        "message" => "MCP bridge execution failed for #{tool_identity(registration)}.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_identity(%{"server" => server_name, "tool" => %{"name" => tool_name}}) do
    "#{server_name}:#{tool_name}"
  end

  defp tool_identity(_registration), do: "unknown_tool"
end
