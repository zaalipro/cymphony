defmodule CymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cymphony.
  """

  use Phoenix.LiveView, layout: {CymphonyElixirWeb.Layouts, :app}

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

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
      |> assign(:filter_project, nil)
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
  def handle_event("filter_project", %{"project" => project}, socket) do
    filter = if project == "", do: nil, else: project
    {:noreply, assign(socket, :filter_project, filter)}
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
    apply_pause_to_all(:pause)
    spawn_payload_load()
    {:noreply, put_flash(socket, :info, "Dispatch paused — running sessions will complete normally")}
  end

  @impl true
  def handle_event("resume_dispatch", _params, socket) do
    apply_pause_to_all(:resume)
    spawn_payload_load()
    {:noreply, put_flash(socket, :info, "Dispatch resumed")}
  end

  @impl true
  def handle_event("set_concurrency", %{"value" => raw_value}, socket) do
    case parse_concurrency(raw_value) do
      {:ok, n} ->
        apply_concurrency_to_all(n)
        spawn_payload_load()

        {:noreply, put_flash(socket, :info, "Concurrency set to #{n}; persisted to ~/.cymphony/config.json")}

      :error ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a positive integer")}
    end
  end

  @impl true
  def handle_event("toggle_project_pause", %{"project" => project_name}, socket) do
    case toggle_project_pause(socket.assigns.payload, project_name) do
      :ok ->
        spawn_payload_load()
        {:noreply, socket}

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
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Cymphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Cymphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <span class="version-badge">v<%= @version %></span>
            <button
              type="button"
              class="subtle-button"
              phx-click="refresh_now"
            >
              Refresh
            </button>
          </div>
        </div>
      </header>

      <%= if info = @flash["info"] do %>
        <div class="alert-banner alert-info">
          <%= info %>
        </div>
      <% end %>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <%= if @payload[:projects] do %>
          <section class="project-grid">
            <%= for project <- @payload.projects do %>
              <article class={"project-mini-card" <> if(Map.get(project, :paused, false), do: " project-mini-card-paused", else: "")}>
                <div class="project-mini-header">
                  <p class="project-mini-name"><%= project.name %></p>
                  <%= if Map.get(project, :paused, false) do %>
                    <span class="state-badge state-badge-warning">Paused</span>
                  <% end %>
                </div>
                <div class="project-mini-stats">
                  <span class="project-mini-stat">
                    <span class="project-mini-value numeric"><%= project.running %></span>
                    <span class="project-mini-label">running</span>
                  </span>
                  <span class="project-mini-stat">
                    <span class="project-mini-value numeric"><%= project.retrying %></span>
                    <span class="project-mini-label">retrying</span>
                  </span>
                </div>
                <div class="project-mini-actions">
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="toggle_project_pause"
                    phx-value-project={project.name}
                  >
                    <%= if Map.get(project, :paused, false), do: "Resume", else: "Pause" %>
                  </button>
                </div>
              </article>
            <% end %>
          </section>
        <% end %>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.claude_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.claude_totals.input_tokens) %> / Out <%= format_int(@payload.claude_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Claude runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Throughput</p>
            <p class="metric-value numeric"><%= format_tps(current_tps(@token_samples)) %></p>
            <p class="metric-detail"><%= tps_sparkline(@token_samples) %></p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Polling</h2>
              <p class="section-copy">Linear issue tracker refresh schedule.</p>
            </div>
            <div class="polling-controls">
              <%= if @payload.polling do %>
                <form phx-submit="set_concurrency" class="concurrency-form">
                  <label class="concurrency-label" for="concurrency-input">Concurrency</label>
                  <input
                    id="concurrency-input"
                    type="number"
                    name="value"
                    min="1"
                    value={Map.get(@payload.polling, :max_concurrent_agents) || ""}
                    class="concurrency-input"
                  />
                  <button type="submit" class="subtle-button">Set</button>
                </form>
                <%= if Map.get(@payload.polling, :paused, false) do %>
                  <button type="button" class="subtle-button" phx-click="resume_dispatch">
                    Resume
                  </button>
                <% else %>
                  <button type="button" class="subtle-button" phx-click="pause_dispatch">
                    Pause
                  </button>
                <% end %>
              <% end %>
            </div>
          </div>

          <%= if @payload.polling do %>
            <div class="polling-grid">
              <div class="polling-item">
                <span class="polling-label">Next poll</span>
                <span class="polling-value">
                  <%= cond do %>
                    <% Map.get(@payload.polling, :paused, false) -> %>
                      <span class="polling-live">Paused — new dispatches stopped</span>
                    <% @payload.polling.checking? -> %>
                      <span class="polling-live">Checking now…</span>
                    <% true -> %>
                      <%= format_poll_countdown(@payload.polling.next_poll_in_ms, @now) %>
                  <% end %>
                </span>
              </div>
              <%= if @payload.polling.poll_interval_ms do %>
                <div class="polling-item">
                  <span class="polling-label">Interval</span>
                  <span class="polling-value"><%= div(@payload.polling.poll_interval_ms, 1_000) %>s</span>
                </div>
              <% end %>
              <%= if Map.get(@payload.polling, :max_concurrent_agents) do %>
                <div class="polling-item">
                  <span class="polling-label">Concurrency</span>
                  <span class="polling-value numeric">
                    <%= Map.get(@payload.polling, :max_concurrent_agents) %>
                  </span>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="empty-state">Polling status unavailable.</p>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <%= if @payload.rate_limits do %>
            <%= case Presenter.format_rate_limits_for_web(@payload.rate_limits) do %>
              <% nil -> %>
                <p class="empty-state">Rate limit data unavailable.</p>
              <% formatted -> %>
                <div class="rate-limit-grid">
                  <div class="rate-limit-card">
                    <span class="rate-limit-id"><%= formatted.limit_id %></span>
                    <div class="rate-limit-buckets">
                      <%= if formatted.primary do %>
                        <div class="rate-limit-bucket">
                          <span class="rate-limit-bucket-label">Primary</span>
                          <span class="rate-limit-bucket-value"><%= formatted.primary.summary %></span>
                          <%= if formatted.primary.reset_in_seconds do %>
                            <span class="rate-limit-bucket-reset">resets in <%= formatted.primary.reset_in_seconds %>s</span>
                          <% end %>
                        </div>
                      <% end %>
                      <%= if formatted.secondary do %>
                        <div class="rate-limit-bucket">
                          <span class="rate-limit-bucket-label">Secondary</span>
                          <span class="rate-limit-bucket-value"><%= formatted.secondary.summary %></span>
                          <%= if formatted.secondary.reset_in_seconds do %>
                            <span class="rate-limit-bucket-reset">resets in <%= formatted.secondary.reset_in_seconds %>s</span>
                          <% end %>
                        </div>
                      <% end %>
                      <%= if formatted.credits do %>
                        <div class="rate-limit-bucket">
                          <span class="rate-limit-bucket-label">Credits</span>
                          <span class="rate-limit-bucket-value"><%= formatted.credits.summary %></span>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
            <% end %>
          <% else %>
            <p class="empty-state">No rate-limit data available.</p>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

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
              <button
                type="button"
                class="subtle-button"
                phx-click="dismiss_stalled_alert"
              >
                Dismiss
              </button>
            </div>
          <% end %>

          <%= if @payload[:projects] do %>
            <div class="filter-bar">
              <button
                type="button"
                class={filter_button_class(@filter_project == nil)}
                phx-click="filter_project"
                phx-value-project=""
              >
                All
              </button>
              <%= for project <- @payload.projects do %>
                <button
                  type="button"
                  class={filter_button_class(@filter_project == project.name)}
                  phx-click="filter_project"
                  phx-value-project={project.name}
                >
                  <%= project.name %>
                </button>
              <% end %>
            </div>
          <% end %>

          <% filtered_running = filter_running_by_project(@payload.running, @filter_project) %>

          <%= if filtered_running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="session-card-grid">
              <%= for entry <- filtered_running do %>
                <article class="session-card">
                  <div class="session-card-header">
                    <div class="session-card-identity">
                      <span class="session-card-issue-id">
                        <%= if entry.issue_url do %>
                          <a href={entry.issue_url} target="_blank" rel="noopener" class="session-card-issue-link">
                            <%= entry.issue_identifier %>
                          </a>
                        <% else %>
                          <%= entry.issue_identifier %>
                        <% end %>
                      </span>
                      <%= if entry.issue_title do %>
                        <span class="session-card-issue-title"><%= entry.issue_title %></span>
                      <% end %>
                      <div class="session-card-badges">
                        <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                        <%= if priority_label = priority_label(entry.priority) do %>
                          <span class={priority_badge_class(entry.priority)}><%= priority_label %></span>
                        <% end %>
                        <%= if entry.stalled do %>
                          <span class="state-badge state-badge-stalled">Stalled</span>
                        <% end %>
                        <span class="host-badge"><%= entry.worker_host || "local" %></span>
                        <%= if entry.provider do %>
                          <span class="provider-badge"><%= entry.provider %></span>
                        <% end %>
                        <%= if entry.project_name do %>
                          <span class="session-card-project-badge"><%= entry.project_name %></span>
                        <% end %>
                      </div>
                    </div>
                    <div class="session-card-actions">
                      <form phx-submit="set_provider" class="provider-form">
                        <input type="hidden" name="issue" value={entry.issue_identifier} />
                        <input
                          type="text"
                          name="provider"
                          value={entry.provider || ""}
                          placeholder="provider"
                          class="provider-input"
                        />
                        <button type="submit" class="subtle-button">Set</button>
                      </form>
                      <button
                        type="button"
                        class="subtle-button danger"
                        phx-click="kill_issue"
                        phx-value-issue={entry.issue_identifier}
                      >
                        Kill
                      </button>
                    </div>
                  </div>

                  <div class="session-card-stats">
                    <div class="session-stat">
                      <span class="session-stat-label">Runtime</span>
                      <span class="session-stat-value numeric">
                        <%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %>
                      </span>
                      <span class="session-stat-detail">Turn <%= entry.turn_count %></span>
                    </div>
                    <div class="session-stat">
                      <span class="session-stat-label">Tokens</span>
                      <span class="session-stat-value numeric"><%= format_int(entry.tokens.total_tokens) %></span>
                      <span class="session-stat-detail numeric">
                        In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %>
                      </span>
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
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </span>
                    </div>
                    <div class="session-stat">
                      <span class="session-stat-label">Workspace</span>
                      <span class="session-stat-value">
                        <%= if entry.workspace_path do %>
                          <span class="mono" style="font-size:0.78rem;word-break:break-all;">
                            <%= entry.workspace_path %>
                          </span>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy"
                            data-copy={entry.workspace_path}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </span>
                    </div>
                  </div>

                  <%= if entry.last_event do %>
                    <div class="session-card-activity">
                      <div class="session-activity-header">
                        <span class="session-stat-label">Last activity</span>
                        <%= if entry.last_event_at do %>
                          <span class="mono numeric" style="font-size:0.78rem;color:var(--muted);">
                            <%= entry.last_event_at %>
                          </span>
                        <% end %>
                      </div>
                      <div class="session-activity-content">
                        <span class={log_event_badge_class(entry.last_event)}>
                          <%= entry.last_event %>
                        </span>
                        <span class="session-activity-message">
                          <%= entry.last_message || "n/a" %>
                        </span>
                      </div>
                    </div>
                  <% end %>

                  <div class="session-card-log">
                    <div class="session-log-header">
                      <span class="session-log-title">Recent logs</span>
                      <button
                        type="button"
                        class="subtle-button"
                        phx-click="toggle_logs"
                        phx-value-issue={entry.issue_identifier}
                      >
                        <%= if MapSet.member?(@expanded_issue_ids, entry.issue_identifier) do %>Hide logs<% else %>Show logs<% end %>
                      </button>
                    </div>
                    <%= if MapSet.member?(@expanded_issue_ids, entry.issue_identifier) do %>
                      <div class="session-log-terminal">
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
                  </div>
                </article>
              <% end %>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <% filtered_retrying = filter_retrying_by_project(@payload.retrying, @filter_project) %>

          <%= if filtered_retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="session-card-grid">
              <%= for entry <- filtered_retrying do %>
                <article class="retry-card">
                  <div class="retry-card-header">
                    <div class="retry-card-identity">
                      <span class="retry-card-issue-id"><%= entry.issue_identifier %></span>
                      <div class="retry-card-badges">
                        <span class="state-badge state-badge-warning">Retry</span>
                        <span class="host-badge"><%= entry.worker_host || "local" %></span>
                        <%= if Map.get(entry, :project_name) do %>
                          <span class="session-card-project-badge"><%= entry.project_name %></span>
                        <% end %>
                      </div>
                    </div>
                    <div class="retry-card-countdown">
                      <span class="retry-countdown-value numeric">Attempt <%= entry.attempt %></span>
                      <span class="retry-countdown-label">
                        <%= if entry.due_at do %>
                          Due <%= format_retry_countdown(entry.due_at, @now) %>
                        <% else %>
                          Pending
                        <% end %>
                      </span>
                    </div>
                  </div>
                  <div class="retry-card-body">
                    <div class="retry-card-meta">
                      <%= if entry.workspace_path do %>
                        <span class="retry-meta-item">
                          <span class="mono" style="font-size:0.82rem;"><%= entry.workspace_path %></span>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy"
                            data-copy={entry.workspace_path}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy
                          </button>
                        </span>
                      <% end %>
                    </div>
                    <%= if entry.error do %>
                      <pre class="drawer-error"><%= entry.error %></pre>
                    <% end %>
                  </div>
                  <div class="retry-card-actions">
                    <button
                      type="button"
                      class="subtle-button"
                      phx-click="retry_issue"
                      phx-value-issue={entry.issue_identifier}
                    >
                      Retry now
                    </button>
                  </div>
                </article>
              <% end %>
            </div>
          <% end %>
        </section>

        <%= if @payload[:recent_completed] && @payload.recent_completed != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Recent completions</h2>
                <p class="section-copy">Last <%= length(@payload.recent_completed) %> agent runs that wrapped up. Cleared on daemon restart.</p>
              </div>
            </div>

            <div class="session-card-grid">
              <%= for entry <- @payload.recent_completed do %>
                <article class="retry-card">
                  <div class="retry-card-header">
                    <div class="retry-card-identity">
                      <span class="retry-card-issue-id"><%= entry.issue_identifier %></span>
                      <div class="retry-card-badges">
                        <span class="state-badge state-badge-success">Done</span>
                        <span class="host-badge"><%= entry.worker_host || "local" %></span>
                        <%= if Map.get(entry, :project_name) do %>
                          <span class="session-card-project-badge"><%= entry.project_name %></span>
                        <% end %>
                      </div>
                    </div>
                    <div class="retry-card-countdown">
                      <span class="retry-countdown-value numeric">
                        <%= format_runtime_seconds(entry.runtime_seconds || 0) %>
                      </span>
                      <span class="retry-countdown-label">
                        <%= format_int(entry.claude_total_tokens) %> tokens
                      </span>
                    </div>
                  </div>
                  <div class="retry-card-body">
                    <div class="retry-card-meta">
                      <%= if entry.workspace_path do %>
                        <span class="retry-meta-item">
                          <span class="mono" style="font-size:0.82rem;"><%= entry.workspace_path %></span>
                        </span>
                      <% end %>
                      <%= if entry.ended_at do %>
                        <span class="retry-meta-item">
                          <span class="mono" style="font-size:0.78rem;color:var(--muted);">ended <%= entry.ended_at %></span>
                        </span>
                      <% end %>
                    </div>
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

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
  end

  defp apply_pause_to_all(action) do
    case CymphonyElixir.ProjectSupervisor.list_orchestrators() do
      [] ->
        case action do
          :pause -> CymphonyElixir.Orchestrator.pause(orchestrator())
          :resume -> CymphonyElixir.Orchestrator.resume(orchestrator())
        end

      orchestrators ->
        Enum.each(orchestrators, fn {_project, pid} ->
          case action do
            :pause -> CymphonyElixir.Orchestrator.pause(pid)
            :resume -> CymphonyElixir.Orchestrator.resume(pid)
          end
        end)
    end
  end

  defp apply_concurrency_to_all(n) do
    case CymphonyElixir.ProjectSupervisor.list_orchestrators() do
      [] ->
        CymphonyElixir.Orchestrator.set_concurrency(orchestrator(), n)
        _ = CymphonyConfig.update_concurrency(nil, n)
        :ok

      orchestrators ->
        Enum.each(orchestrators, fn {project, pid} ->
          CymphonyElixir.Orchestrator.set_concurrency(pid, n)
          _ = CymphonyConfig.update_concurrency(project, n)
        end)
    end
  end

  defp parse_concurrency(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_concurrency(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_concurrency(_), do: :error

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

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp priority_label(1), do: "Urgent"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Medium"
  defp priority_label(4), do: "Low"
  defp priority_label(_), do: nil

  defp priority_badge_class(1), do: "priority-badge priority-badge-urgent"
  defp priority_badge_class(2), do: "priority-badge priority-badge-high"
  defp priority_badge_class(3), do: "priority-badge priority-badge-medium"
  defp priority_badge_class(4), do: "priority-badge priority-badge-low"
  defp priority_badge_class(_), do: "priority-badge"

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

  defp filter_running_by_project(running, nil), do: running

  defp filter_running_by_project(running, project) when is_binary(project) do
    Enum.filter(running, &(&1.project_name == project))
  end

  defp filter_retrying_by_project(retrying, nil), do: retrying

  defp filter_retrying_by_project(retrying, project) when is_binary(project) do
    Enum.filter(retrying, &(&1.project_name == project))
  end

  defp filter_button_class(true), do: "filter-button filter-button-active"
  defp filter_button_class(false), do: "filter-button"

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

    orchestrator_pid =
      if is_binary(project_name) do
        CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator)
      else
        orchestrator()
      end

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

  defp send_set_provider(socket, entry, issue_id, provider) do
    project_name = Map.get(entry, :project_name)

    orchestrator_pid =
      if is_binary(project_name) do
        CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator)
      else
        orchestrator()
      end

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
