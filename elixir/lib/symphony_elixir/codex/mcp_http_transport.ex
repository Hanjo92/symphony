defmodule SymphonyElixir.Codex.McpHttpTransport do
  @moduledoc """
  Minimal Streamable HTTP MCP client used by Symphony's dynamic tool bridge.
  """

  @protocol_version "2025-06-18"
  @client_name "symphony-elixir"

  @spec call_tool(map(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def call_tool(registration, arguments, opts \\ []) when is_map(registration) and is_list(opts) do
    request_fun = Keyword.get(opts, :mcp_http_request, &Req.request/1)
    server_config = registration["server_config"] || %{}
    tool_name = remote_tool_name(registration)
    arguments = normalize_arguments(arguments)

    with {:ok, url} <- fetch_url(server_config),
         {:ok, base_headers} <- build_headers(server_config),
         {:ok, initialize_response} <- initialize(url, base_headers, request_fun),
         {:ok, session_headers} <- session_headers(initialize_response, base_headers),
         :ok <- send_initialized(url, session_headers, request_fun),
         {:ok, tool_response} <- call_remote_tool(url, tool_name, arguments, session_headers, request_fun) do
      maybe_close_session(url, session_headers, request_fun)
      normalize_tool_response(tool_response)
    else
      {:error, reason} ->
        {:error, {:mcp_transport, reason}}
    end
  end

  defp initialize(url, headers, request_fun) do
    post_json(
      url,
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{
            "name" => @client_name,
            "version" => client_version()
          }
        }
      },
      headers,
      request_fun
    )
  end

  defp send_initialized(url, headers, request_fun) do
    case post_json(
           url,
           %{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized",
             "params" => %{}
           },
           headers,
           request_fun
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: 202}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_remote_tool(url, tool_name, arguments, headers, request_fun) do
    post_json(
      url,
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => tool_name,
          "arguments" => arguments
        }
      },
      headers,
      request_fun
    )
  end

  defp post_json(url, body, headers, request_fun) do
    req_opts = [
      method: :post,
      url: url,
      headers: headers,
      json: body,
      receive_timeout: 30_000
    ]

    case request_fun.(req_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_http_result, other}}
    end
  end

  defp session_headers(%Req.Response{} = response, base_headers) do
    negotiated_version =
      response.body
      |> extract_result()
      |> Map.get("protocolVersion", @protocol_version)

    headers =
      base_headers
      |> put_header("mcp-protocol-version", negotiated_version)
      |> maybe_put_header("mcp-session-id", response_header(response.headers, "mcp-session-id"))

    {:ok, headers}
  end

  defp normalize_tool_response(%Req.Response{body: body}) when is_map(body) do
    case extract_result(body) do
      %{"isError" => true} = result ->
        {:error, {:tool_error, normalize_error_payload(result)}}

      %{"structuredContent" => structured} ->
        {:ok, structured}

      %{"content" => [%{"type" => "text", "text" => text}]} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
        end

      %{} = result ->
        {:ok, result}

      other ->
        {:ok, other}
    end
  end

  defp normalize_tool_response(%Req.Response{body: body}), do: {:ok, body}

  defp normalize_error_payload(%{"content" => content} = result) when is_list(content) do
    text =
      content
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(Map.get(&1, "type") == "text"))
      |> Enum.map(&Map.get(&1, "text"))
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n\n")

    %{
      "message" =>
        if(text == "", do: "Remote MCP tool returned an error.", else: text),
      "result" => result
    }
  end

  defp normalize_error_payload(result), do: %{"message" => "Remote MCP tool returned an error.", "result" => result}

  defp maybe_close_session(url, headers, request_fun) do
    case header_value(headers, "mcp-session-id") do
      nil ->
        :ok

      _session_id ->
        _ =
          request_fun.(
            method: :delete,
            url: url,
            headers: headers,
            receive_timeout: 5_000
          )

        :ok
    end
  end

  defp fetch_url(server_config) do
    case server_config["url"] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_mcp_server_url}
    end
  end

  defp build_headers(server_config) do
    with {:ok, auth_headers} <- auth_headers(server_config["auth"]) do
      {:ok,
       [
         {"accept", "application/json, text/event-stream"},
         {"content-type", "application/json"},
         {"user-agent", @client_name}
         | auth_headers
       ]}
    end
  end

  defp auth_headers(nil), do: {:ok, []}

  defp auth_headers(%{} = auth) do
    type = auth["type"] || auth[:type]

    cond do
      type in [nil, "", "none"] ->
        {:ok, extra_headers(auth)}

      type == "bearer" ->
        with {:ok, token} <- auth_token(auth) do
          {:ok, [{"authorization", "Bearer #{token}"} | extra_headers(auth)]}
        end

      true ->
        {:error, {:unsupported_auth_type, type}}
    end
  end

  defp auth_headers(_auth), do: {:error, :invalid_auth_config}

  defp auth_token(auth) do
    cond do
      is_binary(auth["token"]) and String.trim(auth["token"]) != "" ->
        {:ok, String.trim(auth["token"])}

      is_binary(auth[:token]) and String.trim(auth[:token]) != "" ->
        {:ok, String.trim(auth[:token])}

      is_binary(auth["env"]) and String.trim(auth["env"]) != "" ->
        env_token(auth["env"])

      is_binary(auth[:env]) and String.trim(auth[:env]) != "" ->
        env_token(auth[:env])

      true ->
        {:error, :missing_auth_token}
    end
  end

  defp env_token(env_name) do
    case System.get_env(String.trim(env_name)) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, {:missing_auth_env, env_name}}
    end
  end

  defp extra_headers(auth) do
    auth
    |> Map.get("headers", %{})
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{String.downcase(String.trim(key)), String.trim(value)}]
      _ -> []
    end)
  end

  defp extract_result(%{"result" => %{} = result}), do: result
  defp extract_result(%{"error" => %{} = error}), do: %{"isError" => true, "content" => [%{"type" => "text", "text" => Jason.encode!(error)}]}
  defp extract_result(_body), do: %{}

  defp remote_tool_name(%{"tool" => %{"remote_name" => remote_name}}) when is_binary(remote_name) and remote_name != "", do: remote_name
  defp remote_tool_name(%{"tool" => %{"name" => tool_name}}), do: tool_name
  defp remote_tool_name(_registration), do: nil

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(nil), do: %{}
  defp normalize_arguments(arguments), do: %{"input" => arguments}

  defp client_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp response_header(headers, key) when is_map(headers) do
    case headers[key] || headers[String.downcase(key)] || headers[String.upcase(key)] do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp response_header(_headers, _key), do: nil

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: put_header(headers, key, value)

  defp put_header(headers, key, value) do
    lowered_key = String.downcase(key)
    filtered = Enum.reject(headers, fn {existing_key, _value} -> String.downcase(existing_key) == lowered_key end)
    [{lowered_key, value} | filtered]
  end

  defp header_value(headers, key) do
    lowered_key = String.downcase(key)

    Enum.find_value(headers, fn
      {^lowered_key, value} -> value
      {existing_key, value} when is_binary(existing_key) ->
        if String.downcase(existing_key) == lowered_key, do: value

      _ -> nil
    end)
  end
end
