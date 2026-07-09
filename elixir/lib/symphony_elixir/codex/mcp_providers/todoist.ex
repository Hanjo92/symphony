defmodule SymphonyElixir.Codex.McpProviders.Todoist do
  @moduledoc """
  Todoist MCP provider presets and alias mapping for Symphony.
  """

  @default_url "https://ai.todoist.net/mcp"
  @default_transport "streamable_http"

  @tool_presets %{
    "todoist_find_tasks" => %{
      "name" => "todoist_find_tasks",
      "remote_name" => "findTasks",
      "description" => "Find Todoist tasks by text, filter, project, or labels.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "query" => %{"type" => "string"},
          "filter" => %{"type" => "string"},
          "projectId" => %{"type" => "string"},
          "sectionId" => %{"type" => "string"},
          "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    },
    "todoist_add_tasks" => %{
      "name" => "todoist_add_tasks",
      "remote_name" => "addTasks",
      "description" => "Create one or more Todoist tasks.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["tasks"],
        "properties" => %{
          "tasks" => %{
            "type" => "array",
            "items" => %{"type" => "object", "additionalProperties" => true}
          }
        }
      }
    },
    "todoist_update_tasks" => %{
      "name" => "todoist_update_tasks",
      "remote_name" => "updateTasks",
      "description" => "Update existing Todoist tasks without rescheduling recurring dates.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["tasks"],
        "properties" => %{
          "tasks" => %{
            "type" => "array",
            "items" => %{"type" => "object", "additionalProperties" => true}
          }
        }
      }
    },
    "todoist_reschedule_tasks" => %{
      "name" => "todoist_reschedule_tasks",
      "remote_name" => "rescheduleTasks",
      "description" => "Reschedule Todoist tasks while preserving recurring schedules.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["tasks"],
        "properties" => %{
          "tasks" => %{
            "type" => "array",
            "items" => %{"type" => "object", "additionalProperties" => true}
          }
        }
      }
    },
    "todoist_find_projects" => %{
      "name" => "todoist_find_projects",
      "remote_name" => "findProjects",
      "description" => "Find Todoist projects by name or archived status.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "searchTerm" => %{"type" => "string"},
          "archivedStatus" => %{"type" => "string"}
        }
      }
    }
  }

  @spec normalize_server(map(), [map()]) :: map()
  def normalize_server(server_config, normalized_allowed_tools) when is_map(server_config) do
    allowed_tools =
      case normalized_allowed_tools do
        [] -> default_tools()
        tools -> Enum.map(tools, &normalize_tool/1)
      end

    %{
      "provider" => "todoist",
      "transport" => trim_or_default(server_config["transport"], @default_transport),
      "url" => trim_or_default(server_config["url"], @default_url),
      "auth" => Map.get(server_config, "auth"),
      "allowed_tools" => allowed_tools
    }
  end

  defp default_tools do
    @tool_presets
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&Map.fetch!(@tool_presets, &1))
  end

  defp normalize_tool(%{"name" => name} = tool) do
    preset =
      @tool_presets[name] ||
        Enum.find_value(@tool_presets, fn {_alias_name, preset} ->
          if preset["remote_name"] == name, do: preset, else: nil
        end) ||
        %{}

    remote_name =
      cond do
        is_binary(tool["remote_name"]) and String.trim(tool["remote_name"]) != "" ->
          String.trim(tool["remote_name"])

        is_binary(preset["remote_name"]) ->
          preset["remote_name"]

        true ->
          name
      end

    preset
    |> Map.merge(tool)
    |> Map.put("remote_name", remote_name)
  end

  defp trim_or_default(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp trim_or_default(_value, default), do: default
end
