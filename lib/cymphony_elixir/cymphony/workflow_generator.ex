defmodule CymphonyElixir.Cymphony.WorkflowGenerator do
  @moduledoc """
  Renders a project's `config.json` entry into a generated `WORKFLOW.md`.

  Generated files embed the plaintext Linear API key as `tracker.api_key`, so
  every write goes through `write/2` and lands as mode `0600` — the same
  treatment `Cymphony.Config.save/1` gives `config.json`.
  """

  alias CymphonyElixir.Cymphony.Config
  alias CymphonyElixir.Cymphony.PromptTemplate

  # Owner read/write only: these files carry the Linear API key in cleartext.
  @file_mode 0o600

  @spec generate(map()) :: String.t()
  def generate(config) do
    # Serialize the structured config map as JSON, which is valid YAML, so the
    # `WORKFLOW.md` front matter round-trips losslessly (Jason handles all
    # escaping) instead of relying on hand-built, unescaped YAML.
    front_matter = Jason.encode!(Config.to_schema_map(config), pretty: true)
    template = PromptTemplate.get()

    "---\n#{front_matter}\n---\n\n#{template}"
  end

  @doc """
  Writes the generated workflow for `config` to `path` with mode `0600`.

  Staged through a sibling temp file that is chmod'd while still empty, then
  renamed over `path`:

    * the Linear API key in the front matter is never on disk under a
      umask-derived mode (`0644` under the usual `022`), not even for the width
      of one `File.write/2`, and a file left `0644` by an older build is
      replaced by a `0600` one;
    * the rename is atomic, so a rewrite never exposes a truncated or partial
      `WORKFLOW.md` to the `WorkflowStore` reload poll, and a failed write
      leaves the previous file intact.
  """
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, config) when is_binary(path) and is_map(config) do
    staged = "#{path}.tmp-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(staged, ""),
         :ok <- File.chmod(staged, @file_mode),
         :ok <- File.write(staged, generate(config)),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(staged)
        error
    end
  end

  @spec write_temp(map()) :: {:ok, String.t()} | {:error, term()}
  @spec write_temp(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_temp(config, opts \\ []) do
    project_slug = safe_project_slug(Map.get(config, "name"))
    suffix = :erlang.unique_integer([:positive])
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(tmp_dir, "cymphony_workflow_#{project_slug}_#{suffix}.md")

    case write(path, config) do
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
