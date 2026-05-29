defmodule CymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour CymphonyElixir.Tracker

  alias CymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation CymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation CymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query CymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  # Zero-arity versions (legacy, reads global config)
  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  # Config-accepting versions for multi-project
  @spec fetch_candidate_issues(term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(config), do: client_module().fetch_candidate_issues(config)

  @spec fetch_issues_by_states([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, config), do: client_module().fetch_issues_by_states(states, config)

  @spec fetch_issue_states_by_ids([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config), do: client_module().fetch_issue_states_by_ids(issue_ids, config)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body})
    |> interpret_mutation(["data", "commentCreate", "success"])
  end

  @spec create_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, config) when is_binary(issue_id) and is_binary(body) do
    graphql_fun = graphql_with_config(config)

    graphql_fun.(@create_comment_mutation, %{issueId: issue_id, body: body})
    |> interpret_mutation(["data", "commentCreate", "success"])
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name) do
      client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id})
      |> interpret_mutation(["data", "issueUpdate", "success"])
    end
  end

  @spec update_issue_state(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, config)
      when is_binary(issue_id) and is_binary(state_name) do
    graphql_fun = graphql_with_config(config)

    with {:ok, state_id} <- resolve_state_id(issue_id, state_name, config) do
      graphql_fun.(@update_state_mutation, %{issueId: issue_id, stateId: state_id})
      |> interpret_mutation(["data", "issueUpdate", "success"])
    end
  end

  # Distinguish "API returned success: true" from "API errored or returned an
  # unexpected/missing field". The previous `get_in(...) == true` form collapsed
  # all of those into one opaque error; preserving the raw response (or the
  # unexpected return value) aids debugging when Linear's schema shifts.
  defp interpret_mutation({:ok, response}, path) do
    case get_in(response, path) do
      true -> :ok
      _ -> {:error, {:linear_unexpected_response, response}}
    end
  end

  defp interpret_mutation({:error, reason}, _path), do: {:error, reason}
  defp interpret_mutation(other, _path), do: {:error, {:linear_unexpected_response, other}}

  defp client_module do
    Application.get_env(:cymphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_state_id(issue_id, state_name, config) do
    graphql_fun = graphql_with_config(config)

    with {:ok, response} <- graphql_fun.(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp graphql_with_config(config) do
    client = client_module()
    opts = client.graphql_opts_for_config(config)
    fn query, variables -> client.graphql(query, variables, opts) end
  end
end
