defmodule CymphonyElixir.Cymphony.WorkflowGenerator do
  @moduledoc false

  alias CymphonyElixir.Cymphony.Config
  alias CymphonyElixir.Cymphony.PromptTemplate

  @spec generate(map()) :: String.t()
  def generate(config) do
    # Serialize the structured config map as JSON, which is valid YAML, so the
    # `WORKFLOW.md` front matter round-trips losslessly (Jason handles all
    # escaping) instead of relying on hand-built, unescaped YAML.
    front_matter = Jason.encode!(Config.to_schema_map(config), pretty: true)
    template = PromptTemplate.get()

    "---\n#{front_matter}\n---\n\n#{template}"
  end

  @spec write_temp(map()) :: {:ok, String.t()} | {:error, term()}
  @spec write_temp(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_temp(config, opts \\ []) do
    content = generate(config)
    project_slug = safe_project_slug(Map.get(config, "name"))
    suffix = :erlang.unique_integer([:positive])
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(tmp_dir, "cymphony_workflow_#{project_slug}_#{suffix}.md")

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to write temp workflow: #{inspect(reason)}"}
    end
  end

  defp safe_project_slug(nil), do: "default"

  defp safe_project_slug(name) when is_binary(name) do
    name
    |> String.replace(Regex.compile!("[^a-zA-Z0-9._-]"), "_")
    |> String.slice(0, 32)
  end
end
