defmodule SymphonyElixir.Cymphony.WorkflowGenerator do
  @moduledoc false

  alias SymphonyElixir.Cymphony.Config
  alias SymphonyElixir.Cymphony.PromptTemplate

  @spec generate(map()) :: String.t()
  def generate(config) do
    yaml = Config.to_workflow_yaml(config)
    template = PromptTemplate.get()

    "---\n#{yaml}\n---\n\n#{template}"
  end

  @spec write_temp(map()) :: {:ok, String.t()} | {:error, term()}
  def write_temp(config) do
    content = generate(config)
    project_slug = safe_project_slug(Map.get(config, "name"))
    suffix = :erlang.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "cymphony_workflow_#{project_slug}_#{suffix}.md")

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
