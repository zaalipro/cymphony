defmodule CymphonyElixir.Cymphony.Onboarding do
  @moduledoc false

  alias CymphonyElixir.Cymphony.Config

  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    IO.puts("""

    ╭──────────────────────────────────────────────────────────╮
    │  Welcome to Cymphony!                                    │
    │                                                          │
    │  Let's set up your configuration.                        │
    │  This will be saved to ~/.cymphony/config.json           │
    ╰──────────────────────────────────────────────────────────╯
    """)

    case collect_project([]) do
      {:ok, first_project} ->
        save_onboarded_projects([first_project])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_onboarded_projects(first_projects) do
    projects = collect_additional_projects(first_projects)
    config = %{"projects" => projects}

    case Config.save(config) do
      :ok ->
        IO.puts("\nConfiguration saved to #{Config.config_path()}")
        {:ok, config}

      {:error, reason} ->
        {:error, "Failed to save configuration: #{inspect(reason)}"}
    end
  end

  @doc """
  Adds a single project to an existing config file.
  """
  @spec add_project() :: {:ok, map()} | {:error, term()}
  def add_project do
    case Config.load() do
      {:ok, config} ->
        add_project_to_config(config)

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  defp add_project_to_config(config) do
    IO.puts("""

    ╭──────────────────────────────────────────────────────────╮
    │  Add a new project to your Cymphony configuration.      │
    ╰──────────────────────────────────────────────────────────╯
    """)

    existing_names = Config.projects(config) |> Enum.map(& &1["name"])

    case collect_project(existing_names) do
      {:ok, project} ->
        save_added_project(config, project)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_added_project(config, project) do
    updated_projects = Config.projects(config) ++ [project]
    updated_config = Map.put(config, "projects", updated_projects)

    case Config.save(updated_config) do
      :ok ->
        IO.puts("\nProject '#{project["name"]}' added to #{Config.config_path()}")
        {:ok, updated_config}

      {:error, reason} ->
        {:error, "Failed to save configuration: #{inspect(reason)}"}
    end
  end

  @doc """
  Lists configured projects.
  """
  @spec list_projects() :: {:ok, [map()]} | {:error, term()}
  def list_projects do
    case Config.load() do
      {:ok, config} ->
        {:ok, Config.projects(config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_project(existing_names, providers \\ nil) do
    providers = providers || onboarding_providers()

    with {:ok, name} <- ask_project_name(existing_names),
         {:ok, github_repo} <- ask_required("GitHub repo URL (e.g. git@github.com:user/repo.git): "),
         {:ok, project_slug} <- ask_required("Linear project slug (e.g. myteam-ab12cd34ef56): "),
         {:ok, api_key} <- ask_linear_api_key(),
         {:ok, workspace_root} <-
           ask_optional("Workspace root [~/.cymphony/workspaces/#{name}]: ", "~/.cymphony/workspaces/#{name}"),
         {:ok, polling_interval} <- ask_optional("Polling interval in seconds [5]: ", "5"),
         {:ok, agent_kind} <- ask_agent_kind(),
         {:ok, model} <- ask_numbered("Model", model_choices(agent_kind)),
         {:ok, effort} <- ask_numbered("Reasoning effort", effort_choices(agent_kind)),
         {:ok, provider} <- ask_provider(providers) do
      {:ok,
       build_project(%{
         name: name,
         github_repo: github_repo,
         project_slug: project_slug,
         api_key: api_key,
         workspace_root: workspace_root,
         polling_interval: polling_interval,
         agent_kind: agent_kind,
         model: model,
         effort: effort,
         provider: provider
       })}
    end
  end

  defp build_project(attrs) do
    polling_ms =
      case Integer.parse(attrs.polling_interval) do
        {secs, _} -> secs * 1000
        :error -> 5000
      end

    %{
      "name" => attrs.name,
      "github_repo_url" => attrs.github_repo,
      "linear_project_slug" => attrs.project_slug,
      "linear_api_key" => attrs.api_key,
      "workspace_root" => attrs.workspace_root,
      "polling_interval_ms" => polling_ms,
      "agent" => attrs.agent_kind
    }
    |> maybe_put("provider", present_string(attrs.provider))
    |> maybe_put("model", attrs.model)
    |> maybe_put("effort", attrs.effort)
  end

  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # {label shown in the menu, value stored in config; nil = agent default}.
  # Codex choices come from the live `codex debug models` catalog (with
  # per-model descriptions); claude uses its stable alias vocabulary.
  defp model_choices(agent_kind) do
    fetched =
      agent_kind
      |> CymphonyElixir.AgentCatalog.models()
      |> Enum.map(fn model ->
        label =
          case model.description do
            desc when is_binary(desc) and desc != "" -> "#{model.label} — #{desc}"
            _ -> model.label
          end

        {label, model.value}
      end)

    [{"agent default", nil} | fetched]
  end

  defp effort_choices(agent_kind) do
    levels =
      agent_kind
      |> CymphonyElixir.AgentCatalog.efforts(nil)
      |> Enum.map(fn level -> {level, level} end)

    [{"agent default", nil} | levels]
  end

  # Numbered menu: pick by number, Enter for option 1, or type a custom value
  # (models change faster than this list — free text is always accepted).
  defp ask_numbered(title, choices) do
    IO.puts("\n#{title}:")

    choices
    |> Enum.with_index(1)
    |> Enum.each(fn {{label, _value}, index} -> IO.puts("  #{index}) #{label}") end)

    parse_numbered_choice(read_line("Choose 1-#{length(choices)} or type a custom value [1]: "), choices)
  end

  defp parse_numbered_choice(:eof, choices), do: default_numbered_choice(choices)
  defp parse_numbered_choice({:error, _}, choices), do: default_numbered_choice(choices)

  defp parse_numbered_choice(input, choices) do
    case String.trim(input) do
      "" -> default_numbered_choice(choices)
      value -> resolve_numbered_value(value, choices)
    end
  end

  defp default_numbered_choice(choices), do: {:ok, elem(hd(choices), 1)}

  defp resolve_numbered_value(value, choices) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= length(choices) ->
        {:ok, choices |> Enum.at(n - 1) |> elem(1)}

      _ ->
        {:ok, value}
    end
  end

  defp ask_project_name(existing_names) do
    case ask_required("Project name: ") do
      {:ok, name} ->
        if name in existing_names do
          IO.puts("  A project named '#{name}' already exists. Choose a different name.")
          ask_project_name(existing_names)
        else
          {:ok, name}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_additional_projects(projects, providers \\ nil) do
    providers = providers || onboarding_providers()

    case read_line("Add another project? [y/N]: ") do
      :eof ->
        projects

      {:error, _} ->
        projects

      input ->
        maybe_collect_another_project(input, projects, providers)
    end
  end

  defp maybe_collect_another_project(input, projects, providers) do
    if String.trim(String.downcase(input)) == "y" do
      append_collected_project(projects, providers)
    else
      projects
    end
  end

  defp append_collected_project(projects, providers) do
    case collect_project(Enum.map(projects, & &1["name"]), providers) do
      {:ok, project} ->
        collect_additional_projects(projects ++ [project], providers)

      {:error, _reason} ->
        projects
    end
  end

  defp ask_required(prompt) do
    case read_line(prompt) do
      :eof ->
        {:error, "Unexpected end of input"}

      {:error, reason} ->
        {:error, "Input error: #{inspect(reason)}"}

      input ->
        value = String.trim(input)

        if value == "" do
          IO.puts("  This field is required.")
          ask_required(prompt)
        else
          {:ok, value}
        end
    end
  end

  defp ask_linear_api_key do
    env_key = System.get_env("LINEAR_API_KEY")

    prompt =
      if env_key do
        masked = String.slice(env_key, -4, 4) |> String.pad_leading(String.length(env_key), "*")
        "Linear API key [#{masked} from env]: "
      else
        "Linear API key: "
      end

    case read_line(prompt) do
      :eof ->
        {:error, "Unexpected end of input"}

      {:error, reason} ->
        {:error, "Input error: #{inspect(reason)}"}

      input ->
        value = String.trim(input)

        cond do
          value != "" ->
            {:ok, value}

          env_key != nil ->
            {:ok, env_key}

          true ->
            IO.puts("  This field is required. Set LINEAR_API_KEY or enter a key.")
            ask_linear_api_key()
        end
    end
  end

  defp ask_agent_kind do
    kinds = CymphonyElixir.Agent.known_kinds()
    default = hd(kinds)
    prompt = "Coding agent (#{Enum.join(kinds, "/")}) [#{default}]: "

    case read_line(prompt) do
      :eof ->
        {:ok, default}

      {:error, _} ->
        {:ok, default}

      input ->
        parse_agent_kind(input, default, kinds)
    end
  end

  defp parse_agent_kind(input, default, kinds) do
    case input |> String.trim() |> String.downcase() do
      "" ->
        {:ok, default}

      kind ->
        accept_or_retry_agent_kind(kind, kinds)
    end
  end

  defp accept_or_retry_agent_kind(kind, kinds) do
    if CymphonyElixir.Agent.known_kind?(kind) do
      {:ok, kind}
    else
      IO.puts("  Unknown agent '#{kind}'. Choose #{format_agent_kinds(kinds)}.")
      ask_agent_kind()
    end
  end

  defp format_agent_kinds(kinds) do
    {leading, [last]} = Enum.split(kinds, -1)
    Enum.join(leading, ", ") <> ", or " <> last
  end

  defp ask_optional(prompt, default) do
    case read_line(prompt) do
      :eof ->
        {:ok, default}

      {:error, _} ->
        {:ok, default}

      input ->
        value = String.trim(input)
        {:ok, if(value == "", do: default, else: value)}
    end
  end

  defp ask_provider(providers) do
    provider_names = Map.keys(providers)

    if provider_names == [] do
      {:ok, nil}
    else
      prompt_for_provider(providers, provider_names)
    end
  end

  defp prompt_for_provider(providers, provider_names) do
    names_str = Enum.join(provider_names, ", ")
    prompt = "Provider (#{names_str}) [none]: "

    case read_line(prompt) do
      :eof ->
        {:ok, nil}

      {:error, _} ->
        {:ok, nil}

      input ->
        parse_provider_choice(input, providers, names_str)
    end
  end

  defp parse_provider_choice(input, providers, names_str) do
    value = String.trim(input)

    if value == "" do
      {:ok, nil}
    else
      accept_or_retry_provider(value, providers, names_str)
    end
  end

  defp accept_or_retry_provider(value, providers, names_str) do
    string_names = providers |> Map.keys() |> Enum.map(&to_string/1)

    if value in string_names do
      {:ok, value}
    else
      IO.puts("  Unknown provider '#{value}'. Available: #{names_str}")
      ask_provider(providers)
    end
  end

  defp read_line(prompt) do
    reader = Application.get_env(:cymphony_elixir, :onboarding_gets, &IO.gets/1)
    reader.(prompt)
  end

  defp onboarding_providers do
    Application.get_env(:cymphony_elixir, :onboarding_providers, %{})
  end
end
