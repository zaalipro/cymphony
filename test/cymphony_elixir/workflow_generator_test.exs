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
