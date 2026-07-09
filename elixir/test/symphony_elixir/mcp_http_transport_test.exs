defmodule SymphonyElixir.Codex.McpHttpTransportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.McpHttpTransport

  test "calls a Todoist MCP tool over streamable HTTP and returns structuredContent" do
    test_pid = self()

    registration = %{
      "server" => "todoist",
      "server_config" => %{
        "provider" => "todoist",
        "transport" => "streamable_http",
        "url" => "https://ai.todoist.net/mcp",
        "auth" => %{"type" => "bearer", "token" => "secret"}
      },
      "tool" => %{
        "name" => "todoist_find_tasks",
        "remote_name" => "findTasks"
      }
    }

    assert {:ok, %{"items" => [%{"id" => "task-1", "content" => "Ship Todoist bridge"}]}} =
             McpHttpTransport.call_tool(
               registration,
               %{"query" => "today"},
               mcp_http_request: fn req_opts ->
                 send(test_pid, {:mcp_http_request, req_opts})

                 case req_opts[:method] do
                   :post ->
                     handle_post_request(req_opts)

                   :delete ->
                     {:ok, %Req.Response{status: 204, headers: %{}}}
                 end
               end
             )

    assert_received {:mcp_http_request, initialize_req}
    assert initialize_req[:method] == :post
    assert initialize_req[:json]["method"] == "initialize"

    assert_received {:mcp_http_request, initialized_req}
    assert initialized_req[:json]["method"] == "notifications/initialized"
    assert header_value(initialized_req[:headers], "mcp-session-id") == "todoist-session-1"
    assert header_value(initialized_req[:headers], "mcp-protocol-version") == "2025-06-18"

    assert_received {:mcp_http_request, tool_req}
    assert tool_req[:json]["method"] == "tools/call"
    assert tool_req[:json]["params"] == %{"name" => "findTasks", "arguments" => %{"query" => "today"}}
    assert header_value(tool_req[:headers], "authorization") == "Bearer secret"
    assert header_value(tool_req[:headers], "mcp-session-id") == "todoist-session-1"
  end

  test "formats remote MCP tool errors as tool_error tuples" do
    registration = %{
      "server" => "todoist",
      "server_config" => %{
        "provider" => "todoist",
        "transport" => "streamable_http",
        "url" => "https://ai.todoist.net/mcp",
        "auth" => %{"type" => "bearer", "token" => "secret"}
      },
      "tool" => %{
        "name" => "todoist_add_tasks",
        "remote_name" => "addTasks"
      }
    }

    assert {:error,
            {:tool_error,
             %{
               "message" => "validation failed",
               "result" => %{
                 "content" => [%{"type" => "text", "text" => "validation failed"}],
                 "isError" => true
               }
             }}} =
             McpHttpTransport.call_tool(
               registration,
               %{"tasks" => [%{"content" => ""}]},
               mcp_http_request: fn req_opts ->
                 case req_opts[:method] do
                   :delete ->
                     {:ok, %Req.Response{status: 204, headers: %{}}}

                   _ ->
                     case req_opts[:json]["method"] do
                       "initialize" ->
                         {:ok,
                          %Req.Response{
                            status: 200,
                            body: %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"protocolVersion" => "2025-06-18"}},
                            headers: %{"mcp-session-id" => ["todoist-session-2"]}
                          }}

                       "notifications/initialized" ->
                         {:ok, %Req.Response{status: 202, headers: %{}}}

                       "tools/call" ->
                         {:ok,
                          %Req.Response{
                            status: 200,
                            body: %{
                              "jsonrpc" => "2.0",
                              "id" => 2,
                              "result" => %{
                                "isError" => true,
                                "content" => [%{"type" => "text", "text" => "validation failed"}]
                              }
                            },
                            headers: %{}
                          }}
                     end
                 end
               end
             )
  end

  defp handle_post_request(req_opts) do
    case req_opts[:json]["method"] do
      "initialize" ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "todoist", "version" => "1.0.0"}
             }
           },
           headers: %{"mcp-session-id" => ["todoist-session-1"]}
         }}

      "notifications/initialized" ->
        {:ok, %Req.Response{status: 202, headers: %{}}}

      "tools/call" ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "jsonrpc" => "2.0",
             "id" => 2,
             "result" => %{
               "structuredContent" => %{
                 "items" => [%{"id" => "task-1", "content" => "Ship Todoist bridge"}]
               }
             }
           },
           headers: %{}
         }}
    end
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
