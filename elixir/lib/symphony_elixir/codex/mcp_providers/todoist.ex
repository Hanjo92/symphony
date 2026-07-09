defmodule SymphonyElixir.Codex.McpProviders.Todoist do
  @moduledoc """
  Todoist MCP provider presets and alias mapping for Symphony.
  """

  @default_url "https://ai.todoist.net/mcp"
  @default_transport "streamable_http"
  @generic_object_schema %{"type" => "object", "additionalProperties" => true}
  @generic_items_schema %{
    "type" => "array",
    "items" => %{"type" => "object", "additionalProperties" => true}
  }

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
    "todoist_find_tasks_by_date" => %{
      "name" => "todoist_find_tasks_by_date",
      "remote_name" => "findTasksByDate",
      "description" => "Find Todoist tasks by date range, including today-style planning views.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "startDate" => %{"type" => "string"},
          "endDate" => %{"type" => "string"},
          "daysCount" => %{"type" => "integer"},
          "limit" => %{"type" => "integer"}
        }
      }
    },
    "todoist_find_completed_tasks" => %{
      "name" => "todoist_find_completed_tasks",
      "remote_name" => "findCompletedTasks",
      "description" => "Find recently completed Todoist tasks.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "since" => %{"type" => "string"},
          "until" => %{"type" => "string"},
          "projectId" => %{"type" => "string"},
          "limit" => %{"type" => "integer"}
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
          "tasks" => @generic_items_schema
        }
      }
    },
    "todoist_complete_tasks" => %{
      "name" => "todoist_complete_tasks",
      "remote_name" => "completeTasks",
      "description" => "Mark Todoist tasks as completed.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["taskIds"],
        "properties" => %{
          "taskIds" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    },
    "todoist_uncomplete_tasks" => %{
      "name" => "todoist_uncomplete_tasks",
      "remote_name" => "uncompleteTasks",
      "description" => "Reopen previously completed Todoist tasks.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["taskIds"],
        "properties" => %{
          "taskIds" => %{"type" => "array", "items" => %{"type" => "string"}}
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
          "tasks" => @generic_items_schema
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
          "tasks" => @generic_items_schema
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
    },
    "todoist_add_projects" => %{
      "name" => "todoist_add_projects",
      "remote_name" => "addProjects",
      "description" => "Create Todoist projects.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["projects"],
        "properties" => %{
          "projects" => @generic_items_schema
        }
      }
    },
    "todoist_update_projects" => %{
      "name" => "todoist_update_projects",
      "remote_name" => "updateProjects",
      "description" => "Update existing Todoist projects.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["projects"],
        "properties" => %{
          "projects" => @generic_items_schema
        }
      }
    },
    "todoist_find_sections" => %{
      "name" => "todoist_find_sections",
      "remote_name" => "findSections",
      "description" => "Find Todoist sections within a project or inbox context.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "projectId" => %{"type" => "string"},
          "searchTerm" => %{"type" => "string"}
        }
      }
    },
    "todoist_add_sections" => %{
      "name" => "todoist_add_sections",
      "remote_name" => "addSections",
      "description" => "Create Todoist sections.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["sections"],
        "properties" => %{
          "sections" => @generic_items_schema
        }
      }
    },
    "todoist_update_sections" => %{
      "name" => "todoist_update_sections",
      "remote_name" => "updateSections",
      "description" => "Update existing Todoist sections.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["sections"],
        "properties" => %{
          "sections" => @generic_items_schema
        }
      }
    },
    "todoist_find_comments" => %{
      "name" => "todoist_find_comments",
      "remote_name" => "findComments",
      "description" => "Find Todoist comments for a task, project, or specific comment id.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "taskId" => %{"type" => "string"},
          "projectId" => %{"type" => "string"},
          "commentId" => %{"type" => "string"}
        }
      }
    },
    "todoist_add_comments" => %{
      "name" => "todoist_add_comments",
      "remote_name" => "addComments",
      "description" => "Create Todoist task or project comments.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["comments"],
        "properties" => %{
          "comments" => @generic_items_schema
        }
      }
    },
    "todoist_update_comments" => %{
      "name" => "todoist_update_comments",
      "remote_name" => "updateComments",
      "description" => "Update existing Todoist comments.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["comments"],
        "properties" => %{
          "comments" => @generic_items_schema
        }
      }
    },
    "todoist_find_reminders" => %{
      "name" => "todoist_find_reminders",
      "remote_name" => "findReminders",
      "description" => "Find Todoist reminders by task or reminder id.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "taskId" => %{"type" => "string"},
          "reminderId" => %{"type" => "string"},
          "locationReminderId" => %{"type" => "string"}
        }
      }
    },
    "todoist_add_reminders" => %{
      "name" => "todoist_add_reminders",
      "remote_name" => "addReminders",
      "description" => "Create Todoist reminders for tasks.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["reminders"],
        "properties" => %{
          "reminders" => @generic_items_schema
        }
      }
    },
    "todoist_update_reminders" => %{
      "name" => "todoist_update_reminders",
      "remote_name" => "updateReminders",
      "description" => "Update existing Todoist reminders.",
      "mode" => "write",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "required" => ["reminders"],
        "properties" => %{
          "reminders" => @generic_items_schema
        }
      }
    },
    "todoist_find_project_collaborators" => %{
      "name" => "todoist_find_project_collaborators",
      "remote_name" => "findProjectCollaborators",
      "description" => "Find Todoist collaborators by project, name, or email.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "projectId" => %{"type" => "string"},
          "searchTerm" => %{"type" => "string"}
        }
      }
    },
    "todoist_get_overview" => %{
      "name" => "todoist_get_overview",
      "remote_name" => "getOverview",
      "description" => "Get a Markdown overview of a Todoist account or project.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => true,
        "properties" => %{
          "projectId" => %{"type" => "string"},
          "includeCompleted" => %{"type" => "boolean"}
        }
      }
    },
    "todoist_fetch_object" => %{
      "name" => "todoist_fetch_object",
      "remote_name" => "fetchObject",
      "description" => "Fetch a single Todoist task, project, comment, or section by id.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["type", "id"],
        "properties" => %{
          "type" => %{"type" => "string"},
          "id" => %{"type" => "string"}
        }
      }
    },
    "todoist_get_productivity_stats" => %{
      "name" => "todoist_get_productivity_stats",
      "remote_name" => "getProductivityStats",
      "description" => "Get Todoist productivity statistics and karma trends.",
      "inputSchema" => @generic_object_schema
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
