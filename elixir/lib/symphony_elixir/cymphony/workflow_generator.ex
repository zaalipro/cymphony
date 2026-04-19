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
    path = Path.join(System.tmp_dir!(), "cymphony_workflow_#{:erlang.unique_integer([:positive])}.md")

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "Failed to write temp workflow: #{inspect(reason)}"}
    end
  end
end
