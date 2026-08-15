defmodule CymphonyElixir.Orchestrator.Tokens do
  @moduledoc """
  Token-usage and rate-limit extraction for agent worker updates.

  Claude, Codex, and Antigravity payloads carry token counts and rate-limit
  buckets under a variety of shapes and key conventions (bare `update[:usage]`
  on `:turn_completed`, stream-event `payload["usage"]`, nested `params`,
  camelCase vs snake_case). These pure functions normalize all of that into a
  per-update delta and an absolute rate-limit map. Extracted from the
  Orchestrator both to shrink it and to make this fiddly parsing directly
  unit-testable.
  """

  @type token_delta :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_reported: non_neg_integer(),
          output_reported: non_neg_integer(),
          total_reported: non_neg_integer()
        }

  @doc """
  Adds a per-update `token_delta` to a running `token_totals` accumulator,
  clamping each field at zero.
  """
  @spec apply_token_delta(map(), map()) :: map()
  def apply_token_delta(token_totals, token_delta) do
    input_tokens = Map.get(token_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(token_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(token_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(token_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  @doc """
  Computes the token delta for an update relative to the running entry's
  last-reported absolute counts.
  """
  @spec extract_token_delta(map() | nil, map()) :: token_delta()
  def extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(running_entry, :input, usage, :last_reported_input_tokens),
      compute_token_delta(running_entry, :output, usage, :last_reported_output_tokens),
      compute_token_delta(running_entry, :total, usage, :last_reported_total_tokens)
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  @doc """
  Extracts the rate-limit map from an update payload, or `nil` when none is
  present.
  """
  @spec extract_rate_limits(term()) :: map() | nil
  def extract_rate_limits(update) when is_map(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  def extract_rate_limits(_update), do: nil

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  # First integer_token_map among: (a) update[:usage]/update["usage"],
  # (b) payload["usage"], (c) type=="turn.completed", (d) event=="result",
  # (e) event=="step_update", (f) existing Claude nested paths.
  defp extract_token_usage(update) do
    payload = update[:payload] || Map.get(update, "payload")

    [
      integer_token_map_or_nil(update[:usage]),
      integer_token_map_or_nil(Map.get(update, "usage")),
      integer_token_map_or_nil(payload_usage_field(payload)),
      typed_turn_completed_usage(payload),
      result_event_usage(payload),
      step_update_usage(payload),
      claude_usage_from_update(update, payload)
    ]
    |> Enum.find(&is_map/1) || %{}
  end

  defp integer_token_map_or_nil(value) when is_map(value) do
    if integer_token_map?(value), do: value
  end

  defp integer_token_map_or_nil(_value), do: nil

  defp payload_usage_field(payload) when is_map(payload) do
    Map.get(payload, "usage") || Map.get(payload, :usage)
  end

  defp payload_usage_field(_payload), do: nil

  defp typed_turn_completed_usage(payload) when is_map(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)

    if type in ["turn.completed", "turn/completed", :turn_completed] do
      integer_token_map_or_nil(payload_usage_field(payload))
    end
  end

  defp typed_turn_completed_usage(_payload), do: nil

  defp result_event_usage(payload) when is_map(payload) do
    event = Map.get(payload, "event") || Map.get(payload, :event)

    if event in ["result", :result] do
      result = Map.get(payload, "result") || Map.get(payload, :result)

      nested =
        if is_map(result) do
          integer_token_map_or_nil(Map.get(result, "usage") || Map.get(result, :usage))
        end

      nested || integer_token_map_or_nil(payload_usage_field(payload))
    end
  end

  defp result_event_usage(_payload), do: nil

  defp step_update_usage(payload) when is_map(payload) do
    event = Map.get(payload, "event") || Map.get(payload, :event)

    if event in ["step_update", :step_update] do
      step = Map.get(payload, "step_update") || Map.get(payload, :step_update)

      if is_map(step) do
        integer_token_map_or_nil(Map.get(step, "usage") || Map.get(step, :usage))
      end
    end
  end

  defp step_update_usage(_payload), do: nil

  defp claude_usage_from_update(update, payload) do
    candidates = [
      update[:usage],
      Map.get(update, "usage"),
      payload,
      update
    ]

    Enum.find_value(candidates, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(candidates, &turn_completed_usage_from_payload/1)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    payload
    |> Map.values()
    |> Enum.find_value(&rate_limits_from_payload/1)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    Enum.find_value(payload, &rate_limits_from_payload/1)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total) do
    case payload_get(usage, [
           "total_tokens",
           "total",
           :total_tokens,
           :total,
           "totalTokens",
           :totalTokens
         ]) do
      total when is_integer(total) ->
        total

      _ ->
        input = get_token_usage(usage, :input)
        output = get_token_usage(usage, :output)

        if is_integer(input) or is_integer(output) do
          (input || 0) + (output || 0)
        end
    end
  end

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
