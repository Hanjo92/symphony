defmodule SymphonyElixir.Codex.McpRegistry do
  @moduledoc """
  Registry for MCP-backed dynamic tools configured through the workflow.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Codex.McpProviders.Todoist

  @default_input_schema %{
    "type" => "object",
    "additionalProperties" => true
  }

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    opts
    |> configured_servers()
    |> Enum.flat_map(fn {server_name, server_config} ->
      Enum.map(Map.get(server_config, "allowed_tools", []), fn tool ->
        tool
        |> Map.take(["name", "description", "inputSchema"])
        |> Map.put("server", server_name)
      end)
    end)
  end

  @spec lookup_tool(String.t() | nil, keyword()) :: {:ok, map()} | :error
  def lookup_tool(tool_name, opts \\ [])

  def lookup_tool(tool_name, _opts) when not is_binary(tool_name), do: :error

  def lookup_tool(tool_name, opts) do
    trimmed_name = String.trim(tool_name)

    opts
    |> configured_servers()
    |> Enum.find_value(:error, fn {server_name, server_config} ->
      Enum.find_value(Map.get(server_config, "allowed_tools", []), :error, fn tool ->
        if Map.get(tool, "name") == trimmed_name do
          {:ok,
           %{
             "server" => server_name,
             "tool" => tool,
             "server_config" => server_config
           }}
        else
          false
        end
      end)
    end)
  end

  @spec normalize_servers(term()) :: map()
  def normalize_servers(nil), do: %{}

  def normalize_servers(servers) when is_map(servers) do
    Enum.reduce(servers, %{}, fn {server_name, server_config}, acc ->
      normalized_name = server_name |> to_string() |> String.trim()

      if normalized_name == "" or not is_map(server_config) do
        acc
      else
        Map.put(acc, normalized_name, normalize_server(server_config))
      end
    end)
  end

  def normalize_servers(_servers), do: %{}

  defp normalize_server(server_config) do
    normalized_allowed_tools = normalize_allowed_tools(Map.get(server_config, "allowed_tools"))

    normalized_server =
      server_config
      |> Map.put("provider", normalize_optional_string(Map.get(server_config, "provider")))
      |> Map.put("transport", normalize_optional_string(Map.get(server_config, "transport")))
      |> Map.put("url", normalize_optional_string(Map.get(server_config, "url")))
      |> Map.put("auth", normalize_optional_map(Map.get(server_config, "auth")))
      |> Map.put("allowed_tools", normalized_allowed_tools)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case normalized_server["provider"] do
      "todoist" -> Todoist.normalize_server(normalized_server, normalized_allowed_tools)
      _ -> normalized_server
    end
  end

  defp normalize_allowed_tools(nil), do: []

  defp normalize_allowed_tools(allowed_tools) when is_list(allowed_tools) do
    allowed_tools
    |> Enum.map(&normalize_allowed_tool/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_allowed_tools(_allowed_tools), do: []

  defp normalize_allowed_tool(tool_name) when is_binary(tool_name) do
    case String.trim(tool_name) do
      "" ->
        nil

      trimmed ->
        %{
          "name" => trimmed,
          "description" => "MCP bridged tool exposed by Symphony.",
          "inputSchema" => @default_input_schema
        }
    end
  end

  defp normalize_allowed_tool(tool_config) when is_map(tool_config) do
    case normalize_optional_string(Map.get(tool_config, "name")) do
      nil ->
        nil

      tool_name ->
        %{
          "name" => tool_name,
          "description" =>
            normalize_optional_string(Map.get(tool_config, "description")) ||
              "MCP bridged tool exposed by Symphony.",
          "inputSchema" =>
            normalize_input_schema(
              Map.get(tool_config, "inputSchema") || Map.get(tool_config, "input_schema")
            ),
          "mode" => normalize_optional_string(Map.get(tool_config, "mode"))
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    end
  end

  defp normalize_allowed_tool(_tool_config), do: nil

  defp normalize_input_schema(schema) when is_map(schema), do: schema
  defp normalize_input_schema(_schema), do: @default_input_schema

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_optional_map(value) when is_map(value), do: value
  defp normalize_optional_map(_value), do: nil

  defp configured_servers(opts) do
    case Keyword.fetch(opts, :servers) do
      {:ok, servers} -> normalize_servers(servers)
      :error -> normalize_servers(Config.settings!().mcp.servers)
    end
  end
end
