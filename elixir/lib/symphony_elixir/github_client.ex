defmodule SymphonyElixir.GitHubClient do
  @moduledoc """
  Fetches lightweight GitHub repo observability data for the dashboard/API.
  """

  alias SymphonyElixir.Config.Schema.GitHub

  @type response_body :: map() | list()
  @type rate_limit :: %{
          optional(:limit) => integer(),
          optional(:remaining) => integer(),
          optional(:reset_at) => String.t()
        }

  @spec fetch_observability(GitHub.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_observability(%GitHub{enabled: false}), do: {:ok, nil}

  def fetch_observability(%GitHub{} = config) do
    with {:ok, repo} <- normalize_repo(config.repo),
         {:ok, repo_info, repo_rate_limit} <- get_json(config, "/repos/#{repo}"),
         {:ok, open_pull_requests, pr_rate_limit} <- optional_search_total(config, repo, "pr"),
         {:ok, open_issues, issue_rate_limit} <- optional_search_total(config, repo, "issue") do
      {workflow_runs, workflow_errors, workflow_rate_limit} = fetch_workflow_runs(config, repo)

      {:ok,
       %{
         fetched_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         repo: summarize_repo(repo_info),
         counts: %{
           open_pull_requests: open_pull_requests,
           open_issues: open_issues
         },
         workflows: %{
           recent: workflow_runs
         },
         rate_limit:
           merge_rate_limits([
             repo_rate_limit,
             pr_rate_limit,
             issue_rate_limit,
             workflow_rate_limit
           ]),
         errors: workflow_errors
       }}
    end
  end

  @spec fetch_observability_with_request(GitHub.t(), (keyword() -> {:ok, term()} | {:error, term()})) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_observability_with_request(%GitHub{enabled: false}, _request_fun), do: {:ok, nil}

  def fetch_observability_with_request(%GitHub{} = config, request_fun) when is_function(request_fun, 1) do
    Process.put({__MODULE__, :request_fun}, request_fun)

    try do
      fetch_observability(config)
    after
      Process.delete({__MODULE__, :request_fun})
    end
  end

  defp fetch_workflow_runs(config, repo) do
    path = "/repos/#{repo}/actions/runs?per_page=#{config.recent_workflow_runs}"

    case get_json(config, path) do
      {:ok, %{"workflow_runs" => runs}, rate_limit} when is_list(runs) ->
        {Enum.map(runs, &summarize_workflow_run/1), [], rate_limit}

      {:ok, _body, rate_limit} ->
        {[], [%{source: "workflows", reason: "unexpected_response"}], rate_limit}

      {:error, {:http_error, status, _body}} when status in [403, 404] ->
        {[], [%{source: "workflows", reason: http_reason(status)}], nil}

      {:error, reason} ->
        {[], [%{source: "workflows", reason: format_reason(reason)}], nil}
    end
  end

  defp optional_search_total(config, repo, type) do
    query = URI.encode_query(%{"q" => "repo:#{repo} type:#{type} state:open", "per_page" => 1})

    case get_json(config, "/search/issues?#{query}") do
      {:ok, %{"total_count" => total_count}, rate_limit} when is_integer(total_count) ->
        {:ok, total_count, rate_limit}

      {:ok, _body, rate_limit} ->
        {:ok, nil, rate_limit}

      {:error, {:http_error, status, _body}} when status in [403, 404] ->
        {:ok, nil, nil}

      {:error, _reason} ->
        {:ok, nil, nil}
    end
  end

  defp summarize_repo(%{} = repo_info) do
    %{
      full_name: repo_info["full_name"],
      html_url: repo_info["html_url"],
      default_branch: repo_info["default_branch"],
      private: repo_info["private"],
      visibility: repo_info["visibility"],
      open_issues_count: repo_info["open_issues_count"],
      pushed_at: repo_info["pushed_at"]
    }
  end

  defp summarize_workflow_run(%{} = run) do
    %{
      name: run["name"],
      status: run["status"],
      conclusion: run["conclusion"],
      event: run["event"],
      head_branch: run["head_branch"],
      html_url: run["html_url"],
      created_at: run["created_at"],
      updated_at: run["updated_at"]
    }
  end

  defp get_json(%GitHub{} = config, path) do
    url = String.trim_trailing(config.api_url || "https://api.github.com", "/") <> path

    req_opts = [
      method: :get,
      url: url,
      headers: headers(config),
      receive_timeout: 15_000
    ]

    case request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status >= 200 and status < 300 ->
        {:ok, body, extract_rate_limit(headers)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(req_opts) do
    case Process.get({__MODULE__, :request_fun}) do
      request_fun when is_function(request_fun, 1) -> request_fun.(req_opts)
      _ -> Req.request(req_opts)
    end
  end

  defp headers(%GitHub{token: token}) do
    base = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "symphony-elixir"},
      {"x-github-api-version", "2022-11-28"}
    ]

    if is_binary(token) and String.trim(token) != "" do
      [{"authorization", "Bearer #{token}"} | base]
    else
      base
    end
  end

  defp normalize_repo(repo) when is_binary(repo) do
    trimmed = String.trim(repo)

    cond do
      trimmed == "" -> {:error, :missing_github_repo}
      String.contains?(trimmed, "/") -> {:ok, trimmed}
      true -> {:error, {:invalid_github_repo, repo}}
    end
  end

  defp normalize_repo(_repo), do: {:error, :missing_github_repo}

  defp extract_rate_limit(headers) when is_map(headers) do
    %{}
    |> maybe_put_rate_limit(:limit, header_int(headers, "x-ratelimit-limit"))
    |> maybe_put_rate_limit(:remaining, header_int(headers, "x-ratelimit-remaining"))
    |> maybe_put_rate_limit(:reset_at, header_reset_at(headers, "x-ratelimit-reset"))
  end

  defp extract_rate_limit(_headers), do: nil

  defp maybe_put_rate_limit(map, _key, nil), do: map
  defp maybe_put_rate_limit(map, key, value), do: Map.put(map, key, value)

  defp header_int(headers, key) do
    case headers[key] || headers[String.downcase(key)] || headers[String.upcase(key)] do
      [value | _] -> parse_integer(value)
      value when is_binary(value) -> parse_integer(value)
      _ -> nil
    end
  end

  defp header_reset_at(headers, key) do
    case header_int(headers, key) do
      nil -> nil
      unix_seconds -> unix_seconds |> DateTime.from_unix!(:second) |> DateTime.to_iso8601()
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp merge_rate_limits(rate_limits) do
    rate_limits
    |> Enum.filter(&is_map/1)
    |> List.last()
  end

  defp http_reason(403), do: "forbidden"
  defp http_reason(404), do: "not_found"
  defp http_reason(status), do: "http_#{status}"

  defp format_reason({:http_error, status, _body}), do: http_reason(status)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
