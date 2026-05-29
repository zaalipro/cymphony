defmodule CymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cymphony.
  """

  use Phoenix.LiveView, layout: {CymphonyElixirWeb.Layouts, :app}

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixirWeb.{Control, Endpoint, ObservabilityPubSub, Presenter}

  @version Mix.Project.config()[:version]
  @runtime_tick_ms 1_000
  @payload_refresh_ms 3_000
  @default_payload %{
    counts: %{running: 0, retrying: 0},
    running: [],
    retrying: [],
    claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil,
    polling: nil
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
  def handle_event("toggle_logs", %{"issue" => issue_id}, socket) do
    expanded = socket.assigns.expanded_issue_ids

    expanded =
      if MapSet.member?(expanded, issue_id) do
        MapSet.delete(expanded, issue_id)
      else
        MapSet.put(expanded, issue_id)
      end

    {:noreply, assign(socket, :expanded_issue_ids, expanded)}
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
  def handle_event("toggle_project_pause", %{"project" => project_name}, socket) do
    case toggle_project_pause(socket.assigns.payload, project_name) do
      :ok ->
        {:noreply, reload_payload_now(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project orchestrator not found: #{project_name}")}
    end
  end

  @impl true
  def handle_event("set_provider", %{"issue" => issue_identifier, "provider" => provider}, socket) do
    provider = String.trim(provider)

    entry =
      Enum.find(socket.assigns.payload.running, &(&1.issue_identifier == issue_identifier)) || %{}

    issue_id = Map.get(entry, :issue_id)

    if is_binary(issue_id) and provider != "" do
      send_set_provider(socket, entry, issue_id, provider)
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
     |> assign(:token_samples, token_samples)}
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
            <span class="brand-tagline">Operations</span>
          </div>
          <div class="command-bar-meta">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <span class="version-badge">v<%= @version %></span>

            <div class="theme-toggle" role="group" aria-label="Theme">
              <button type="button" class="theme-toggle-button" data-theme-set="light" title="Light theme" aria-label="Light theme">☀</button>
              <button type="button" class="theme-toggle-button" data-theme-set="dark" title="Dark theme" aria-label="Dark theme">☾</button>
              <button type="button" class="theme-toggle-button" data-theme-set="system" title="Follow system" aria-label="Follow system">⌂</button>
            </div>

            <button type="button" class="subtle-button" phx-click="refresh_now">Refresh</button>
          </div>
        </div>

        <%= unless @payload[:error] do %>
          <div class="command-bar-row command-bar-row--metrics">
            <div class="metric-pill">
              <span class="metric-pill-label">Run</span>
              <span class="metric-pill-value numeric"><%= @payload.counts.running %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label">Retry</span>
              <span class="metric-pill-value numeric"><%= @payload.counts.retrying %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label">Tokens</span>
              <span class="metric-pill-value numeric"><%= format_int(@payload.claude_totals.total_tokens) %></span>
              <span class="metric-pill-detail numeric" title="input / output">
                in <%= format_int(@payload.claude_totals.input_tokens) %> · out <%= format_int(@payload.claude_totals.output_tokens) %>
              </span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label">Runtime</span>
              <span class="metric-pill-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            </div>
            <div class="metric-pill metric-pill--throughput">
              <span class="metric-pill-label">Tput</span>
              <span class="metric-pill-value numeric"><%= format_tps(current_tps(@token_samples)) %></span>
              <span class="metric-pill-spark numeric"><%= tps_sparkline(@token_samples) %></span>
            </div>
          </div>

          <div class="command-bar-row command-bar-row--ops">
            <%= if @payload.polling do %>
              <div class="ops-cluster">
                <span class="ops-label">Polling</span>
                <span class="ops-value">
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
                  <span class="ops-divider" aria-hidden="true">·</span>
                  <span class="ops-value muted">every <%= div(@payload.polling.poll_interval_ms, 1_000) %>s</span>
                <% end %>
              </div>
            <% end %>

            <%= if @payload.rate_limits do %>
              <%= case Presenter.format_rate_limits_for_web(@payload.rate_limits) do %>
                <% nil -> %>
                <% formatted -> %>
                  <div class="ops-cluster">
                    <span class="ops-label">Limits</span>
                    <%= if formatted.primary do %>
                      <span class="ops-value">primary <%= formatted.primary.summary %></span>
                      <%= if formatted.primary.reset_in_seconds do %>
                        <span class="ops-value muted">resets <%= formatted.primary.reset_in_seconds %>s</span>
                      <% end %>
                    <% end %>
                    <%= if formatted.secondary do %>
                      <span class="ops-divider" aria-hidden="true">·</span>
                      <span class="ops-value">secondary <%= formatted.secondary.summary %></span>
                    <% end %>
                    <%= if formatted.credits do %>
                      <span class="ops-divider" aria-hidden="true">·</span>
                      <span class="ops-value">credits <%= formatted.credits.summary %></span>
                    <% end %>
                  </div>
              <% end %>
            <% end %>

            <%= if @payload.polling do %>
              <div class="ops-cluster ops-cluster--push">
                <%= if Map.get(@payload.polling, :paused, false) do %>
                  <button type="button" class="subtle-button subtle-button--accent" phx-click="resume_dispatch">Resume all</button>
                <% else %>
                  <button type="button" class="subtle-button" phx-click="pause_dispatch">Pause all</button>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </header>

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
                <form phx-submit="set_project_concurrency" class="inline-form">
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"concurrency-#{project.name}"}>concurrency</label>
                  <input
                    id={"concurrency-#{project.name}"}
                    type="number"
                    name="value"
                    min="1"
                    value={Map.get(project, :max_concurrent_agents) || ""}
                    class="inline-input inline-input--narrow"
                    title="Max concurrent agents (cli alias: cr)"
                  />
                </form>

                <form phx-submit="set_project_providers" class="inline-form inline-form--wide">
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"providers-#{project.name}"}>claude command</label>
                  <input
                    id={"providers-#{project.name}"}
                    type="text"
                    name="value"
                    value={Enum.join(Map.get(project, :providers, []), ",")}
                    placeholder="cv1,cz2,ck1"
                    class="inline-input"
                    title="Comma-separated provider aliases (cli alias: c)"
                  />
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
              <p class="empty-state">No active sessions.</p>
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
                          <span class="chip chip--accent"><%= entry.provider %></span>
                        <% end %>
                        <span class="chip chip--muted"><%= entry.worker_host || "local" %></span>
                      </div>

                      <div class="session-row-runtime numeric">
                        <%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %>
                      </div>

                      <div class="session-row-tokens numeric" title={"In #{format_int(entry.tokens.input_tokens)} / Out #{format_int(entry.tokens.output_tokens)}"}>
                        <%= format_int(entry.tokens.total_tokens) %>
                      </div>

                      <button
                        type="button"
                        class="subtle-button danger"
                        phx-click="kill_issue"
                        phx-value-issue={entry.issue_identifier}
                      >
                        Kill
                      </button>
                    </div>

                    <%= if expanded? do %>
                      <div class="session-row-detail">
                        <div class="session-row-detail-grid">
                          <div class="session-stat">
                            <span class="session-stat-label">Turn</span>
                            <span class="session-stat-value numeric"><%= entry.turn_count %></span>
                          </div>
                          <div class="session-stat">
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
                          <div class="session-stat session-stat--wide">
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
                          <div class="session-stat">
                            <span class="session-stat-label">Provider</span>
                            <form phx-submit="set_provider" class="inline-form">
                              <input type="hidden" name="issue" value={entry.issue_identifier} />
                              <input
                                type="text"
                                name="provider"
                                value={entry.provider || ""}
                                placeholder="provider"
                                class="inline-input inline-input--narrow"
                              />
                              <button type="submit" class="subtle-button">Set</button>
                            </form>
                          </div>
                        </div>

                        <%= if entry.last_event do %>
                          <div class="session-row-activity">
                            <span class={log_event_badge_class(entry.last_event)}><%= entry.last_event %></span>
                            <span class="session-activity-message"><%= entry.last_message || "n/a" %></span>
                            <%= if entry.last_event_at do %>
                              <span class="mono numeric muted small">@ <%= entry.last_event_at %></span>
                            <% end %>
                          </div>
                        <% end %>

                        <%= if entry.log_events == [] do %>
                          <p class="empty-state">No log events yet.</p>
                        <% else %>
                          <ul class="log-list">
                            <%= for log <- entry.log_events do %>
                              <li class="log-event">
                                <span class="log-event-at"><%= format_log_at(log.at) %></span>
                                <span class={log_event_badge_class(log.event)}><%= log.event %></span>
                                <span class="log-event-message"><%= format_log_message(log.message) %></span>
                              </li>
                            <% end %>
                          </ul>
                        <% end %>
                      </div>
                    <% end %>
                  </article>
                <% end %>
              </div>
            <% end %>

            <%= if project.retrying != [] do %>
              <div class="retry-row-list">
                <p class="subsection-label">Retry queue</p>
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
                    <div class="retry-row-error">
                      <%= if entry.error do %>
                        <span class="muted small mono"><%= String.slice(to_string(entry.error), 0, 120) %></span>
                      <% end %>
                    </div>
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
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent completions</h2>
                <p class="section-copy">Last <%= length(@payload.recent_completed) %> agent runs. Cleared on daemon restart.</p>
              </div>
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
                      <span class="chip chip--muted"><%= entry.worker_host || "local" %></span>
                    </div>
                    <div class="session-row-runtime numeric">
                      <%= format_runtime_seconds(entry.runtime_seconds || 0) %>
                    </div>
                    <div class="session-row-tokens numeric">
                      <%= format_int(entry.claude_total_tokens) %>
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
  end

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
    get_in(payload, [:claude_totals, :seconds_running]) || 0
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
    total_tokens = get_in(payload, [:claude_totals, :total_tokens]) || 0

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

    rates =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{start_ms, start_tokens}, {end_ms, end_tokens}] ->
        elapsed_ms = end_ms - start_ms
        delta_tokens = max(0, end_tokens - start_tokens)
        tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
        {end_ms, tps}
      end)

    bucketed_tps =
      0..(@sparkline_columns - 1)
      |> Enum.map(fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @sparkline_columns - 1

        values =
          rates
          |> Enum.filter(fn {timestamp, _tps} ->
            if last_bucket? do
              timestamp >= bucket_start and timestamp <= bucket_end
            else
              timestamp >= bucket_start and timestamp < bucket_end
            end
          end)
          |> Enum.map(fn {_, tps} -> tps end)

        if values == [] do
          0.0
        else
          Enum.sum(values) / length(values)
        end
      end)

    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    bucketed_tps
    |> Enum.map_join(fn value ->
      index =
        if max_tps <= 0 do
          0
        else
          round(value / max_tps * (length(@sparkline_blocks) - 1))
        end

      Enum.at(@sparkline_blocks, index, "▁")
    end)
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

  defp send_set_provider(socket, entry, issue_id, provider) do
    project_name = Map.get(entry, :project_name)
    orchestrator_pid = lookup_orchestrator(project_name)

    if orchestrator_addressable?(orchestrator_pid) do
      Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
        try do
          GenServer.call(orchestrator_pid, {:set_issue_provider, issue_id, provider}, 10_000)
        catch
          :exit, _ -> {:error, :unavailable}
        end
      end)
    end

    socket
  end
end
