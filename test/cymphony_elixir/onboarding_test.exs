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

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
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
    assert output =~ "2) sonnet (balanced)"
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

    assert output =~ "gpt-5.2-codex"

    {:ok, config} = CymphonyConfig.load()
    [project] = CymphonyConfig.projects(config)
    assert project["agent"] == "codex"
    assert project["model"] == "my-custom-model"
    refute Map.has_key?(project, "effort")
  end
end
