defmodule CymphonyElixir.PromptBuilderTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.PromptBuilder

  test "build_prompt/2 prefers an explicit prompt_template option" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "workflow {{ issue.identifier }}")

    issue = issue(identifier: "MT-900", title: "Explicit template")

    prompt =
      PromptBuilder.build_prompt(issue,
        prompt_template: "override {{ issue.identifier }} {{ issue.title }} attempt={{ attempt }}",
        attempt: 4,
        config: %Schema{}
      )

    assert prompt == "override MT-900 Explicit template attempt=4"
  end

  test "build_prompt/2 uses Config.workflow_prompt/0 when only config is supplied" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "from-config {{ issue.identifier }}")

    issue = issue(identifier: "MT-901")
    prompt = PromptBuilder.build_prompt(issue, config: %Schema{})

    assert prompt == "from-config MT-901"
  end

  test "build_prompt/1 loads the workflow template and falls back when it is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "workflow-only {{ issue.identifier }}")

    assert PromptBuilder.build_prompt(issue(identifier: "MT-902")) == "workflow-only MT-902"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "  \n")
    fallback = PromptBuilder.build_prompt(issue(identifier: "MT-903", title: "Blank workflow"))

    assert fallback =~ "You are working on a Linear issue."
    assert fallback =~ "Identifier: MT-903"
    assert fallback =~ "Title: Blank workflow"
  end

  test "build_prompt/1 raises when the workflow file cannot be loaded" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-prompt-builder-#{System.unique_integer([:positive])}.md"))

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue(identifier: "MT-904"))
    end
  end

  test "build_prompt/2 wraps Solid parse failures with the template source" do
    issue = issue(identifier: "MT-905")

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue, prompt_template: "{% if issue.identifier %}")
    end
  end

  test "build_prompt/2 normalizes nested date-like values, maps, structs, and scalars" do
    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")

    issue =
      issue(
        identifier: "MT-906",
        created_at: created_at,
        labels: [
          ~N[2026-02-27 12:34:56],
          ~D[2026-02-28],
          ~T[12:34:56],
          %{phase: "test", count: 2},
          URI.parse("https://example.org/issues/MT-906"),
          "plain"
        ]
      )

    template = """
    id={{ issue.identifier }}
    created={{ issue.created_at }}
    naive={{ issue.labels[0] }}
    date={{ issue.labels[1] }}
    time={{ issue.labels[2] }}
    phase={{ issue.labels[3].phase }}
    count={{ issue.labels[3].count }}
    host={{ issue.labels[4].host }}
    plain={{ issue.labels[5] }}
    assigned={{ issue.assigned_to_worker }}
    """

    prompt = PromptBuilder.build_prompt(issue, prompt_template: template)

    assert prompt =~ "id=MT-906"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "naive=2026-02-27T12:34:56"
    assert prompt =~ "date=2026-02-28"
    assert prompt =~ "time=12:34:56"
    assert prompt =~ "phase=test"
    assert prompt =~ "count=2"
    assert prompt =~ "host=example.org"
    assert prompt =~ "plain=plain"
    assert prompt =~ "assigned=true"
  end

  defp issue(attrs) do
    struct!(
      %Issue{
        id: "issue-pb",
        identifier: "MT-0",
        title: "Prompt builder coverage",
        description: "Serialize issue fields",
        state: "Todo",
        url: "https://example.org/issues/MT-0",
        labels: []
      },
      attrs
    )
  end
end
