defmodule CymphonyElixir.Linear.ClientAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Linear.Client

  @fake_key "lin_test"
  @alt_fake_key "lin_api_fake"
  @viewer_ok %{"data" => %{"viewer" => %{"id" => "user-1"}}}

  setup do
    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    previous_endpoint = System.get_env("LINEAR_ENDPOINT")
    previous_linear_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_app_env(:linear_graphql_opts, previous_opts)
      restore_env("LINEAR_ENDPOINT", previous_endpoint)
      restore_env("LINEAR_API_KEY", previous_linear_key)
    end)

    :ok
  end

  describe "graphql_opts_for_api_key/2" do
    test "authorizes with the raw key and defaults to the Linear GraphQL endpoint" do
      opts = Client.graphql_opts_for_api_key(@fake_key)

      assert opts[:endpoint] == "https://api.linear.app/graphql"
      assert is_function(opts[:graphql_headers_fun], 0)
      assert is_function(opts[:request_fun], 2)
      assert {:ok, headers} = opts[:graphql_headers_fun].()
      assert {"Authorization", @fake_key} in headers
      assert {"Content-Type", "application/json"} in headers
    end

    test "honors opts[:endpoint] over LINEAR_ENDPOINT" do
      System.put_env("LINEAR_ENDPOINT", "https://env.example/graphql")

      opts =
        Client.graphql_opts_for_api_key(@fake_key, endpoint: "https://opts.example/graphql")

      assert opts[:endpoint] == "https://opts.example/graphql"
    end

    test "uses LINEAR_ENDPOINT when opts[:endpoint] is blank" do
      System.put_env("LINEAR_ENDPOINT", " https://env.example/graphql ")

      opts = Client.graphql_opts_for_api_key(@fake_key, endpoint: "  ")
      assert opts[:endpoint] == "https://env.example/graphql"
    end

    test "merges Application :linear_graphql_opts so tests can inject request_fun" do
      parent = self()

      Application.put_env(:cymphony_elixir, :linear_graphql_opts,
        request_fun: fn payload, headers ->
          send(parent, {:injected, payload, headers})
          {:ok, %{status: 200, body: @viewer_ok}}
        end
      )

      opts = Client.graphql_opts_for_api_key(@alt_fake_key)
      assert {:ok, %{status: 200, body: @viewer_ok}} = opts[:request_fun].(%{"query" => "q"}, [{"h", "v"}])
      assert_received {:injected, %{"query" => "q"}, [{"h", "v"}]}
    end
  end

  describe "validate_api_key/2" do
    test "returns :empty for a blank key and does not call Linear" do
      request_fun = fn _payload, _headers -> flunk("must not call Linear") end

      assert {:error, :empty} = Client.validate_api_key("", request_fun: request_fun)
      assert {:error, :empty} = Client.validate_api_key("   \n", request_fun: request_fun)
    end

    test "returns viewer id on stubbed 200" do
      previous_key = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "lin_must_not_be_read")

      try do
        assert {:ok, %{id: "user-1"}} =
                 Client.validate_api_key("  #{@fake_key}  ",
                   request_fun: fn payload, headers ->
                     assert payload["query"] =~ "CymphonyLinearViewer"
                     assert {"Authorization", @fake_key} in headers
                     refute {"Authorization", "lin_must_not_be_read"} in headers
                     {:ok, %{status: 200, body: @viewer_ok}}
                   end
                 )
      after
        restore_env("LINEAR_API_KEY", previous_key)
      end
    end

    test "uses Application-injected request_fun without Config.settings!" do
      Application.put_env(:cymphony_elixir, :linear_graphql_opts,
        request_fun: fn _payload, headers ->
          assert {"Authorization", @alt_fake_key} in headers
          {:ok, %{status: 200, body: @viewer_ok}}
        end
      )

      assert {:ok, %{id: "user-1"}} = Client.validate_api_key(@alt_fake_key)
    end

    test "maps HTTP 401 to :unauthorized" do
      log =
        capture_log(fn ->
          assert {:error, :unauthorized} =
                   Client.validate_api_key(@fake_key,
                     request_fun: fn _payload, _headers ->
                       {:ok, %{status: 401, body: %{"errors" => [%{"message" => "Unauthorized"}]}}}
                     end
                   )
        end)

      assert log =~ "Linear GraphQL request failed status=401"
    end

    test "maps HTTP 403 to :unauthorized" do
      capture_log(fn ->
        assert {:error, :unauthorized} =
                 Client.validate_api_key(@fake_key,
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 403, body: "forbidden"}}
                   end
                 )
      end)
    end

    test "maps GraphQL authentication errors to :unauthorized" do
      body = %{
        "errors" => [
          %{
            "message" => "Authentication required, not authenticated",
            "extensions" => %{"code" => "AUTHENTICATION_ERROR"}
          }
        ]
      }

      assert {:error, :unauthorized} =
               Client.validate_api_key(@fake_key,
                 request_fun: fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
               )
    end

    test "maps 200 without viewer.id to :invalid" do
      assert {:error, :invalid} =
               Client.validate_api_key(@fake_key,
                 request_fun: fn _payload, _headers ->
                   {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{}}}}}
                 end
               )

      assert {:error, :invalid} =
               Client.validate_api_key(@fake_key,
                 request_fun: fn _payload, _headers ->
                   {:ok, %{status: 200, body: %{"data" => %{}}}}
                 end
               )
    end

    test "maps non-auth GraphQL errors without a viewer to :invalid" do
      body = %{"errors" => [%{"message" => "Variable \"$ids\" got invalid value"}]}

      assert {:error, :invalid} =
               Client.validate_api_key(@fake_key,
                 request_fun: fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
               )
    end

    test "passes through transport errors" do
      capture_log(fn ->
        assert {:error, {:linear_api_request, :nxdomain}} =
                 Client.validate_api_key(@fake_key,
                   request_fun: fn _payload, _headers -> {:error, :nxdomain} end
                 )
      end)
    end
  end

  describe "list_accessible_projects/2" do
    test "returns :empty for a blank key and does not call Linear" do
      request_fun = fn _payload, _headers -> flunk("must not call Linear") end
      assert {:error, :empty} = Client.list_accessible_projects(" ", request_fun: request_fun)
    end

    test "maps slugId, drops nodes missing slugId, and paginates" do
      request_fun = fn payload, headers ->
        assert payload["query"] =~ "CymphonyLinearProjects"
        assert payload["query"] =~ "slugId"
        assert {"Authorization", @fake_key} in headers
        assert payload["variables"][:first] == 50

        case payload["variables"][:after] do
          nil ->
            {:ok,
             %{
               status: 200,
               body:
                 projects_page(
                   [
                     %{
                       "id" => "proj-1",
                       "name" => "AI Logic",
                       "slugId" => "ailogic-ced4159f70c4"
                     },
                     %{"id" => "proj-2", "name" => "No slug"},
                     %{"id" => "proj-3", "name" => "Blank slug", "slugId" => "  "}
                   ],
                   true,
                   "cursor-1"
                 )
             }}

          "cursor-1" ->
            {:ok,
             %{
               status: 200,
               body:
                 projects_page(
                   [
                     %{"id" => "proj-4", "name" => "Farm", "slugId" => "farm-aaaa"},
                     %{"name" => "Missing id", "slugId" => "missing-id"}
                   ],
                   false,
                   nil
                 )
             }}
        end
      end

      assert {:ok, projects} = Client.list_accessible_projects(@fake_key, request_fun: request_fun)

      assert projects == [
               %{id: "proj-1", name: "AI Logic", slug_id: "ailogic-ced4159f70c4"},
               %{id: "proj-4", name: "Farm", slug_id: "farm-aaaa"}
             ]
    end

    test "maps HTTP 401 to :unauthorized" do
      capture_log(fn ->
        assert {:error, :unauthorized} =
                 Client.list_accessible_projects(@fake_key,
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 401, body: "nope"}}
                   end
                 )
      end)
    end

    test "maps GraphQL authentication errors to :unauthorized" do
      body = %{
        "errors" => [
          %{"message" => "Unauthorized", "extensions" => %{"code" => "AUTHENTICATION_ERROR"}}
        ]
      }

      assert {:error, :unauthorized} =
               Client.list_accessible_projects(@fake_key,
                 request_fun: fn _payload, _headers -> {:ok, %{status: 200, body: body}} end
               )
    end

    test "returns GraphQL errors that are not auth failures" do
      errors = [%{"message" => "Internal error", "extensions" => %{"code" => "INTERNAL_ERROR"}}]

      assert {:error, {:linear_graphql_errors, ^errors}} =
               Client.list_accessible_projects(@fake_key,
                 request_fun: fn _payload, _headers ->
                   {:ok, %{status: 200, body: %{"errors" => errors}}}
                 end
               )
    end

    test "stops after 10 pages" do
      request_fun = fn payload, _headers ->
        send(self(), {:project_page, payload["variables"][:after]})

        {:ok,
         %{
           status: 200,
           body:
             projects_page(
               [%{"id" => "proj", "name" => "Paged", "slugId" => "paged-1"}],
               true,
               "next"
             )
         }}
      end

      assert {:ok, projects} = Client.list_accessible_projects(@fake_key, request_fun: request_fun)
      assert length(projects) == 10

      assert_received {:project_page, nil}

      for _ <- 2..10 do
        assert_received {:project_page, "next"}
      end

      refute_received {:project_page, _}
    end
  end

  defp projects_page(nodes, has_next_page, end_cursor) do
    %{
      "data" => %{
        "projects" => %{
          "nodes" => nodes,
          "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
        }
      }
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:cymphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:cymphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
