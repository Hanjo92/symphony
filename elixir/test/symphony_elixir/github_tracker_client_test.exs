defmodule SymphonyElixir.GitHubTrackerClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.TrackerClient

  defmodule FakeReq do
    def request(opts) do
      parent = self()
      send(parent, {:github_request, opts})

      case Process.get({__MODULE__, :responses}) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        nil ->
          Process.get({__MODULE__, :response})
      end
    end
  end

  test "normalize_issue_for_test maps labels and defaults closed issues" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", github_repo: "Hanjo92/symphony")

    issue = %{
      "number" => 42,
      "title" => "Track me",
      "body" => "desc",
      "state" => "open",
      "html_url" => "https://github.com/Hanjo92/symphony/issues/42",
      "labels" => [%{"name" => "In Progress"}],
      "created_at" => "2026-05-08T00:00:00Z",
      "updated_at" => "2026-05-08T01:00:00Z"
    }

    normalized = TrackerClient.normalize_issue_for_test(issue, ["Todo", "In Progress", "Done"])
    assert normalized.id == "42"
    assert normalized.identifier == "GH-42"
    assert normalized.state == "In Progress"
    assert normalized.labels == ["In Progress"]

    closed_issue = Map.put(issue, "state", "closed") |> Map.put("labels", [])
    assert TrackerClient.normalize_issue_for_test(closed_issue, ["Todo", "Done", "Closed"]).state == "Closed"
  end

  test "fetches candidate issues, creates comments, and updates labels through GitHub" do
    Application.put_env(:symphony_elixir, :github_tracker_request_module, FakeReq)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      github_repo: "Hanjo92/symphony",
      github_token: "token"
    )

    Process.put({FakeReq, :responses}, [
      {:ok,
       %Req.Response{
         status: 200,
         body: [
           %{
             "number" => 1,
             "title" => "Todo issue",
             "body" => "body",
             "state" => "open",
             "html_url" => "https://github.com/Hanjo92/symphony/issues/1",
             "labels" => [%{"name" => "Todo"}],
             "created_at" => "2026-05-08T00:00:00Z",
             "updated_at" => "2026-05-08T00:10:00Z"
           }
         ]
       }},
      {:ok, %Req.Response{status: 201, body: %{}}},
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "number" => 1,
           "state" => "open",
           "labels" => [%{"name" => "Todo"}, %{"name" => "backend"}]
         }
       }},
      {:ok, %Req.Response{status: 200, body: %{}}}
    ])

    assert {:ok, [issue]} = TrackerClient.fetch_candidate_issues()
    assert issue.id == "1"
    assert issue.state == "Todo"

    assert :ok = TrackerClient.create_comment("1", "hello")
    assert :ok = TrackerClient.update_issue_state("1", "In Progress")

    assert_receive {:github_request, fetch_opts}
    assert fetch_opts[:method] == :get
    assert fetch_opts[:url] =~ "/repos/Hanjo92/symphony/issues?"

    assert_receive {:github_request, comment_opts}
    assert comment_opts[:method] == :post
    assert comment_opts[:url] == "https://api.github.com/repos/Hanjo92/symphony/issues/1/comments"
    assert comment_opts[:json] == %{body: "hello"}

    assert_receive {:github_request, get_issue_opts}
    assert get_issue_opts[:method] == :get
    assert get_issue_opts[:url] == "https://api.github.com/repos/Hanjo92/symphony/issues/1"

    assert_receive {:github_request, patch_opts}
    assert patch_opts[:method] == :patch
    assert patch_opts[:url] == "https://api.github.com/repos/Hanjo92/symphony/issues/1"
    assert patch_opts[:json] == %{"labels" => ["backend", "In Progress"], "state" => "open"}
  end
end
