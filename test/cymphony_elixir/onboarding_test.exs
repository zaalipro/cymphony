defmodule CymphonyElixir.Cymphony.OnboardingTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.Onboarding

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-onboarding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    # Pin the codex catalog so the numbered menus are deterministic regardless
    # of whether a codex binary (and which version) is installed locally.
    CymphonyElixir.AgentCatalog.clear_cache()

    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn ->
      {:ok,
       ~s({"models": [{"slug": "gpt-5.2-codex", "description": "Test catalog model", "default_reasoning_level": "medium", "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}], "visibility": "list", "priority": 1}]})}
    end)

    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
      Application.delete_env(:cymphony_elixir, :onboarding_gets)
      Application.delete_env(:cymphony_elixir, :onboarding_providers)
      CymphonyElixir.AgentCatalog.clear_cache()

      if previous_key do
        System.put_env("LINEAR_API_KEY", previous_key)
      else
        System.delete_env("LINEAR_API_KEY")
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp run_wizard(answers) do
    parent = self()

    output =
      capture_io([input: Enum.join(answers, "\n") <> "\n", capture_prompt: true], fn ->
        send(parent, {:result, Onboarding.run()})
      end)

    assert_received {:result, result}
    {result, output}
  end

  defp run_add_project(answers) do
    parent = self()

    output =
      capture_io([input: Enum.join(answers, "\n") <> "\n", capture_prompt: true], fn ->
        send(parent, {:result, Onboarding.add_project()})
      end)

    assert_received {:result, result}
    {result, output}
  end

  defp with_gets(responses, fun) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    Application.put_env(:cymphony_elixir, :onboarding_gets, fn _prompt ->
      Agent.get_and_update(agent, &next_response/1)
    end)

    try do
      fun.()
    after
      Application.delete_env(:cymphony_elixir, :onboarding_gets)
      if Process.alive?(agent), do: Agent.stop(agent)
    end
  end

  defp next_response([next | rest]) do
    reply = if is_function(next, 0), do: next.(), else: next
    {reply, rest}
  end

  defp next_response([]), do: {:eof, []}

  defp run_wizard_scripted(responses) do
    parent = self()

    output =
      capture_io(fn ->
        with_gets(responses, fn -> send(parent, {:result, Onboarding.run()}) end)
      end)

    assert_received {:result, result}
    {result, output}
  end

  defp run_add_project_scripted(responses) do
    parent = self()

    output =
      capture_io(fn ->
        with_gets(responses, fn -> send(parent, {:result, Onboarding.add_project()}) end)
      end)

    assert_received {:result, result}
    {result, output}
  end

  defp project_answers(name, opts \\ []) do
    [
      name,
      Keyword.get(opts, :repo, "git@github.com:example/repo.git"),
      Keyword.get(opts, :slug, "team-abc123"),
      Keyword.get(opts, :api_key, "lin_api_test"),
      Keyword.get(opts, :workspace, ""),
      Keyword.get(opts, :polling, ""),
      Keyword.get(opts, :agent, ""),
      Keyword.get(opts, :model, ""),
      Keyword.get(opts, :effort, "")
    ]
  end

  test "model and effort are picked from numbered menus" do
    answers = [
      "NumberedProj",
      "git@github.com:example/repo.git",
      "team-abc123",
      "lin_api_test",
      # workspace root (default)
      "",
      # polling interval (default)
      "",
      # agent kind (default claude)
      "",
      # model: option 3 = opus
      "3",
      # effort: option 4 = high
      "4",
      # add another project?
      "n"
    ]

    {{:ok, _config}, output} = run_wizard(answers)

    assert output =~ "Model:"
    assert output =~ "1) agent default"
    assert output =~ "2) sonnet — Balanced speed and capability"
    assert output =~ "Reasoning effort:"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["model"] == "opus"
    assert project["effort"] == "high"
    assert project["agent"] == "claude"
  end

  test "Enter keeps agent defaults; custom free text is accepted for model" do
    answers = [
      "DefaultsProj",
      "git@github.com:example/repo.git",
      "team-abc123",
      "lin_api_test",
      "",
      "",
      "codex",
      # model: custom free text (menu shows codex models)
      "my-custom-model",
      # effort: Enter = option 1 (agent default)
      "",
      "n"
    ]

    {{:ok, _config}, output} = run_wizard(answers)

    # Codex menu comes from the (stubbed) live catalog, description included.
    assert output =~ "gpt-5.2-codex — Test catalog model"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["agent"] == "codex"
    assert project["model"] == "my-custom-model"
    refute Map.has_key?(project, "effort")
  end

  test "antigravity is accepted; unknown kinds are rejected with the known list" do
    answers = [
      "AntiProj",
      "git@github.com:example/repo.git",
      "team-abc123",
      "lin_api_test",
      "",
      "",
      # rejected, then accepted
      "gemini",
      "antigravity",
      # model: Enter = agent default
      "",
      # effort: Enter = agent default
      "",
      "n"
    ]

    {{:ok, _config}, output} = run_wizard(answers)

    assert output =~ "Coding agent (claude/codex/antigravity)"
    assert output =~ "Unknown agent 'gemini'. Choose claude, codex, or antigravity."
    assert output =~ "gemini-3.7-flash-high"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["agent"] == "antigravity"
    refute Map.has_key?(project, "model")
    refute Map.has_key?(project, "effort")
  end

  test "empty required fields are retried; invalid polling falls back to 5000ms" do
    answers = [
      "",
      "RetryProj",
      "git@github.com:example/repo.git",
      "team-abc123",
      "",
      "lin_after_blank",
      "/tmp/cymphony-ws",
      "not-a-number",
      "",
      "",
      "",
      "n"
    ]

    {{:ok, _config}, output} = run_wizard(answers)
    assert output =~ "This field is required."
    assert output =~ "This field is required. Set LINEAR_API_KEY or enter a key."

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["name"] == "RetryProj"
    assert project["linear_api_key"] == "lin_after_blank"
    assert project["workspace_root"] == "/tmp/cymphony-ws"
    assert project["polling_interval_ms"] == 5000
  end

  test "eof after the required fields accepts optional/agent/menu defaults and skips add-another" do
    {{:ok, config}, _output} = run_wizard(["EofProj", "git@github.com:example/repo.git", "team-abc123", "lin_api_test"])

    [project] = config["projects"]
    assert project["name"] == "EofProj"
    assert project["agent"] == "claude"
    refute Map.has_key?(project, "model")
    refute Map.has_key?(project, "effort")
  end

  test "eof on the API key aborts the wizard" do
    {{:error, reason}, _output} = run_wizard(["EofKey", "git@github.com:example/repo.git", "team-abc123"])
    assert reason == "Unexpected end of input"
  end

  test "LINEAR_API_KEY from the environment is used when the prompt is left blank" do
    System.put_env("LINEAR_API_KEY", "lin_from_env_9999")

    answers = project_answers("EnvKeyProj", api_key: "") ++ ["n"]
    {{:ok, _config}, output} = run_wizard(answers)

    assert output =~ "from env"
    assert output =~ "9999"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["linear_api_key"] == "lin_from_env_9999"
  after
    System.delete_env("LINEAR_API_KEY")
  end

  test "add another project collects a second entry; a duplicate name is rejected" do
    answers =
      project_answers("First") ++
        ["y"] ++
        ["First", "Second"] ++
        tl(project_answers("Second")) ++
        ["n"]

    {{:ok, config}, output} = run_wizard(answers)

    assert output =~ "A project named 'First' already exists."
    names = Enum.map(config["projects"], & &1["name"])
    assert names == ["First", "Second"]
  end

  test "add another project that then hits eof keeps the first project" do
    answers = project_answers("KeepFirst") ++ ["y"]
    {{:ok, config}, _output} = run_wizard(answers)
    assert Enum.map(config["projects"], & &1["name"]) == ["KeepFirst"]
  end

  test "run reports a save failure when the config directory cannot be created", %{tmp: tmp} do
    File.rm_rf!(tmp)
    File.write!(tmp, "not-a-directory")

    {{:error, reason}, _output} = run_wizard(project_answers("SaveFail") ++ ["n"])
    assert reason =~ "Failed to save configuration"
  end

  test "list_projects returns configured projects and surfaces load errors", %{tmp: tmp} do
    assert {:error, _} = Onboarding.list_projects()

    {{:ok, _config}, _output} = run_wizard(project_answers("Listed") ++ ["n"])
    assert {:ok, [project]} = Onboarding.list_projects()
    assert project["name"] == "Listed"

    File.rm_rf!(tmp)
    File.write!(tmp, "not-a-directory")
    assert {:error, _} = Onboarding.list_projects()
  end

  test "add_project appends to an existing config and rejects a missing one" do
    assert {:error, msg} = Onboarding.add_project()
    assert msg =~ "Configuration error"

    {{:ok, _config}, _output} = run_wizard(project_answers("Existing") ++ ["n"])

    {{:ok, updated}, output} = run_add_project(project_answers("Added") ++ [])
    assert output =~ "Add a new project"
    assert output =~ "Project 'Added' added"
    assert Enum.map(updated["projects"], & &1["name"]) == ["Existing", "Added"]
  end

  test "add_project surfaces a collect error when input ends immediately" do
    :ok = CymphonyConfig.save(%{"projects" => [%{"name" => "Existing"}]})
    {{:error, reason}, _output} = run_add_project([])
    assert reason == "Unexpected end of input"
  end

  test "add_project reports a save failure after a successful collect" do
    :ok = CymphonyConfig.save(%{"projects" => [%{"name" => "Existing"}]})

    sabotage = fn ->
      path = CymphonyConfig.config_path()
      File.rm!(path)
      File.mkdir_p!(path)
      "Added\n"
    end

    {{:error, reason}, _output} =
      run_add_project_scripted([
        sabotage,
        "git@github.com:example/repo.git\n",
        "team-abc123\n",
        "lin_api_test\n",
        "\n",
        "\n",
        "\n",
        "\n",
        "\n"
      ])

    assert reason =~ "Failed to save configuration"
  end

  test "IO.gets {:error, _} on the project name is reported as an input error" do
    {{:error, reason}, _output} = run_wizard_scripted([{:error, :eio}])
    assert reason =~ "Input error"
  end

  test "IO.gets {:error, _} on the API key is reported as an input error" do
    {{:error, reason}, _output} =
      run_wizard_scripted(["ErrKey\n", "git@github.com:example/repo.git\n", "team-abc123\n", {:error, :eio}])

    assert reason =~ "Input error"
  end

  test "IO.gets {:error, _} on optional/agent/menu/add-another prompts uses the defaults" do
    {{:ok, config}, _output} =
      run_wizard_scripted([
        "ErrDefaults\n",
        "git@github.com:example/repo.git\n",
        "team-abc123\n",
        "lin_api_test\n",
        {:error, :eio},
        {:error, :eio},
        {:error, :eio},
        {:error, :eio},
        {:error, :eio},
        {:error, :eio}
      ])

    [project] = config["projects"]
    assert project["name"] == "ErrDefaults"
    assert project["agent"] == "claude"
    refute Map.has_key?(project, "model")
  end

  test "a configured provider is stored; unknown names are retried; blank keeps none" do
    Application.put_env(:cymphony_elixir, :onboarding_providers, %{"cz1" => %{}, ck: %{}})

    {{:ok, _config}, output} =
      run_wizard(project_answers("ProvOk") ++ ["nope", "cz1", "n"])

    assert output =~ "Unknown provider 'nope'"
    assert output =~ "Available:"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["provider"] == "cz1"
  after
    Application.delete_env(:cymphony_elixir, :onboarding_providers)
  end

  test "blank, eof, and IO error on the provider prompt leave provider unset" do
    Application.put_env(:cymphony_elixir, :onboarding_providers, %{"cz1" => %{}})

    {{:ok, _config}, _output} = run_wizard(project_answers("ProvBlank") ++ ["", "n"])
    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    refute Map.has_key?(project, "provider")

    File.rm!(CymphonyConfig.config_path())

    {{:ok, config}, _output} = run_wizard(project_answers("ProvEof"))
    [project] = config["projects"]
    refute Map.has_key?(project, "provider")

    File.rm_rf!(CymphonyConfig.config_path())

    {{:ok, config}, _output} =
      run_wizard_scripted(Enum.map(project_answers("ProvErr"), &(&1 <> "\n")) ++ [{:error, :eio}, "n\n"])

    [project] = config["projects"]
    refute Map.has_key?(project, "provider")
  after
    Application.delete_env(:cymphony_elixir, :onboarding_providers)
  end
end
