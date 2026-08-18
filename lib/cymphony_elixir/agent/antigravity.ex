defmodule CymphonyElixir.Agent.Antigravity do
  @moduledoc """
  Antigravity CLI adapter: builds `agy -p …` commands and parses `stream-json`,
  `json`, and `text` output into the normalized turn result.

  Resume uses `--conversation <id>` (never `-c` / `--continue`, which resume the
  last session in cwd and would cross-pollute issues). MCP flags are not
  invented; operators can pass extras via `settings.extra_args`. `--effort` is
  never emitted: CLI Proxy model slugs already encode reasoning
  (`gemini-3.7-flash-high`) and agy rejects the flag on those models.

  Two flags are always built in because the CLI is unusable without them:

  * `--new-project` — without it `agy` ignores the cwd it was launched in and
    sandboxes itself into `~/.gemini/antigravity-cli/scratch`, so every run
    wrote its code outside the per-issue workspace and no PR could ever be
    produced. It is appended to fresh runs *and* to `--conversation` resumes
    (verified safe on both). `settings.new_project == false` is the escape
    hatch; any other value (including a missing key) keeps the flag.
  * `--log-file <workspace>/../.agy-<issue>.log` — stdout only ever carries the
    generic "Agent execution terminated due to error."; the real cause (HTTP
    400/429, auth failures) goes to the CLI's own log file, which otherwise
    lands in `~/.gemini/antigravity-cli/log/` under a timestamp nobody can
    correlate to an issue. It is written *beside* the workspace rather than
    inside it: the workspace root is the cloned repo root, so a log file in the
    tree ends up in the pull request. The path is resolved lexically, so under
    SSH remoting it names the remote workspace's sibling.
  """

  @behaviour CymphonyElixir.Agent

  @session_log_prefix ".agy-"

  @impl true
  def default_command, do: "agy"

  @impl true
  def auth_env_prefixes, do: ["ANTIGRAVITY_", "GOOGLE_", "GEMINI_", "API_TIMEOUT"]

  @impl true
  def auth_env_fallback, do: ["GOOGLE_API_KEY", "GEMINI_API_KEY"]

  @impl true
  def build_command(%{settings: settings} = run_spec) do
    command =
      case run_spec.command || Map.get(settings, :command) do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> default_command()
      end

    output_format =
      case Map.get(settings, :output_format) do
        fmt when is_binary(fmt) and fmt != "" -> fmt
        _ -> "stream-json"
      end

    args =
      ["-p", shell_escape(run_spec.prompt), "--output-format", shell_escape(output_format)]
      |> maybe_add_model(run_spec.model)
      |> maybe_add_conversation(run_spec.session_id)
      |> maybe_add_bool_flag(Map.get(settings, :skip_permissions) == true, "--dangerously-skip-permissions")
      |> maybe_add_bool_flag(Map.get(settings, :sandbox) == true, "--sandbox")
      |> maybe_add_print_timeout(Map.get(settings, :print_timeout))
      |> maybe_add_new_project(Map.get(settings, :new_project))
      |> maybe_add_log_file(run_spec.workspace)
      |> maybe_add_extra_args(Map.get(settings, :extra_args))

    {:ok, Enum.join([command | args], " ")}
  end

  @impl true
  def parse_output(lines, %{settings: settings}, on_message) do
    case Map.get(settings, :output_format) do
      "stream-json" -> parse_stream_json_output(lines, on_message)
      "json" -> parse_json_output(lines)
      _ -> parse_text_output(lines)
    end
  end

  defp parse_stream_json_output(lines, on_message) do
    initial = %{session_id: nil, last_message: nil, completed: nil, result_text: nil, usage: nil, status: nil}

    state =
      Enum.reduce(lines, initial, fn
        line, acc when is_binary(line) ->
          case Jason.decode(line) do
            {:ok, %{} = event} ->
              emit(on_message, %{event: :stream_event, payload: event, raw: line})
              integrate_event(acc, event)

            _ ->
              acc
          end

        _line, acc ->
          acc
      end)

    finalize_stream(state, lines)
  end

  defp finalize_stream(%{completed: completed, status: status} = state, lines) do
    cond do
      is_map(completed) and present?(status) and status != "SUCCESS" ->
        {:error, {:turn_failed, CymphonyElixir.Agent.redact_payload(completed["error"] || completed)}}

      is_map(completed) ->
        {:ok,
         %{
           session_id: state.session_id,
           result: state.result_text || state.last_message,
           usage: normalize_usage(state.usage),
           raw: Jason.encode!(completed)
         }}

      true ->
        {:error, {:no_result_in_stream, transcript_excerpt(lines)}}
    end
  end

  defp integrate_event(acc, %{"event" => "init"} = event) do
    init = event["init"]
    from_init = if is_map(init), do: init["conversation_id"], else: nil
    %{acc | session_id: event["conversation_id"] || from_init || acc.session_id}
  end

  defp integrate_event(acc, %{"event" => "step_update"} = event) do
    step = event["step_update"]

    acc
    |> maybe_append_text_delta(step)
    |> maybe_keep_step_usage(step)
  end

  defp integrate_event(acc, %{"event" => "result"} = event) do
    completed =
      case event["result"] do
        %{} = nested -> nested
        _ -> event
      end

    %{
      acc
      | completed: completed,
        session_id: completed["conversation_id"] || acc.session_id,
        result_text: completed["response"],
        usage: keep_usage(completed["usage"], acc.usage),
        status: completed["status"]
    }
  end

  defp integrate_event(acc, _event), do: acc

  defp maybe_append_text_delta(acc, %{"text_delta" => delta}) when is_binary(delta),
    do: %{acc | last_message: (acc.last_message || "") <> delta}

  defp maybe_append_text_delta(acc, _step), do: acc

  defp maybe_keep_step_usage(acc, %{"usage" => %{} = usage}), do: %{acc | usage: usage}
  defp maybe_keep_step_usage(acc, _step), do: acc

  defp keep_usage(%{} = usage, _prev), do: usage
  defp keep_usage(_usage, prev), do: prev

  defp parse_json_output(lines) do
    case find_last_json_line(lines) do
      nil ->
        {:error, {:no_json_output, transcript_excerpt(lines)}}

      line ->
        case Jason.decode(line) do
          {:ok, %{} = payload} ->
            finalize_json_payload(payload, line)

          {:error, decode_error} ->
            {:error, {:json_decode_failed, decode_error, transcript_excerpt([line])}}
        end
    end
  end

  defp finalize_json_payload(payload, line) do
    status = payload["status"]

    if present?(status) and status != "SUCCESS" do
      {:error, {:turn_failed, CymphonyElixir.Agent.redact_payload(payload["error"] || payload)}}
    else
      {:ok,
       %{
         session_id: payload["conversation_id"],
         result: payload["response"],
         usage: normalize_usage(payload["usage"]),
         raw: line
       }}
    end
  end

  defp parse_text_output(lines) do
    joined = Enum.join(lines, "\n")
    {:ok, %{session_id: nil, result: joined, usage: nil, raw: joined}}
  end

  defp find_last_json_line(lines) when is_list(lines) do
    lines |> Enum.reverse() |> Enum.find(&json_line?/1)
  end

  defp json_line?(line) when is_binary(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp json_line?(_), do: false

  defp normalize_usage(%{} = usage) do
    input = integer_or_zero(usage["input_tokens"])
    output = integer_or_zero(usage["output_tokens"])

    total =
      if Map.has_key?(usage, "total_tokens") do
        integer_or_zero(usage["total_tokens"])
      else
        input + output
      end

    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => total}
  end

  defp normalize_usage(_usage), do: nil

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp present?(nil), do: false
  defp present?(_value), do: true

  defp maybe_add_model(args, model) when is_binary(model) and model != "",
    do: args ++ ["--model", shell_escape(model)]

  defp maybe_add_model(args, _model), do: args

  defp maybe_add_conversation(args, session_id) when is_binary(session_id) and session_id != "",
    do: args ++ ["--conversation", shell_escape(session_id)]

  defp maybe_add_conversation(args, _session_id), do: args

  defp maybe_add_bool_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_bool_flag(args, _value, _flag), do: args

  defp maybe_add_print_timeout(args, timeout) when is_binary(timeout) and timeout != "",
    do: args ++ ["--print-timeout", shell_escape(timeout)]

  defp maybe_add_print_timeout(args, _timeout), do: args

  # Opt-out, not opt-in: only an explicit `false` drops the flag. A missing key
  # (hand-authored WORKFLOW.md, or the claude-section fallback `Agent.section/2`
  # returns when no antigravity embed exists) must still get the workspace.
  defp maybe_add_new_project(args, false), do: args
  defp maybe_add_new_project(args, _new_project), do: args ++ ["--new-project"]

  defp maybe_add_log_file(args, workspace) when is_binary(workspace) and workspace != "",
    do: args ++ ["--log-file", shell_escape(session_log_path(workspace))]

  defp maybe_add_log_file(args, _workspace), do: args

  # A *sibling* of the workspace, not a file inside it. The workspace root is
  # the repo root — `hooks.after_create` runs `git clone … .` into it and the
  # prompt tells the agent to `git status`, commit and push — so a log file in
  # the tree lands in the pull request. It grows (15 KB from one bare run) and
  # appends across retry attempts, so `.gitignore`-ing it would be a second
  # tracked change in every repo Cymphony touches.
  #
  # Path.expand/1 resolves the `..` lexically, without touching the filesystem,
  # so this still works for a remote workspace under SSH. The result stays a
  # direct child of `workspace.root` and is swept with the workspaces. agy
  # continues silently when the directory is missing.
  defp session_log_path(workspace) do
    Path.expand(Path.join([workspace, "..", "#{@session_log_prefix}#{Path.basename(workspace)}.log"]))
  end

  defp maybe_add_extra_args(args, extra), do: CymphonyElixir.Agent.append_extra_args(args, extra)

  defp transcript_excerpt(lines), do: CymphonyElixir.Agent.transcript_excerpt(lines)

  defp emit(on_message, details) when is_function(on_message, 1) do
    on_message.(Map.put(details, :timestamp, DateTime.utc_now()))
  end

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
