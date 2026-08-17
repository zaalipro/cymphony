defmodule CymphonyElixir.Cymphony.WorkflowGeneratorTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Cymphony.PromptTemplate
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Workflow

  test "generate/1 wraps JSON front matter and the prompt template" do
    content = WorkflowGenerator.generate(%{"name" => "Farm", "linear_project_slug" => "farm"})

    assert String.starts_with?(content, "---\n")
    assert content =~ ~s("kind": "claude")
    assert content =~ ~s("project_slug": "farm")
    assert String.contains?(content, PromptTemplate.get())
  end

  test "write_temp/1 uses a default slug when the project has no name" do
    assert {:ok, path} = WorkflowGenerator.write_temp(%{"linear_api_key" => "k"})
    on_exit(fn -> File.rm(path) end)

    assert Path.basename(path) =~ ~r/^cymphony_workflow_default_\d+\.md$/
    assert {:ok, %{config: parsed}} = Workflow.load(path)
    assert parsed["tracker"]["api_key"] == "k"
  end

  test "write_temp/1 creates the file with 0600 permissions" do
    # The front matter embeds tracker.api_key in cleartext, so the umask-derived
    # 0644 these files used to land with is a credential leak to every local user.
    assert {:ok, path} = WorkflowGenerator.write_temp(%{"name" => "perms", "linear_api_key" => "lin_secret"})
    on_exit(fn -> File.rm(path) end)

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.read!(path) =~ "lin_secret"
  end

  test "write/2 writes the generated workflow and tightens an existing loose mode to 0600" do
    path = Path.join(System.tmp_dir!(), "cymphony-wg-rewrite-#{System.unique_integer([:positive])}.md")
    File.write!(path, "stale")
    File.chmod!(path, 0o644)
    on_exit(fn -> File.rm(path) end)

    assert :ok = WorkflowGenerator.write(path, %{"name" => "Farm", "linear_api_key" => "lin_secret"})

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    refute File.read!(path) =~ "stale"
    assert {:ok, %{config: parsed}} = Workflow.load(path)
    assert parsed["tracker"]["api_key"] == "lin_secret"
  end

  test "write/2 returns the posix error when the target directory does not exist" do
    path = Path.join([System.tmp_dir!(), "cymphony-wg-missing-#{System.unique_integer([:positive])}", "WORKFLOW.md"])

    assert {:error, :enoent} = WorkflowGenerator.write(path, %{"name" => "blocked"})
  end

  test "write/2 removes its staged file when the write cannot be completed" do
    # Renaming a file onto a directory fails, which is the cheapest way to fail
    # the last step — the staged sibling must not survive it.
    dir = Path.join(System.tmp_dir!(), "cymphony-wg-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, reason} = WorkflowGenerator.write(dir, %{"name" => "blocked", "linear_api_key" => "lin_secret"})
    assert is_atom(reason)
    assert Path.wildcard(dir <> ".tmp-*") == []
    assert File.ls!(dir) == []
  end

  test "write_temp/1 sanitizes and truncates the project name for the filename" do
    name = "My Project! #1 " <> String.duplicate("x", 40)
    expected_slug = String.slice("My_Project___1_" <> String.duplicate("x", 40), 0, 32)

    assert {:ok, path} = WorkflowGenerator.write_temp(%{"name" => name})
    on_exit(fn -> File.rm(path) end)

    basename = Path.basename(path)
    assert String.starts_with?(basename, "cymphony_workflow_#{expected_slug}_")
    assert String.ends_with?(basename, ".md")
    assert String.length(expected_slug) == 32
  end

  test "write_temp/2 returns an error when the temp directory is not writable" do
    tmp_dir = Path.join(System.tmp_dir!(), "cymphony-wg-not-a-dir-#{System.unique_integer([:positive])}")
    File.write!(tmp_dir, "not a directory")
    on_exit(fn -> File.rm(tmp_dir) end)

    assert {:error, message} = WorkflowGenerator.write_temp(%{"name" => "blocked"}, tmp_dir: tmp_dir)
    assert message =~ "Failed to write temp workflow"
  end
end
