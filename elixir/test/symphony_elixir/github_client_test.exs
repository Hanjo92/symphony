defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.GitHub
  alias SymphonyElixir.GitHubClient

  test "fetch_observability_with_request returns repo summary and workflow runs" do
    github = %GitHub{
      enabled: true,
      api_url: "https://api.github.com",
      token: "token",
      repo: "Hanjo92/symphony",
      refresh_interval_ms: 60_000,
      recent_workflow_runs: 2
    }

    request_fun = fn opts ->
      url = opts[:url]

      cond do
        url == "https://api.github.com/repos/Hanjo92/symphony" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "full_name" => "Hanjo92/symphony",
               "html_url" => "https://github.com/Hanjo92/symphony",
               "default_branch" => "main",
               "private" => false,
               "visibility" => "public",
               "open_issues_count" => 11,
               "pushed_at" => "2026-05-08T03:00:00Z"
             },
             headers: %{"x-ratelimit-remaining" => ["4999"]}
           }}

        String.starts_with?(url, "https://api.github.com/search/issues?") and
            String.contains?(url, "type%3Apr") ->
          {:ok, %Req.Response{status: 200, body: %{"total_count" => 3}, headers: %{}}}

        String.starts_with?(url, "https://api.github.com/search/issues?") and
            String.contains?(url, "type%3Aissue") ->
          {:ok, %Req.Response{status: 200, body: %{"total_count" => 7}, headers: %{}}}

        url == "https://api.github.com/repos/Hanjo92/symphony/actions/runs?per_page=2" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "workflow_runs" => [
                 %{
                   "name" => "CI",
                   "status" => "completed",
                   "conclusion" => "success",
                   "event" => "push",
                   "head_branch" => "main",
                   "html_url" => "https://github.com/Hanjo92/symphony/actions/runs/1",
                   "created_at" => "2026-05-08T03:00:00Z",
                   "updated_at" => "2026-05-08T03:03:00Z"
                 }
               ]
             },
             headers: %{"x-ratelimit-limit" => ["5000"], "x-ratelimit-remaining" => ["4998"], "x-ratelimit-reset" => ["1778210000"]}
           }}
      end
    end

    assert {:ok, payload} = GitHubClient.fetch_observability_with_request(github, request_fun)
    assert payload.repo.full_name == "Hanjo92/symphony"
    assert payload.counts.open_pull_requests == 3
    assert payload.counts.open_issues == 7
    assert [%{name: "CI", conclusion: "success"}] = payload.workflows.recent
    assert payload.rate_limit.remaining == 4998
  end

  test "fetch_observability_with_request tolerates workflow endpoint errors" do
    github = %GitHub{enabled: true, api_url: "https://api.github.com", repo: "Hanjo92/symphony", recent_workflow_runs: 1}

    request_fun = fn opts ->
      url = opts[:url]

      cond do
        url == "https://api.github.com/repos/Hanjo92/symphony" ->
          {:ok, %Req.Response{status: 200, body: %{"full_name" => "Hanjo92/symphony", "html_url" => "https://github.com/Hanjo92/symphony"}, headers: %{}}}

        String.starts_with?(url, "https://api.github.com/search/issues?") and
            String.contains?(url, "type%3Apr") ->
          {:ok, %Req.Response{status: 403, body: %{}, headers: %{}}}

        String.starts_with?(url, "https://api.github.com/search/issues?") and
            String.contains?(url, "type%3Aissue") ->
          {:ok, %Req.Response{status: 404, body: %{}, headers: %{}}}

        url == "https://api.github.com/repos/Hanjo92/symphony/actions/runs?per_page=1" ->
          {:ok, %Req.Response{status: 403, body: %{}, headers: %{}}}
      end
    end

    assert {:ok, payload} = GitHubClient.fetch_observability_with_request(github, request_fun)
    assert payload.counts.open_pull_requests == nil
    assert payload.counts.open_issues == nil
    assert payload.workflows.recent == []
    assert [%{reason: "forbidden", source: "workflows"}] = payload.errors
  end
end
