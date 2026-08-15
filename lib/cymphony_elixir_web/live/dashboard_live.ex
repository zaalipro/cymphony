defmodule CymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cymphony.
  """

  use Phoenix.LiveView, layout: {CymphonyElixirWeb.Layouts, :app}

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixirWeb.{Control, Endpoint, ObservabilityPubSub, Presenter}

  @version Mix.Project.config()[:version]
  @runtime_tick_ms 1_000
  @payload_refresh_ms 3_000
  @harness_tail_cap 400
  @default_payload %{
    counts: %{running: 0, retrying: 0, by_state: %{}, by_kind: %{}},
    running: [],
    retrying: [],
    token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil,
    polling: nil,
    projects: []
  }

  @impl true
  def mount(_params, _session, socket) do
    connected? = connected?(socket)
    initial_payload = if connected?, do: load_payload(), else: @default_payload

    last_refresh =
      if connected?, do: System.monotonic_time(:millisecond), else: nil

    socket =
      socket
      |> assign(:payload, initial_payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:stalled_alert_dismissed, false)
      |> assign(:expanded_issue_ids, MapSet.new())
      |> assign(:harness_tails, %{})
      |> assign(:agent_setting_drafts, %{})
      |> assign(:issue_run_spec_drafts, %{})
      |> assign(:token_samples, update_token_samples([], initial_payload))
      |> assign(:version, @version)
      |> assign(:last_payload_refresh, last_refresh)

    if connected? do
      schedule_runtime_tick()
      ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_logs", %{"issue" => issue_identifier}, socket) do
    expanded = socket.assigns.expanded_issue_ids

    if MapSet.member?(expanded, issue_identifier) do
      {:noreply,
       socket
       |> assign(:expanded_issue_ids, MapSet.delete(expanded, issue_identifier))
       |> collapse_harness_tail(issue_identifier)}
    else
      {:noreply,
       socket
       |> assign(:expanded_issue_ids, MapSet.put(expanded, issue_identifier))
       |> expand_harness_tail(issue_identifier)}
    end
  end

  @impl true
  def handle_event("toggle_harness_follow", %{"issue" => issue_identifier}, socket) do
    case Map.get(socket.assigns.harness_tails, issue_identifier) do
      nil ->
        {:noreply, socket}

      tail ->
        follow? = Map.get(tail, :follow, true)
        tails = Map.put(socket.assigns.harness_tails, issue_identifier, Map.put(tail, :follow, !follow?))
        {:noreply, assign(socket, :harness_tails, tails)}
    end
  end

  @impl true
  def handle_event("dismiss_stalled_alert", _params, socket) do
    {:noreply, assign(socket, :stalled_alert_dismissed, true)}
  end

  @impl true
  def handle_event("kill_issue", %{"issue" => issue_identifier}, socket) do
    {:noreply, send_issue_command(socket, issue_identifier, :kill_issue)}
  end

  @impl true
  def handle_event("retry_issue", %{"issue" => issue_identifier}, socket) do
    {:noreply, send_issue_command(socket, issue_identifier, :retry_issue_now)}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      _ = CymphonyElixir.Orchestrator.request_refresh(orchestrator())
    end)

    Process.send_after(self(), :clear_flash, 3_000)
    {:noreply, put_flash(socket, :info, "Refresh requested — checking Linear now...")}
  end

  @impl true
  def handle_event("pause_dispatch", _params, socket) do
    Control.pause(:all)
    {:noreply, reload_payload_now(put_flash(socket, :info, "Dispatch paused — running sessions will complete normally"))}
  end

  @impl true
  def handle_event("resume_dispatch", _params, socket) do
    Control.resume(:all)
    {:noreply, reload_payload_now(put_flash(socket, :info, "Dispatch resumed"))}
  end

  @impl true
  def handle_event("set_concurrency", %{"value" => raw_value}, socket) do
    case Control.parse_concurrency(raw_value) do
      {:ok, n} ->
        Control.set_concurrency(:all, n)

        {:noreply, reload_payload_now(put_flash(socket, :info, "Concurrency set to #{n}; persisted to ~/.cymphony/config.json"))}

      :error ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a positive integer")}
    end
  end

  @impl true
  def handle_event(
        "set_project_concurrency",
        %{"project" => project_name, "value" => raw_value},
        socket
      ) do
    case Control.parse_concurrency(raw_value) do
      {:ok, n} ->
        case Control.set_concurrency({:project, project_name}, n) do
          :ok ->
            {:noreply, reload_payload_now(put_flash(socket, :info, "#{project_name}: concurrency set to #{n}"))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a positive integer")}
    end
  end

  @impl true
  def handle_event(
        "set_project_providers",
        %{"project" => project_name, "value" => raw_value},
        socket
      ) do
    case CymphonyConfig.parse_providers_csv(raw_value) do
      {:ok, list} ->
        case Control.set_providers({:project, project_name}, list) do
          :ok ->
            {:noreply, reload_payload_now(put_flash(socket, :info, "#{project_name}: providers set to #{Enum.join(list, ", ")}"))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}
        end

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "Providers must be a non-empty comma-separated list")}
    end
  end

  @impl true
  def handle_event("preview_project_agent", %{"project" => project_name} = params, socket) do
    case params["value"] || params["agent_kind"] do
      kind when is_binary(kind) ->
        if Agent.known_kind?(kind) do
          project = Enum.find(socket.assigns.payload[:projects] || [], &(&1.name == project_name)) || %{name: project_name}
          current = project_agent_settings(socket.assigns.agent_setting_drafts, project)
          agent_changed? = current.kind != kind

          draft = %{
            kind: kind,
            model: if(agent_changed?, do: "", else: Map.get(params, "model", "")),
            effort: if(agent_changed?, do: "", else: Map.get(params, "effort", ""))
          }

          drafts = Map.put(socket.assigns.agent_setting_drafts, project_name, draft)
          {:noreply, assign(socket, :agent_setting_drafts, drafts)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_project_agent", %{"project" => project_name} = params, socket) do
    parse_params =
      params
      |> Map.take(["model", "effort"])
      |> Map.put("kind", params["agent_kind"])

    case Control.parse_agent_settings(parse_params) do
      {:ok, settings} ->
        case Control.set_agent_settings({:project, project_name}, settings) do
          :ok ->
            confirmed = confirmed_agent_draft(settings)

            socket =
              update(socket, :agent_setting_drafts, &apply_confirmed_draft(&1, project_name, confirmed))

            {:noreply, reload_payload_now(put_flash(socket, :info, "#{project_name}: agent settings updated"))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Agent must be one of: #{Enum.join(Agent.known_kinds(), ", ")}")}
    end
  end

  @impl true
  def handle_event("toggle_project_pause", %{"project" => project_name}, socket) do
    case toggle_project_pause(socket.assigns.payload, project_name) do
      :ok ->
        {:noreply, reload_payload_now(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project orchestrator not found: #{project_name}")}
    end
  end

  @impl true
  def handle_event("preview_issue_run_spec", %{"issue" => issue_identifier} = params, socket) do
    case params["value"] || params["agent_kind"] do
      kind when is_binary(kind) ->
        preview_issue_run_spec(socket, issue_identifier, kind, params)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_issue_run_spec", %{"issue" => issue_identifier} = params, socket) do
    entry =
      Enum.find(socket.assigns.payload.running, &(&1.issue_identifier == issue_identifier)) || %{}

    issue_id = Map.get(entry, :issue_id)

    overrides =
      %{}
      |> maybe_override_param(:provider, params["provider"])
      |> maybe_override_param(:model, params["model"])
      |> maybe_override_param(:effort, params["effort"])
      |> maybe_override_agent_kind(params["agent_kind"])

    if is_binary(issue_id) and map_size(overrides) > 0 do
      send_issue_run_spec(socket, entry, issue_id, overrides)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    spawn_payload_load()
    {:noreply, assign(socket, :last_payload_refresh, System.monotonic_time(:millisecond))}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_payload_refresh] || 0

    socket =
      if now - last >= @payload_refresh_ms do
        spawn_payload_load()
        assign(socket, :last_payload_refresh, now)
      else
        socket
      end

    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info({:payload_loaded, payload}, socket) do
    token_samples = update_token_samples(socket.assigns.token_samples, payload)

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())
     |> assign(:token_samples, token_samples)
     |> update(:agent_setting_drafts, &prune_agent_drafts(&1, payload))}
  end

  @impl true
  def handle_info(%{event: :harness_stream, issue_id: id} = msg, socket) when is_binary(id) do
    seq = Map.get(msg, :last_seq) || 0
    new_lines = Map.get(msg, :lines) || []
    dropped = Map.get(msg, :dropped) || 0

    tails =
      Enum.reduce(socket.assigns.harness_tails, socket.assigns.harness_tails, fn {identifier, tail}, acc ->
        merge_harness_tail(acc, identifier, tail, id, seq, new_lines, dropped)
      end)

    {:noreply, assign(socket, :harness_tails, tails)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="command-bar">
        <div class="command-bar-row command-bar-row--brand">
          <div class="command-bar-brand">
            <span class="brand-mark" aria-hidden="true"></span>
            <span class="brand-wordmark">CYMPHONY</span>
            <span class="brand-tagline simple-only">Work status</span>
            <span class="brand-tagline advanced-only">Operations</span>
          </div>
          <div class="command-bar-meta">
            <span class="status-badge status-badge-offline status-badge-transport">
              <span class="status-badge-dot"></span>
              Connecting
            </span>
            <%= if @payload[:error] do %>
              <span class="status-badge status-badge-offline status-badge-payload">
                <span class="status-badge-dot"></span>
                Unavailable
              </span>
            <% else %>
              <span class="status-badge status-badge-live status-badge-payload">
                <span class="status-badge-dot"></span>
                Live
              </span>
            <% end %>
            <span class="version-badge">v<%= @version %></span>

            <div class="mode-switch" role="group" aria-label="Dashboard mode">
              <button type="button" class="mode-switch-button" data-mode-set="simple" aria-pressed="true">
                Simple
              </button>
              <button type="button" class="mode-switch-button" data-mode-set="advanced" aria-pressed="false">
                Advanced
              </button>
            </div>

            <div class="theme-toggle" role="group" aria-label="Theme">
              <button type="button" class="theme-toggle-button" data-theme-set="light" title="Light theme" aria-label="Light theme">☀</button>
              <button type="button" class="theme-toggle-button" data-theme-set="dark" title="Dark theme" aria-label="Dark theme">☾</button>
              <button type="button" class="theme-toggle-button" data-theme-set="system" title="Follow system" aria-label="Follow system">⌂</button>
            </div>

            <button type="button" class="subtle-button" data-drawer-toggle aria-label="Settings" title="Settings">⚙</button>
            <button type="button" class="subtle-button" phx-click="refresh_now">Refresh</button>
          </div>
        </div>

        <%= unless @payload[:error] do %>
          <div class="command-bar-row simple-mode-summary simple-only" aria-live="polite">
            <%= case autonomy_state(@payload) do %>
              <% :unknown -> %>
                <span class="autonomy-indicator autonomy-indicator--unknown">
                  <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                  Checking automatic work…
                </span>
                <span class="simple-mode-summary-copy">Cymphony is connecting to live orchestrator status.</span>
              <% :paused -> %>
                <span class="autonomy-indicator autonomy-indicator--paused">
                  <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                  Automatic work is paused
                </span>
                <span class="simple-mode-summary-copy">Running tasks can finish, but Cymphony will not start new ones.</span>
              <% {:partial, active_count, project_count} -> %>
                <span class="autonomy-indicator autonomy-indicator--partial">
                  <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                  Automatic work is on for <%= active_count %> of <%= project_count %> projects
                </span>
                <span class="simple-mode-summary-copy">Some projects are paused. Active projects will keep picking up ready issues.</span>
              <% :on -> %>
                <span class="autonomy-indicator">
                  <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                  Automatic work is on
                </span>
                <span class="simple-mode-summary-copy">Cymphony watches Linear and starts ready issues for you.</span>
            <% end %>
          </div>
        <% end %>

        <%= unless @payload[:error] do %>
          <div class="command-bar-row command-bar-row--metrics section--metrics">
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Working</span>
              <span class="metric-pill-label advanced-only">Run</span>
              <span class="metric-pill-value numeric"><%= @payload.counts.running %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Waiting</span>
              <span class="metric-pill-label advanced-only">Retry</span>
              <span class="metric-pill-value numeric"><%= @payload.counts.retrying %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Usage</span>
              <span class="metric-pill-label advanced-only">Tokens</span>
              <span class="metric-pill-value numeric"><%= format_int(@payload.token_totals.total_tokens) %></span>
              <span class="metric-pill-detail numeric advanced-only" title="input / output">
                in <%= format_int(@payload.token_totals.input_tokens) %> · out <%= format_int(@payload.token_totals.output_tokens) %>
              </span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Time active</span>
              <span class="metric-pill-label advanced-only">Runtime</span>
              <span class="metric-pill-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            </div>
            <div class="metric-pill metric-pill--throughput advanced-only">
              <span class="metric-pill-label">Tput</span>
              <span class="metric-pill-value numeric"><%= format_tps(current_tps(@token_samples)) %></span>
              <span class="metric-pill-spark numeric"><%= tps_sparkline(@token_samples) %></span>
            </div>
            <div class="metric-pill metric-pill--states section--states advanced-only">
              <span class="metric-pill-label">States</span>
              <span class="metric-pill-value"><%= format_count_breakdown(Map.get(@payload.counts, :by_state, %{})) %></span>
            </div>
            <div class="metric-pill metric-pill--kinds section--kinds advanced-only">
              <span class="metric-pill-label">Kinds</span>
              <span class="metric-pill-value"><%= format_count_breakdown(Map.get(@payload.counts, :by_kind, %{})) %></span>
            </div>

            <%= if @payload.polling do %>
              <div class="metric-pill metric-pill--ops section--polling">
                <span class="metric-pill-label simple-only">Automation</span>
                <span class="metric-pill-label advanced-only">Polling</span>
                <span class="metric-pill-value simple-only">
                  <%= case autonomy_state(@payload) do %>
                    <% :unknown -> %>
                      unavailable
                    <% :paused -> %>
                      <span class="ops-pulse">Paused</span>
                    <% {:partial, active_count, project_count} -> %>
                      <%= active_count %> / <%= project_count %> active
                    <% :on -> %>
                      <%= if @payload.polling.checking? do %>
                        <span class="ops-pulse">Checking…</span>
                      <% else %>
                        next <%= format_poll_countdown(@payload.polling.next_poll_in_ms, @now) %>
                      <% end %>
                  <% end %>
                </span>
                <span class="metric-pill-value advanced-only">
                  <%= cond do %>
                    <% Map.get(@payload.polling, :paused, false) -> %>
                      <span class="ops-pulse">Paused</span>
                    <% @payload.polling.checking? -> %>
                      <span class="ops-pulse">Checking…</span>
                    <% true -> %>
                      next <%= format_poll_countdown(@payload.polling.next_poll_in_ms, @now) %>
                  <% end %>
                </span>
                <%= if @payload.polling.poll_interval_ms do %>
                  <span class="metric-pill-detail numeric advanced-only">every <%= div(@payload.polling.poll_interval_ms, 1_000) %>s</span>
                <% end %>
              </div>
            <% end %>

            <%= if @payload.rate_limits do %>
              <%= case Presenter.format_rate_limits_for_web(@payload.rate_limits) do %>
                <% nil -> %>
                <% formatted -> %>
                  <div class="metric-pill metric-pill--ops section--ratelimits advanced-only">
                    <span class="metric-pill-label">Limits</span>
                    <%= if formatted.primary do %>
                      <span class="metric-pill-detail">primary <%= formatted.primary.summary %></span>
                      <%= if formatted.primary.reset_in_seconds do %>
                        <span class="metric-pill-detail muted">resets <%= formatted.primary.reset_in_seconds %>s</span>
                      <% end %>
                    <% end %>
                    <%= if formatted.secondary do %>
                      <span class="metric-pill-detail">secondary <%= formatted.secondary.summary %></span>
                    <% end %>
                    <%= if formatted.credits do %>
                      <span class="metric-pill-detail">credits <%= formatted.credits.summary %></span>
                    <% end %>
                  </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </header>

      <aside class="settings-drawer" aria-label="Dashboard settings">
        <div class="settings-drawer-header">
          <h2 class="section-title">Settings</h2>
          <button type="button" class="subtle-button" data-drawer-toggle aria-label="Close settings">Close</button>
        </div>

        <section class="settings-group settings-group--mode" data-prefs>
          <h3 class="settings-group-title">Experience</h3>
          <p class="settings-help">Choose how much operational detail you want to see. This only changes this browser.</p>
          <div class="mode-option-list" role="group" aria-label="Choose dashboard mode">
            <button type="button" class="mode-option" data-mode-set="simple" aria-pressed="true">
              <span class="mode-option-title">Simple</span>
              <span class="mode-option-copy">Clear status and safe controls for everyday use.</span>
            </button>
            <button type="button" class="mode-option" data-mode-set="advanced" aria-pressed="false">
              <span class="mode-option-title">Advanced</span>
              <span class="mode-option-copy">Models, providers, usage, logs, and restart overrides.</span>
            </button>
          </div>
        </section>

        <section class="settings-group">
          <h3 class="settings-group-title simple-only">Automation</h3>
          <h3 class="settings-group-title advanced-only">Orchestrator</h3>
          <p class="settings-help simple-only">Pause automatic pickup or change how many tasks may run together.</p>

          <%= if @payload[:polling] do %>
            <%= if autonomy_state(@payload) == :paused do %>
              <button type="button" class="subtle-button subtle-button--accent" phx-click="resume_dispatch">Resume all projects</button>
            <% else %>
              <button type="button" class="subtle-button" phx-click="pause_dispatch">Pause all projects</button>
            <% end %>
          <% end %>

          <form phx-submit="set_concurrency" class="inline-form">
            <label class="inline-label" for="drawer-global-concurrency">
              <span class="simple-only">tasks at once</span>
              <span class="advanced-only">global concurrency</span>
            </label>
            <input id="drawer-global-concurrency" type="number" name="value" min="1" class="inline-input inline-input--narrow" />
            <button type="submit" class="subtle-button">Set</button>
          </form>
        </section>

        <section class="settings-group advanced-only" data-prefs>
          <h3 class="settings-group-title">Display</h3>

          <div class="settings-row">
            <span class="inline-label">density</span>
            <label><input type="radio" name="pref-density" data-pref="density" value="comfortable" checked /> comfortable</label>
            <label><input type="radio" name="pref-density" data-pref="density" value="compact" /> compact</label>
          </div>

          <div class="settings-row">
            <span class="inline-label">sections</span>
            <%= for {label, key} <- [{"Metrics", "metrics"}, {"Polling", "polling"}, {"Rate limits", "ratelimits"}, {"Completions", "completions"}, {"States", "states"}, {"Kinds", "kinds"}] do %>
              <label><input type="checkbox" data-pref-section={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">columns</span>
            <%= for {label, key} <- [{"Title", "title"}, {"Chips", "chips"}, {"Runtime", "runtime"}, {"Tokens", "tokens"}] do %>
              <label><input type="checkbox" data-pref-col={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">completions shown</span>
            <select data-pref="completions-limit" class="inline-input inline-input--narrow">
              <option value="25">25</option>
              <option value="50">50</option>
              <option value="100" selected>100</option>
            </select>
          </div>
        </section>
      </aside>

      <%= if info = @flash["info"] do %>
        <div class="alert-banner alert-info"><%= info %></div>
      <% end %>
      <%= if err = @flash["error"] do %>
        <div class="alert-banner alert-error"><%= err %></div>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>

        <% stalled_entries = stalled_running_entries(@payload.running) %>
        <%= if stalled_entries != [] and not @stalled_alert_dismissed do %>
          <div class="alert-banner">
            <div class="alert-content">
              <strong>Stalled agents detected:</strong>
              <%= stalled_entries |> Enum.map(& &1.issue_identifier) |> Enum.join(", ") %>
              <%= if length(stalled_entries) == 1 do %>
                has been stalled for <%= format_stall_duration(hd(stalled_entries).last_event_at, @now) %>.
              <% else %>
                have been stalled.
              <% end %>
            </div>
            <button type="button" class="subtle-button" phx-click="dismiss_stalled_alert">Dismiss</button>
          </div>
        <% end %>

        <%= for project <- (@payload[:projects] || []) do %>
          <% agent_settings = project_agent_settings(@agent_setting_drafts, project) %>
          <article class={"project-section" <> if(Map.get(project, :paused, false), do: " project-section--paused", else: "")}>
            <header class="project-section-header">
              <div class="project-section-title-block">
                <h2 class="project-section-name">
                  <%= project.name %>
                  <%= if Map.get(project, :paused, false) do %>
                    <span class="chip chip--warn">Paused</span>
                  <% end %>
                </h2>
                <p class="project-section-counts">
                  <span class="numeric"><%= Map.get(project, :running_count, length(project.running)) %></span>
                  <%= if max = Map.get(project, :max_concurrent_agents) do %>
                    <span class="muted">/<%= max %></span>
                  <% end %>
                  <span class="muted">running</span>
                  <%= if (Map.get(project, :retrying_count, length(project.retrying)) || 0) > 0 do %>
                    · <span class="numeric"><%= Map.get(project, :retrying_count, length(project.retrying)) %></span>
                    <span class="muted">retrying</span>
                  <% end %>
                </p>
              </div>

              <div class="project-section-controls">
                <form phx-submit="set_project_concurrency" class="inline-form project-concurrency-control">
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"concurrency-#{project.name}"}>
                    <span class="simple-only">tasks at once</span>
                    <span class="advanced-only">concurrency</span>
                  </label>
                  <input
                    id={"concurrency-#{project.name}"}
                    type="number"
                    name="value"
                    min="1"
                    value={Map.get(project, :max_concurrent_agents) || ""}
                    class="inline-input inline-input--narrow"
                    title="Max concurrent agents (cli alias: cr)"
                  />
                  <button type="submit" class="subtle-button">Save</button>
                </form>

                <form
                  phx-change="preview_project_agent"
                  phx-submit="set_project_agent"
                  class="inline-form inline-form--agent advanced-only"
                >
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"agent-#{project.name}-#{agent_settings.kind}"}>agent</label>
                  <select
                    id={"agent-#{project.name}-#{agent_settings.kind}"}
                    name="agent_kind"
                    class="inline-input inline-input--narrow"
                  >
                    <%= for k <- Agent.known_kinds() do %>
                      <option value={k} selected={agent_settings.kind == k}><%= k %></option>
                    <% end %>
                  </select>

                  <label class="inline-label" for={"model-#{project.name}"}>model</label>
                  <input
                    id={"model-#{project.name}"}
                    type="text"
                    name="model"
                    value={agent_settings.model}
                    placeholder="default"
                    list={"model-suggestions-#{project.name}"}
                    class="inline-input inline-input--model"
                    phx-debounce="blur"
                    title="Model override passed to the agent CLI (cli alias: model)"
                  />
                  <datalist id={"model-suggestions-#{project.name}"}>
                    <%= for m <- model_suggestions(agent_settings.kind) do %>
                      <option value={m}></option>
                    <% end %>
                  </datalist>

                  <label class="inline-label" for={"effort-#{project.name}-#{agent_settings.kind}-#{agent_settings.effort}"}>
                    effort
                  </label>
                  <select
                    id={"effort-#{project.name}-#{agent_settings.kind}-#{agent_settings.effort}"}
                    name="effort"
                    class="inline-input inline-input--narrow"
                  >
                    <option value="" selected={agent_settings.effort == ""}>default</option>
                    <%= for level <- effort_levels(agent_settings.kind) do %>
                      <option value={level} selected={agent_settings.effort == level}><%= level %></option>
                    <% end %>
                  </select>

                  <button type="submit" class="subtle-button">Set</button>
                </form>

                <form phx-submit="set_project_providers" class="inline-form inline-form--wide advanced-only">
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"providers-#{project.name}"}>providers</label>
                  <input
                    id={"providers-#{project.name}"}
                    type="text"
                    name="value"
                    value={Enum.join(Map.get(project, :providers, []), ",")}
                    placeholder="cv1,cz2,ck1"
                    class="inline-input"
                    title="Comma-separated provider aliases (cli alias: c)"
                  />
                  <button type="submit" class="subtle-button">Save</button>
                </form>

                <button
                  type="button"
                  class="subtle-button"
                  phx-click="toggle_project_pause"
                  phx-value-project={project.name}
                >
                  <%= if Map.get(project, :paused, false), do: "Resume", else: "Pause" %>
                </button>
              </div>
            </header>

            <%= if project.running == [] and project.retrying == [] do %>
              <%= if Map.get(project, :paused, false) do %>
                <p class="empty-state simple-only">
                  This project is paused. Resume it when you want Cymphony to start ready issues again.
                </p>
              <% else %>
                <p class="empty-state simple-only">
                  Nothing is running right now. Cymphony is watching Linear and will start the next ready issue automatically.
                </p>
              <% end %>
              <p class="empty-state advanced-only">No active sessions.</p>
            <% end %>

            <%= if project.running != [] do %>
              <div class="session-row-list">
                <%= for entry <- project.running do %>
                  <% expanded? = MapSet.member?(@expanded_issue_ids, entry.issue_identifier) %>
                  <article class={"session-row" <> if(expanded?, do: " session-row--expanded", else: "")}>
                    <div class="session-row-summary">
                      <button
                        type="button"
                        class="session-row-disclosure"
                        phx-click="toggle_logs"
                        phx-value-issue={entry.issue_identifier}
                        aria-label={if expanded?, do: "Collapse", else: "Expand"}
                      >
                        <%= if expanded?, do: "▾", else: "▸" %>
                      </button>

                      <div class="session-row-id">
                        <%= if entry.issue_url do %>
                          <a href={entry.issue_url} target="_blank" rel="noopener" class="session-row-link"><%= entry.issue_identifier %></a>
                        <% else %>
                          <%= entry.issue_identifier %>
                        <% end %>
                      </div>

                      <div class="session-row-title" title={entry.issue_title || entry.last_message || ""}>
                        <%= entry.issue_title || entry.last_message || "" %>
                      </div>

                      <div class="session-row-chips">
                        <span class={chip_state_class(entry.state)}><%= entry.state %></span>
                        <%= if entry.stalled do %>
                          <span class="chip chip--danger">Stalled</span>
                        <% end %>
                        <%= if priority_label = priority_label(entry.priority) do %>
                          <span class={chip_priority_class(entry.priority)}><%= priority_label %></span>
                        <% end %>
                        <%= if entry.provider do %>
                          <span class="chip chip--accent advanced-only"><%= entry.provider %></span>
                        <% end %>
                        <%= if Map.get(entry, :agent_kind) do %>
                          <span class="chip chip--agent advanced-only"><%= entry.agent_kind %></span>
                        <% end %>
                        <%= if Map.get(entry, :model) do %>
                          <span class="chip chip--muted chip--truncate advanced-only" title={entry.model}><%= entry.model %></span>
                        <% end %>
                        <%= if Map.get(entry, :effort) do %>
                          <span class="chip chip--muted advanced-only"><%= entry.effort %></span>
                        <% end %>
                        <span class="chip chip--muted advanced-only"><%= entry.worker_host || "local" %></span>
                      </div>

                      <div class="session-row-runtime numeric">
                        <%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %>
                      </div>

                      <div class="session-row-tokens numeric" title={"In #{format_int(entry.tokens.input_tokens)} / Out #{format_int(entry.tokens.output_tokens)}"}>
                        <%= format_int(entry.tokens.total_tokens) %><%= if tps = format_session_tps(entry) do %><span class="tps"> · <%= tps %> t/s</span><% end %>
                      </div>

                      <button
                        type="button"
                        class="subtle-button danger"
                        phx-click="kill_issue"
                        phx-value-issue={entry.issue_identifier}
                      >
                        <span class="simple-only">Stop</span>
                        <span class="advanced-only">Kill</span>
                      </button>
                    </div>

                    <%= if expanded? do %>
                      <div class="session-row-detail">
                        <p class="autonomy-note simple-only">
                          Cymphony is continuing this task on its own. You can open the Linear issue for context or stop this run at any time.
                        </p>
                        <div class="session-row-detail-grid">
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Agent</span>
                            <span class="session-stat-value"><%= Map.get(entry, :agent_kind) || "claude" %></span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Model</span>
                            <span class="session-stat-value"><%= Map.get(entry, :model) || "default" %></span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Effort</span>
                            <span class="session-stat-value"><%= Map.get(entry, :effort) || "default" %></span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Provider</span>
                            <span class="session-stat-value"><%= entry.provider || "default" %></span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Tokens</span>
                            <span class="session-stat-value numeric">
                              <%= format_int(entry.tokens.total_tokens) %>
                              <span class="muted small">(in <%= format_int(entry.tokens.input_tokens) %> / out <%= format_int(entry.tokens.output_tokens) %>)</span>
                            </span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Turn</span>
                            <span class="session-stat-value numeric"><%= entry.turn_count %></span>
                          </div>
                          <div class="session-stat advanced-only">
                            <span class="session-stat-label">Session</span>
                            <span class="session-stat-value">
                              <%= if entry.session_id do %>
                                <button
                                  type="button"
                                  class="subtle-button"
                                  data-label="Copy ID"
                                  data-copy={entry.session_id}
                                  onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                                >Copy ID</button>
                              <% else %>
                                <span class="muted">n/a</span>
                              <% end %>
                            </span>
                          </div>
                          <div class="session-stat session-stat--wide advanced-only">
                            <span class="session-stat-label">Workspace</span>
                            <span class="session-stat-value">
                              <%= if entry.workspace_path do %>
                                <span class="mono workspace-path"><%= entry.workspace_path %></span>
                                <button
                                  type="button"
                                  class="subtle-button"
                                  data-label="Copy"
                                  data-copy={entry.workspace_path}
                                  onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                                >Copy</button>
                              <% else %>
                                <span class="muted">n/a</span>
                              <% end %>
                            </span>
                          </div>
                          <div class="session-stat session-stat--wide advanced-only">
                            <span class="session-stat-label">Restart with</span>
                            <% session_spec = session_run_spec_settings(@issue_run_spec_drafts, entry) %>
                            <form phx-change="preview_issue_run_spec" phx-submit="set_issue_run_spec" class="inline-form">
                              <input type="hidden" name="issue" value={entry.issue_identifier} />
                              <select name="agent_kind" class="inline-input inline-input--narrow" title="Harness (empty = keep)">
                                <option value="" selected={session_spec.kind in [nil, ""]}>keep</option>
                                <%= for k <- Agent.known_kinds() do %>
                                  <option value={k} selected={session_spec.kind == k}><%= k %></option>
                                <% end %>
                              </select>
                              <input
                                type="text"
                                name="provider"
                                value={session_spec.provider}
                                placeholder="provider"
                                class="inline-input inline-input--model"
                                title="Provider auth alias (empty = keep resolved)"
                              />
                              <input
                                type="text"
                                name="model"
                                value={session_spec.model}
                                placeholder="model"
                                list={"model-suggestions-session-#{entry.issue_identifier}"}
                                class="inline-input inline-input--model"
                                title="Model passed to the agent CLI (empty = keep resolved)"
                              />
                              <datalist id={"model-suggestions-session-#{entry.issue_identifier}"}>
                                <%= for m <- model_suggestions(session_spec.suggestion_kind) do %>
                                  <option value={m}></option>
                                <% end %>
                              </datalist>
                              <select name="effort" class="inline-input inline-input--narrow" title="Reasoning effort (keep = unchanged)">
                                <option value="" selected={session_spec.effort in [nil, ""]}>keep</option>
                                <%= for level <- effort_levels(session_spec.suggestion_kind) do %>
                                  <option value={level} selected={session_spec.effort == level}><%= level %></option>
                                <% end %>
                              </select>
                              <button type="submit" class="subtle-button" title="Kill this session and restart it immediately with these overrides">Restart</button>
                            </form>
                            <span class="muted small">Restart kills the session and redispatches with these overrides.</span>
                          </div>
                        </div>

                        <%= if entry.last_event do %>
                          <div class="session-row-activity">
                            <span class="session-stat-label simple-only">Latest update</span>
                            <span class={log_event_badge_class(entry.last_event) <> " advanced-only"}><%= entry.last_event %></span>
                            <span class="session-activity-message"><%= entry.last_message || "n/a" %></span>
                            <%= if entry.last_event_at do %>
                              <span class="mono numeric muted small advanced-only">@ <%= entry.last_event_at %></span>
                            <% end %>
                          </div>
                        <% end %>

                        <%= if entry.log_events == [] do %>
                          <p class="empty-state advanced-only">No log events yet.</p>
                        <% else %>
                          <ul class="log-list advanced-only">
                            <%= for log <- entry.log_events do %>
                              <li class="log-event">
                                <span class="log-event-at"><%= format_log_at(log.at) %></span>
                                <span class={log_event_badge_class(log.event)}><%= log.event %></span>
                                <span class="log-event-message"><%= format_log_message(log.message) %></span>
                              </li>
                            <% end %>
                          </ul>
                        <% end %>

                        <% tail = Map.get(@harness_tails, entry.issue_identifier, %{issue_id: Map.get(entry, :issue_id), last_seq: 0, lines: [], follow: true}) %>
                        <% follow? = Map.get(tail, :follow, true) %>
                        <section
                          id={"harness-tail-" <> entry.issue_identifier}
                          class="harness-tail advanced-only"
                          phx-hook="HarnessTail"
                          data-follow={if follow?, do: "true", else: "false"}
                        >
                          <header class="harness-tail-header">
                            <span class="harness-tail-title">Harness</span>
                            <button type="button" class="subtle-button" phx-click="toggle_harness_follow" phx-value-issue={entry.issue_identifier}>
                              <%= if follow?, do: "Following", else: "Paused" %>
                            </button>
                          </header>
                          <pre class="harness-tail-body"><%= for line <- Map.get(tail, :lines, []) do %><div class="harness-tail-line" data-seq={line_seq(line)}><%= line_text(line) %></div><% end %></pre>
                        </section>
                      </div>
                    <% end %>
                  </article>
                <% end %>
              </div>
            <% end %>

            <%= if project.retrying != [] do %>
              <div class="retry-row-list">
                <p class="subsection-label simple-only">Waiting to try again</p>
                <p class="subsection-label advanced-only">Retry queue</p>
                <%= for entry <- project.retrying do %>
                  <article class="retry-row">
                    <div class="retry-row-id">
                      <%= if entry.issue_url do %>
                        <a href={entry.issue_url} target="_blank" rel="noopener" class="session-row-link"><%= entry.issue_identifier %></a>
                      <% else %>
                        <%= entry.issue_identifier %>
                      <% end %>
                    </div>
                    <div class="retry-row-attempt">
                      <span class="chip chip--warn">Attempt <%= entry.attempt %></span>
                      <%= if entry.due_at do %>
                        <span class="muted">due <%= format_retry_countdown(entry.due_at, @now) %></span>
                      <% end %>
                    </div>
                    <div class="retry-row-error advanced-only">
                      <%= if entry.error do %>
                        <span class="muted small mono"><%= String.slice(to_string(entry.error), 0, 120) %></span>
                      <% end %>
                    </div>
                    <span class="retry-row-guidance simple-only">Cymphony will retry automatically.</span>
                    <button
                      type="button"
                      class="subtle-button"
                      phx-click="retry_issue"
                      phx-value-issue={entry.issue_identifier}
                    >
                      Retry now
                    </button>
                  </article>
                <% end %>
              </div>
            <% end %>
          </article>
        <% end %>

        <%= if @payload[:recent_completed] && @payload.recent_completed != [] do %>
          <section class="section-card section--completions">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent completions</h2>
                <p class="section-copy simple-only"><%= length(@payload.recent_completed) %> recently finished tasks.</p>
                <p class="section-copy advanced-only">Last <%= length(@payload.recent_completed) %> agent runs. Cleared on daemon restart.</p>
              </div>
              <button
                type="button"
                class="subtle-button"
                data-collapse-toggle="completions"
                aria-label="Expand section"
                aria-expanded="false"
              >▸</button>
            </div>

            <div class="session-row-list">
              <%= for entry <- @payload.recent_completed do %>
                <article class="session-row session-row--completed">
                  <div class="session-row-summary">
                    <span class="session-row-disclosure" aria-hidden="true">✓</span>
                    <div class="session-row-id"><%= entry.issue_identifier %></div>
                    <div class="session-row-title muted small">
                      <%= if Map.get(entry, :project_name), do: entry.project_name, else: "" %>
                    </div>
                    <div class="session-row-chips">
                      <span class="chip chip--ok">Done</span>
                      <%= if Map.get(entry, :agent_kind) do %>
                        <span class="chip chip--agent advanced-only"><%= entry.agent_kind %></span>
                      <% end %>
                      <%= if Map.get(entry, :model) do %>
                        <span class="chip chip--muted chip--truncate advanced-only" title={entry.model}><%= entry.model %></span>
                      <% end %>
                      <span class="chip chip--muted advanced-only"><%= entry.worker_host || "local" %></span>
                    </div>
                    <div class="session-row-runtime numeric">
                      <%= format_runtime_seconds(entry.runtime_seconds || 0) %>
                    </div>
                    <div class="session-row-tokens numeric">
                      <%= format_int(entry.total_tokens) %>
                    </div>
                    <span class="muted small mono">
                      <%= if entry.ended_at, do: entry.ended_at, else: "" %>
                    </span>
                  </div>
                </article>
              <% end %>
            </div>
          </section>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp spawn_payload_load do
    pid = self()

    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      send(pid, {:payload_loaded, load_payload()})
    end)
  end

  # Use after a state-changing operation so the next render already shows the
  # updated value, not the previous one. Async refresh is fine for periodic
  # ticks but causes a one-frame flash of stale data on form submits.
  defp reload_payload_now(socket) do
    payload = load_payload()
    token_samples = update_token_samples(socket.assigns.token_samples, payload)

    socket
    |> assign(:payload, payload)
    |> assign(:token_samples, token_samples)
    |> assign(:last_payload_refresh, System.monotonic_time(:millisecond))
    |> update(:agent_setting_drafts, &prune_agent_drafts(&1, payload))
  end

  # A successful submit keeps a confirmed draft so the immediate render shows
  # the submitted values; once the payload reflects them the draft is redundant
  # and must go, or it would shadow later server-side changes.
  defp confirmed_agent_draft(settings) do
    case Map.get(settings, "agent") do
      kind when is_binary(kind) and kind != "" ->
        %{kind: kind, model: Map.get(settings, "model", ""), effort: Map.get(settings, "effort", "")}

      _ ->
        nil
    end
  end

  defp prune_agent_drafts(drafts, payload) do
    Enum.reduce(Map.get(payload, :projects) || [], drafts, &prune_one_draft/2)
  end

  defp prune_one_draft(project, drafts) do
    case Map.get(drafts, Map.get(project, :name)) do
      %{} = draft -> maybe_prune_draft(drafts, project, draft)
      _ -> drafts
    end
  end

  defp maybe_prune_draft(drafts, project, draft) do
    persisted = project_agent_settings(%{}, project)

    if draft.kind == persisted.kind and draft.model == persisted.model and
         draft.effort == persisted.effort do
      Map.delete(drafts, Map.get(project, :name))
    else
      drafts
    end
  end

  defp apply_confirmed_draft(drafts, project_name, nil), do: Map.delete(drafts, project_name)

  defp apply_confirmed_draft(drafts, project_name, confirmed),
    do: Map.put(drafts, project_name, confirmed)

  # Suggestions only — values are pass-through free text. Codex entries come
  # from the live `codex debug models` catalog (cached); claude from its
  # stable alias vocabulary.
  defp model_suggestions(kind) do
    kind
    |> CymphonyElixir.AgentCatalog.models()
    |> Enum.map(& &1.value)
  end

  defp effort_levels(kind), do: CymphonyElixir.AgentCatalog.efforts(kind, nil)

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
  end

  defp toggle_project_pause(payload, project_name) do
    case CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) ->
        project = Enum.find(payload[:projects] || [], &(&1.name == project_name))
        currently_paused = project && Map.get(project, :paused, false)
        action = if currently_paused, do: :resume, else: :pause
        spawn_orchestrator_pause_action(pid, action)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp spawn_orchestrator_pause_action(pid, :pause) do
    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      CymphonyElixir.Orchestrator.pause(pid)
    end)
  end

  defp spawn_orchestrator_pause_action(pid, :resume) do
    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      CymphonyElixir.Orchestrator.resume(pid)
    end)
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    get_in(payload, [:token_totals, :seconds_running]) || 0
  end

  defp autonomy_state(%{projects: [_project | _rest] = projects}) do
    project_count = length(projects)
    paused_count = Enum.count(projects, &Map.get(&1, :paused, false))

    cond do
      paused_count == 0 -> :on
      paused_count == project_count -> :paused
      true -> {:partial, project_count - paused_count, project_count}
    end
  end

  defp autonomy_state(%{polling: %{paused: true}}), do: :paused
  defp autonomy_state(%{polling: %{}}), do: :on
  defp autonomy_state(_payload), do: :unknown

  defp session_run_spec_settings(drafts, entry) do
    default_kind = Map.get(entry, :agent_kind) || ""

    default = %{
      kind: default_kind,
      model: Map.get(entry, :model) || "",
      effort: Map.get(entry, :effort) || "",
      provider: Map.get(entry, :provider) || "",
      suggestion_kind: suggestion_kind(default_kind, entry)
    }

    case Map.get(drafts, entry.issue_identifier) do
      nil ->
        default

      draft ->
        kind = Map.get(draft, :kind, default_kind)

        %{
          kind: kind,
          model: Map.get(draft, :model, default.model),
          effort: Map.get(draft, :effort, default.effort),
          provider: Map.get(draft, :provider, default.provider),
          suggestion_kind: suggestion_kind(kind, entry)
        }
    end
  end

  defp suggestion_kind(kind, entry) do
    if Agent.known_kind?(kind) do
      kind
    else
      Map.get(entry, :agent_kind)
    end
  end

  defp preview_issue_run_spec(socket, issue_identifier, kind, params) do
    if kind == "" or Agent.known_kind?(kind) do
      {:noreply, put_issue_run_spec_draft(socket, issue_identifier, kind, params)}
    else
      {:noreply, socket}
    end
  end

  defp put_issue_run_spec_draft(socket, issue_identifier, kind, params) do
    entry = find_running_entry(socket.assigns.payload, issue_identifier)
    current = session_run_spec_settings(socket.assigns.issue_run_spec_drafts, entry)
    agent_changed? = current.kind != kind

    draft = %{
      kind: kind,
      model: if(agent_changed?, do: "", else: Map.get(params, "model", "")),
      effort: if(agent_changed?, do: "", else: Map.get(params, "effort", "")),
      provider: Map.get(params, "provider", current.provider)
    }

    assign(socket, :issue_run_spec_drafts, Map.put(socket.assigns.issue_run_spec_drafts, issue_identifier, draft))
  end

  defp project_agent_settings(drafts, project) do
    kind = Map.get(project, :agent_kind)

    default = %{
      kind: if(Agent.known_kind?(kind), do: kind, else: "claude"),
      model: Map.get(project, :agent_model) || "",
      effort: Map.get(project, :agent_effort) || ""
    }

    Map.get(drafts, project.name, default)
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(Regex.compile!(".{3}(?=.)", "s"), "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp priority_label(1), do: "Urgent"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Medium"
  defp priority_label(4), do: "Low"
  defp priority_label(_), do: nil

  defp chip_priority_class(1), do: "chip chip--danger"
  defp chip_priority_class(2), do: "chip chip--warn"
  defp chip_priority_class(3), do: "chip chip--accent"
  defp chip_priority_class(4), do: "chip chip--muted"
  defp chip_priority_class(_), do: "chip"

  defp chip_state_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "chip chip--ok"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "chip chip--danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "chip chip--warn"
      true -> "chip"
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp format_log_at(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_log_at(at) when is_binary(at), do: at
  defp format_log_at(_), do: "n/a"

  defp format_log_message(nil), do: ""

  defp format_log_message(message) when is_binary(message) do
    if String.length(message) > 200 do
      String.slice(message, 0, 200) <> "…"
    else
      message
    end
  end

  defp format_log_message(message) do
    inspect(message, pretty: true, limit: 80)
  end

  defp log_event_badge_class(event) when is_binary(event) or is_atom(event) do
    base = "log-event-name"
    normalized = event |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["error", "failed", "exit"]) -> "#{base} log-event-danger"
      String.contains?(normalized, ["started", "ready", "dispatched"]) -> "#{base} log-event-success"
      String.contains?(normalized, ["completed", "ended"]) -> "#{base} log-event-accent"
      true -> base
    end
  end

  defp format_poll_countdown(nil, _now), do: "n/a"

  defp format_poll_countdown(ms, %DateTime{}) when is_integer(ms) do
    seconds = max(div(ms, 1_000), 0)
    "#{seconds}s"
  end

  defp format_poll_countdown(_ms, _now), do: "n/a"

  defp stalled_running_entries(running) do
    Enum.filter(running, & &1.stalled)
  end

  defp format_stall_duration(%DateTime{} = last_event_at, %DateTime{} = now) do
    seconds = DateTime.diff(now, last_event_at, :second)
    format_runtime_seconds(seconds)
  end

  defp format_stall_duration(last_event_at, %DateTime{} = now) when is_binary(last_event_at) do
    case DateTime.from_iso8601(last_event_at) do
      {:ok, parsed, _offset} -> format_stall_duration(parsed, now)
      _ -> "unknown"
    end
  end

  defp format_stall_duration(_, _), do: "unknown"

  defp format_retry_countdown(due_at, now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, parsed, _offset} ->
        diff = DateTime.diff(parsed, now, :second)
        if diff > 0, do: format_runtime_seconds(diff), else: "now"

      _ ->
        "n/a"
    end
  end

  defp format_retry_countdown(_, _), do: "n/a"

  defp update_token_samples(samples, payload) do
    now_ms = System.monotonic_time(:millisecond)
    total_tokens = get_in(payload, [:token_totals, :total_tokens]) || 0

    samples =
      [{now_ms, total_tokens} | samples]
      |> Enum.filter(fn {ts, _} -> now_ms - ts <= 600_000 end)
      |> Enum.take(200)

    samples
  end

  defp current_tps([]), do: 0.0
  defp current_tps([_]), do: 0.0

  defp current_tps(samples) do
    {start_ms, start_tokens} = List.last(samples)
    {end_ms, end_tokens} = List.first(samples)
    elapsed_ms = end_ms - start_ms
    delta_tokens = max(0, end_tokens - start_tokens)

    if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
  end

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  defp group_thousands(value) when is_binary(value) do
    value
    |> String.reverse()
    |> String.replace(Regex.compile!("(\\d{3})(?=\\d)"), "\\1,")
    |> String.reverse()
  end

  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @sparkline_columns 24
  @sparkline_window_ms 600_000

  defp tps_sparkline([]), do: ""
  defp tps_sparkline([_]), do: ""

  defp tps_sparkline(samples) do
    now_ms = System.monotonic_time(:millisecond)
    bucket_ms = div(@sparkline_window_ms, @sparkline_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@sparkline_columns - 1) * bucket_ms
    rates = interval_rates(samples)

    bucketed_tps =
      Enum.map(0..(@sparkline_columns - 1), fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @sparkline_columns - 1
        bucket_average_tps(rates, bucket_start, bucket_end, last_bucket?)
      end)

    render_sparkline(bucketed_tps)
  end

  # @token_samples is newest-first; sort oldest→newest so each interval has
  # positive elapsed_ms (newer - older) instead of a flat zero-rate sparkline.
  defp interval_rates(samples) do
    samples
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&interval_rate/1)
  end

  defp interval_rate([{start_ms, start_tokens}, {end_ms, end_tokens}]) do
    elapsed_ms = end_ms - start_ms
    delta_tokens = max(0, end_tokens - start_tokens)
    tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
    {end_ms, tps}
  end

  defp bucket_average_tps(rates, bucket_start, bucket_end, last_bucket?) do
    values =
      rates
      |> Enum.filter(fn {timestamp, _tps} ->
        in_sparkline_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
      end)
      |> Enum.map(fn {_timestamp, tps} -> tps end)

    if values == [] do
      0.0
    else
      Enum.sum(values) / length(values)
    end
  end

  defp in_sparkline_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_sparkline_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp render_sparkline(bucketed_tps) do
    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    Enum.map_join(bucketed_tps, fn value ->
      Enum.at(@sparkline_blocks, sparkline_index(value, max_tps), "▁")
    end)
  end

  defp sparkline_index(_value, max_tps) when max_tps <= 0, do: 0

  defp sparkline_index(value, max_tps) do
    round(value / max_tps * (length(@sparkline_blocks) - 1))
  end

  defp send_issue_command(socket, issue_identifier, command) do
    entry =
      Enum.find(socket.assigns.payload.running, &(&1.issue_identifier == issue_identifier)) ||
        Enum.find(socket.assigns.payload.retrying, &(&1.issue_identifier == issue_identifier)) ||
        %{}

    issue_id = Map.get(entry, :issue_id)
    project_name = Map.get(entry, :project_name)
    orchestrator_pid = lookup_orchestrator(project_name)

    if is_binary(issue_id) and orchestrator_addressable?(orchestrator_pid) do
      Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
        try do
          GenServer.call(orchestrator_pid, {command, issue_id}, 10_000)
        catch
          :exit, _ -> {:error, :unavailable}
        end
      end)
    end

    socket
  end

  defp orchestrator_addressable?(pid) when is_pid(pid), do: true
  defp orchestrator_addressable?(name) when is_atom(name) and not is_nil(name), do: true
  defp orchestrator_addressable?({:via, _, _}), do: true
  defp orchestrator_addressable?({:global, _}), do: true
  defp orchestrator_addressable?(_), do: false

  defp lookup_orchestrator(project_name) when is_binary(project_name) do
    case CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) -> pid
      _ -> orchestrator()
    end
  end

  defp lookup_orchestrator(_), do: orchestrator()

  defp maybe_override_param(map, _key, nil), do: map

  defp maybe_override_param(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp maybe_override_agent_kind(map, value) when is_binary(value) do
    trimmed = String.trim(value)

    if Agent.known_kind?(trimmed) do
      Map.put(map, :agent_kind, trimmed)
    else
      map
    end
  end

  defp maybe_override_agent_kind(map, _value), do: map

  defp expand_harness_tail(socket, identifier) do
    entry = find_running_entry(socket.assigns.payload, identifier)
    issue_id = Map.get(entry, :issue_id)

    if is_binary(issue_id) and issue_id != "" do
      # EP-STREAM
      _ = ObservabilityPubSub.subscribe_harness(issue_id)
      snapshot = CymphonyElixir.HarnessStream.snapshot(issue_id)

      tail = %{
        issue_id: Map.get(snapshot, :issue_id, issue_id),
        last_seq: Map.get(snapshot, :last_seq, 0),
        lines: Map.get(snapshot, :lines, []),
        follow: true,
        dropped: Map.get(snapshot, :dropped, 0)
      }

      assign(socket, :harness_tails, Map.put(socket.assigns.harness_tails, identifier, tail))
    else
      socket
    end
  end

  defp collapse_harness_tail(socket, identifier) do
    case Map.get(socket.assigns.harness_tails, identifier) do
      %{issue_id: issue_id} when is_binary(issue_id) ->
        # EP-STREAM
        _ = ObservabilityPubSub.unsubscribe_harness(issue_id)

      _ ->
        :ok
    end

    assign(socket, :harness_tails, Map.delete(socket.assigns.harness_tails, identifier))
  end

  defp find_running_entry(payload, identifier) do
    Enum.find(Map.get(payload, :running, []), &(&1.issue_identifier == identifier)) || %{}
  end

  defp format_count_breakdown(counts) when is_map(counts) do
    counts
    |> Enum.filter(fn {_key, count} -> is_number(count) and count > 0 end)
    |> Enum.sort_by(fn {key, count} -> {-count, to_string(key)} end)
    |> Enum.take(3)
    |> Enum.map_join(" · ", fn {key, count} -> "#{key} #{count}" end)
  end

  defp format_count_breakdown(_counts), do: ""

  defp format_session_tps(entry) when is_map(entry) do
    case Map.get(entry, :tokens_per_second) do
      tps when is_number(tps) and tps > 0 -> :erlang.float_to_binary(tps * 1.0, decimals: 1)
      _ -> nil
    end
  end

  defp merge_harness_tail(acc, identifier, tail, id, seq, new_lines, dropped) do
    if Map.get(tail, :issue_id) == id do
      Map.put(acc, identifier, append_harness_tail(tail, seq, new_lines, dropped))
    else
      acc
    end
  end

  defp append_harness_tail(tail, seq, new_lines, dropped) do
    current_seq = Map.get(tail, :last_seq, 0)

    incoming =
      new_lines
      |> List.wrap()
      |> Enum.filter(fn line -> line_seq(line) > current_seq end)

    merged = Enum.take(Map.get(tail, :lines, []) ++ incoming, -@harness_tail_cap)

    tail
    |> Map.put(:lines, merged)
    |> Map.put(:last_seq, harness_tail_last_seq(merged, current_seq, seq))
    |> Map.put(:dropped, dropped)
  end

  defp harness_tail_last_seq(merged, current_seq, seq) do
    merged
    |> Enum.map(&line_seq/1)
    |> Enum.max(fn -> current_seq end)
    |> max(normalize_harness_seq(seq))
  end

  defp normalize_harness_seq(seq) when is_integer(seq), do: seq
  defp normalize_harness_seq(_seq), do: 0

  defp line_seq(%{seq: seq}), do: seq
  defp line_seq(%{"seq" => seq}), do: seq
  defp line_seq(_line), do: 0

  defp line_text(%{text: text}), do: to_string(text)
  defp line_text(%{"text" => text}), do: to_string(text)
  defp line_text(_line), do: ""

  defp send_issue_run_spec(socket, entry, issue_id, overrides) do
    project_name = Map.get(entry, :project_name)
    orchestrator_pid = lookup_orchestrator(project_name)

    if orchestrator_addressable?(orchestrator_pid) do
      Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
        try do
          GenServer.call(orchestrator_pid, {:set_issue_run_spec, issue_id, overrides}, 10_000)
        catch
          :exit, _ -> {:error, :unavailable}
        end
      end)
    end

    socket
  end
end
