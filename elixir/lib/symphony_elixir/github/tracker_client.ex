defmodule SymphonyElixir.GitHub.TrackerClient do
  @moduledoc """
  GitHub-backed tracker client for issues/PRs routed through repository labels.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @per_page 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    desired_states = state_lookup(state_names)

    with {:ok, issues} <- fetch_all_repo_issues() do
      {:ok,
       issues
       |> Enum.map(&normalize_issue(&1, desired_states))
       |> Enum.reject(&is_nil/1)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    desired_ids = issue_ids |> Enum.map(&to_string/1) |> MapSet.new()
    desired_states = state_lookup(all_known_states())

    with {:ok, issues} <- fetch_all_repo_issues() do
      {:ok,
       issues
       |> Enum.filter(fn issue -> MapSet.member?(desired_ids, to_string(issue["number"])) end)
       |> Enum.map(&normalize_issue(&1, desired_states))
       |> Enum.reject(&is_nil/1)
       |> Enum.sort_by(fn %Issue{id: id} -> Enum.find_index(issue_ids, &(to_string(&1) == id)) || 999_999 end)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    repo = github_repo!()

    case request(:post, "/repos/#{repo}/issues/#{issue_id}/comments", %{body: body}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_comment_failed, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    repo = github_repo!()
    desired_state = state_display_name(state_name)

    with {:ok, issue} <- fetch_issue(repo, issue_id),
         labels <- update_state_labels(issue["labels"] || [], desired_state),
         payload <- %{"labels" => labels, "state" => github_issue_state(desired_state)},
         {:ok, %{status: status}} when status in 200..299 <- request(:patch, "/repos/#{repo}/issues/#{issue_id}", payload) do
      :ok
    else
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_issue_update_failed, status, response_body}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_update_failed}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), [String.t()] | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, state_names \\ nil) when is_map(issue) do
    normalize_issue(issue, state_lookup(state_names || all_known_states()))
  end

  defp fetch_all_repo_issues do
    repo = github_repo!()
    assignee = Config.settings!().tracker.assignee
    fetch_issue_page(repo, 1, assignee, [])
  end

  defp fetch_issue_page(repo, page, assignee, acc) do
    query =
      [state: "all", per_page: @per_page, page: page]
      |> maybe_put_query(:assignee, assignee)
      |> URI.encode_query()

    case request(:get, "/repos/#{repo}/issues?#{query}") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        updated_acc = acc ++ body

        if length(body) < @per_page do
          {:ok, updated_acc}
        else
          fetch_issue_page(repo, page + 1, assignee, updated_acc)
        end

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:github_issue_list_failed, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue(repo, issue_id) do
    case request(:get, "/repos/#{repo}/issues/#{issue_id}") do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) -> {:ok, body}
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_issue_fetch_failed, status, response_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(issue, desired_states) when is_map(issue) and is_map(desired_states) do
    state = derive_state(issue, desired_states)

    cond do
      is_nil(state) ->
        nil

      true ->
        %Issue{
          id: to_string(issue["number"]),
          identifier: "GH-#{issue["number"]}",
          title: issue["title"],
          description: issue["body"],
          state: state,
          url: issue["html_url"],
          assignee_id: assignee_login(issue),
          labels: Enum.map(issue["labels"] || [], &label_name/1),
          branch_name: branch_name(issue),
          assigned_to_worker: true,
          created_at: parse_datetime(issue["created_at"]),
          updated_at: parse_datetime(issue["updated_at"])
        }
    end
  end

  defp normalize_issue(_issue, _desired_states), do: nil

  defp derive_state(issue, desired_states) do
    label_names = Enum.map(issue["labels"] || [], &normalize_state/1)

    Enum.find_value(label_names, fn label_name -> Map.get(desired_states, label_name) end) ||
      fallback_state(issue, desired_states)
  end

  defp fallback_state(%{"state" => "closed"}, desired_states) do
    Map.get(desired_states, "closed") || Map.get(desired_states, "done") || "Closed"
  end

  defp fallback_state(%{"state" => "open"}, desired_states) do
    Map.get(desired_states, "todo") || Map.get(desired_states, "open")
  end

  defp fallback_state(_issue, _desired_states), do: nil

  defp state_lookup(state_names) do
    state_names
    |> Enum.map(&state_display_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn state_name, acc ->
      Map.put(acc, normalize_state(state_name), state_name)
    end)
  end

  defp state_display_name(state_name) when is_binary(state_name) do
    trimmed = String.trim(state_name)
    if trimmed == "", do: nil, else: trimmed
  end

  defp state_display_name(state_name), do: state_name |> to_string() |> state_display_name()

  defp all_known_states do
    tracker = Config.settings!().tracker
    tracker.active_states ++ tracker.terminal_states
  end

  defp update_state_labels(labels, desired_state) do
    removable =
      all_known_states()
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    retained =
      labels
      |> Enum.map(&label_name/1)
      |> Enum.reject(fn label -> MapSet.member?(removable, normalize_state(label)) end)

    retained ++ [desired_state]
  end

  defp github_issue_state(state_name) do
    if normalize_state(state_name) in ["done", "closed", "cancelled", "canceled", "duplicate"],
      do: "closed",
      else: "open"
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Keyword.put(query, key, value)

  defp branch_name(%{"pull_request" => %{}, "number" => number}), do: "gh-#{number}"
  defp branch_name(%{"number" => number}), do: "gh-#{number}"
  defp branch_name(_issue), do: nil

  defp assignee_login(%{"assignee" => %{"login" => login}}) when is_binary(login), do: login
  defp assignee_login(_issue), do: nil

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(other), do: to_string(other)

  defp normalize_state(%{"name" => name}) when is_binary(name), do: normalize_state(name)
  defp normalize_state(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_state(name), do: name |> to_string() |> normalize_state()

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp github_repo! do
    case Config.settings!().github.repo do
      repo when is_binary(repo) and repo != "" -> repo
      _ -> raise ArgumentError, "GitHub repo is not configured"
    end
  end

  defp request(method, path, body \\ nil) do
    base_url = String.trim_trailing(Config.settings!().github.api_url || "https://api.github.com", "/")
    url = base_url <> path

    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "symphony-elixir-tracker"},
      {"x-github-api-version", "2022-11-28"}
    ]

    headers =
      case Config.settings!().github.token do
        token when is_binary(token) and token != "" -> [{"authorization", "Bearer #{token}"} | headers]
        _ -> headers
      end

    request_opts = [method: method, url: url, headers: headers, receive_timeout: 15_000]
    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

    case request_module().request(request_opts) do
      {:ok, %Req.Response{} = response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_module do
    Application.get_env(:symphony_elixir, :github_tracker_request_module, Req)
  end
end
