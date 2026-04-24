defmodule CymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cymphony.
  """

  use Phoenix.LiveView, layout: {CymphonyElixirWeb.Layouts, :app}

  alias CymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:expanded_issue_id, nil)
      |> assign(:stalled_alert_dismissed, false)
      |> assign(:filter_project, nil)
      |> assign(:token_samples, [])
      |> assign(:drawer_issue_id, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_logs", %{"issue" => issue_id}, socket) do
    currently_expanded = socket.assigns.expanded_issue_id
    expanded = if currently_expanded == issue_id, do: nil, else: issue_id

    if connected?(socket) do
      cond do
        expanded != nil and currently_expanded != expanded ->
          if currently_expanded, do: ObservabilityPubSub.unsubscribe_issue(currently_expanded)
          ObservabilityPubSub.subscribe_issue(expanded)

        expanded == nil and currently_expanded != nil ->
          ObservabilityPubSub.unsubscribe_issue(currently_expanded)

        true ->
          :ok
      end
    end

    {:noreply, assign(socket, :expanded_issue_id, expanded)}
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
  def handle_event("open_drawer", %{"issue" => issue_id}, socket) do
    if connected?(socket) do
      if socket.assigns.drawer_issue_id && socket.assigns.drawer_issue_id != issue_id do
        ObservabilityPubSub.unsubscribe_issue(socket.assigns.drawer_issue_id)
      end

      :ok = ObservabilityPubSub.subscribe_issue(issue_id)
    end

    {:noreply, assign(socket, :drawer_issue_id, issue_id)}
  end

  @impl true
  def handle_event("close_drawer", _params, socket) do
    if connected?(socket) and socket.assigns.drawer_issue_id do
      :ok = ObservabilityPubSub.unsubscribe_issue(socket.assigns.drawer_issue_id)
    end

    {:noreply, assign(socket, :drawer_issue_id, nil)}
  end

  @impl true
  def handle_event("drawer_click", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_issue", %{"issue" => issue_id}, socket) do
    {:noreply, send_issue_command(socket, issue_id, :kill_issue)}
  end

  @impl true
  def handle_event("retry_issue", %{"issue" => issue_id}, socket) do
    {:noreply, send_issue_command(socket, issue_id, :retry_issue_now)}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    _ = CymphonyElixir.Orchestrator.request_refresh(orchestrator())
    {:noreply, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()
    token_samples = update_token_samples(socket.assigns.token_samples, payload)

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())
     |> assign(:token_samples, token_samples)}
  end

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
              <article class="project-mini-card">
                <p class="project-mini-name"><%= project.name %></p>
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
          </div>

          <%= if @payload.polling do %>
            <div class="polling-grid">
              <div class="polling-item">
                <span class="polling-label">Next poll</span>
                <span class="polling-value">
                  <%= if @payload.polling.checking? do %>
                    <span class="polling-live">Checking now…</span>
                  <% else %>
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
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <%= if @payload[:projects] do %>
                    <col class="project-col" style="width: 8rem;" />
                  <% end %>
                  <col style="width: 6rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <%= if @payload[:projects] do %>
                      <th class="project-col">Project</th>
                    <% end %>
                    <th>Host</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Claude update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for entry <- filtered_running do %>
                    <tr>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <button
                            type="button"
                            class="subtle-button"
                            phx-click="open_drawer"
                            phx-value-issue={entry.issue_identifier}
                          >
                            Details
                          </button>
                          <button
                            type="button"
                            class="subtle-button"
                            phx-click="toggle_logs"
                            phx-value-issue={entry.issue_identifier}
                          >
                            <%= if @expanded_issue_id == entry.issue_identifier do %>Hide<% else %>Logs<% end %>
                          </button>
                        </div>
                      </td>
                      <td>
                        <div class="state-stack">
                          <span class={state_badge_class(entry.state)}>
                            <%= entry.state %>
                          </span>
                          <%= if entry.stalled do %>
                            <span class="state-badge state-badge-stalled">Stalled</span>
                          <% end %>
                        </div>
                      </td>
                      <%= if @payload[:projects] do %>
                        <td class="project-col"><%= entry.project_name %></td>
                      <% end %>
                      <td>
                        <span class="host-badge"><%= entry.worker_host || "local" %></span>
                      </td>
                      <td>
                        <div class="session-stack">
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
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                    <%= if @expanded_issue_id == entry.issue_identifier do %>
                      <tr class="log-row">
                        <td colspan={if @payload[:projects], do: 8, else: 7}>
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
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
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
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- filtered_retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="open_drawer"
                          phx-value-issue={entry.issue_identifier}
                        >
                          Details
                        </button>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>

      <%= if @drawer_issue_id do %>
        <% drawer_entry = find_drawer_entry(@payload, @drawer_issue_id) %>
        <div class="drawer-overlay" phx-click="close_drawer">
          <div class="drawer-panel" phx-click="drawer_click">
            <div class="drawer-header">
              <div>
                <p class="drawer-id"><%= drawer_entry.issue_identifier %></p>
                <span class={state_badge_class(drawer_entry.state)}><%= drawer_entry.state %></span>
              </div>
              <div class="drawer-actions">
                <%= if drawer_entry[:claude_app_server_pid] || Map.get(drawer_entry, :session_id) do %>
                  <button
                    type="button"
                    class="subtle-button danger"
                    phx-click="kill_issue"
                    phx-value-issue={drawer_entry.issue_identifier}
                  >
                    Kill
                  </button>
                <% end %>
                <%= if drawer_entry[:attempt] do %>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="retry_issue"
                    phx-value-issue={drawer_entry.issue_identifier}
                  >
                    Retry now
                  </button>
                <% end %>
                <button
                  type="button"
                  class="subtle-button"
                  phx-click="close_drawer"
                >
                  Close
                </button>
              </div>
            </div>

            <div class="drawer-body">
              <%= if drawer_entry.workspace_path do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Workspace</span>
                  <div class="drawer-row-value">
                    <span class="drawer-path"><%= drawer_entry.workspace_path %></span>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy"
                      data-copy={drawer_entry.workspace_path}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy
                    </button>
                  </div>
                </div>
              <% end %>

              <%= if drawer_entry.worker_host do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Host</span>
                  <span class="drawer-row-value"><%= drawer_entry.worker_host %></span>
                </div>
              <% end %>

              <%= if drawer_entry.session_id do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Session</span>
                  <span class="drawer-row-value mono"><%= drawer_entry.session_id %></span>
                </div>
              <% end %>

              <div class="drawer-row">
                <span class="drawer-row-label">Tokens</span>
                <div class="drawer-row-value">
                  <span class="token-pill">Total <strong><%= format_int(drawer_entry.tokens.total_tokens) %></strong></span>
                  <span class="token-pill">In <strong><%= format_int(drawer_entry.tokens.input_tokens) %></strong></span>
                  <span class="token-pill">Out <strong><%= format_int(drawer_entry.tokens.output_tokens) %></strong></span>
                </div>
              </div>

              <%= if drawer_entry.started_at do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Started</span>
                  <span class="drawer-row-value"><%= drawer_entry.started_at %></span>
                </div>
              <% end %>

              <%= if drawer_entry.turn_count > 0 do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Turns</span>
                  <span class="drawer-row-value"><%= drawer_entry.turn_count %></span>
                </div>
              <% end %>

              <%= if drawer_entry.last_event do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Last event</span>
                  <div class="drawer-row-value">
                    <span class="log-event-name"><%= drawer_entry.last_event %></span>
                    <%= if drawer_entry.last_message do %>
                      <span class="drawer-event-message"><%= drawer_entry.last_message %></span>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if drawer_entry.log_events != [] do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Recent logs</span>
                  <ul class="log-list">
                    <%= for log <- drawer_entry.log_events do %>
                      <li class="log-event">
                        <span class="log-event-at"><%= format_log_at(log.at) %></span>
                        <span class={log_event_badge_class(log.event)}><%= log.event %></span>
                        <span class="log-event-message"><%= format_log_message(log.message) %></span>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>

              <%= if drawer_entry.error do %>
                <div class="drawer-row">
                  <span class="drawer-row-label">Error</span>
                  <pre class="drawer-error"><%= drawer_entry.error %></pre>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
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

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

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

  defp log_event_badge_class(event) when is_binary(event) do
    base = "log-event-name"
    normalized = String.downcase(event)

    cond do
      String.contains?(normalized, ["error", "failed", "exit"]) -> "#{base} log-event-danger"
      String.contains?(normalized, ["started", "ready", "dispatched"]) -> "#{base} log-event-success"
      String.contains?(normalized, ["completed", "ended"]) -> "#{base} log-event-accent"
      true -> base
    end
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp format_poll_countdown(nil, _now), do: "n/a"

  defp format_poll_countdown(ms, %DateTime{} = now) when is_integer(ms) do
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

  defp find_drawer_entry(payload, issue_id) do
    running = Enum.find(payload.running, &(&1.issue_identifier == issue_id))
    retry = Enum.find(payload.retrying, &(&1.issue_identifier == issue_id))
    base = running || retry || %{issue_identifier: issue_id, state: "unknown"}

    Map.merge(
      %{
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
        log_events: [],
        turn_count: 0,
        workspace_path: nil,
        worker_host: nil,
        session_id: nil,
        started_at: nil,
        last_event: nil,
        last_message: nil,
        error: nil
      },
      base
    )
  end

  defp send_issue_command(socket, issue_id, command) do
    drawer_entry = find_drawer_entry(socket.assigns.payload, issue_id)
    project_name = Map.get(drawer_entry, :project_name)

    orchestrator_pid =
      if is_binary(project_name) do
        CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator)
      else
        orchestrator()
      end

    if is_pid(orchestrator_pid) do
      try do
        GenServer.call(orchestrator_pid, {command, issue_id})
      catch
        :exit, _ -> {:error, :unavailable}
      end
    end

    socket
  end
end
