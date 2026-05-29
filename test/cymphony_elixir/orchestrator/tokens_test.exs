defmodule CymphonyElixir.Orchestrator.TokensTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Orchestrator.Tokens

  @ts ~U[2026-05-29 00:00:00Z]

  describe "apply_token_delta/2" do
    test "accumulates each field and clamps at zero" do
      totals = %{input_tokens: 10, output_tokens: 5, total_tokens: 15, seconds_running: 2}
      delta = %{input_tokens: 3, output_tokens: 4, total_tokens: 7, seconds_running: 1}

      assert Tokens.apply_token_delta(totals, delta) ==
               %{input_tokens: 13, output_tokens: 9, total_tokens: 22, seconds_running: 3}
    end

    test "missing accumulator/seconds default to zero" do
      assert %{input_tokens: 1, seconds_running: 0} =
               Tokens.apply_token_delta(%{}, %{input_tokens: 1, output_tokens: 1, total_tokens: 2})
    end
  end

  describe "extract_token_delta/2" do
    test "derives delta from absolute usage minus last-reported, tracking reported" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"input_tokens" => 100, "output_tokens" => 40, "total_tokens" => 140}}}

      running = %{
        claude_last_reported_input_tokens: 70,
        claude_last_reported_output_tokens: 30,
        claude_last_reported_total_tokens: 100
      }

      delta = Tokens.extract_token_delta(running, update)
      assert delta.input_tokens == 30
      assert delta.output_tokens == 10
      assert delta.total_tokens == 40
      assert delta.input_reported == 100
      assert delta.total_reported == 140
    end

    test "nil running entry is treated as a zero baseline" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}
      delta = Tokens.extract_token_delta(nil, update)
      assert delta.input_tokens == 5
      assert delta.total_tokens == 7
    end

    test "non-increasing usage yields zero delta but still records reported" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"input_tokens" => 50}}}
      running = %{claude_last_reported_input_tokens: 80}

      delta = Tokens.extract_token_delta(running, update)
      assert delta.input_tokens == 0
      assert delta.input_reported == 50
      assert delta.output_tokens == 0
    end

    test "reads nested params.msg.payload.info.total_token_usage" do
      usage = %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}

      update = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{"params" => %{"msg" => %{"payload" => %{"info" => %{"total_token_usage" => usage}}}}}
      }

      assert Tokens.extract_token_delta(%{}, update).total_tokens == 20
    end

    test "reads turn/completed usage and camelCase keys" do
      update = %{
        :event => :u,
        :timestamp => @ts,
        "payload" => %{"method" => "turn/completed", "usage" => %{"inputTokens" => 9, "outputTokens" => 1, "totalTokens" => 10}}
      }

      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 9
      assert delta.output_tokens == 1
      assert delta.total_tokens == 10
    end

    test "string-encoded integers are parsed" do
      update = %{:event => :u, :timestamp => @ts, "tokenUsage" => %{"total" => %{"total_tokens" => "42"}}}
      assert Tokens.extract_token_delta(%{}, update).total_tokens == 42
    end

    test "absent usage yields all-zero delta" do
      update = %{event: :u, timestamp: @ts}
      delta = Tokens.extract_token_delta(%{}, update)
      assert delta.input_tokens == 0
      assert delta.output_tokens == 0
      assert delta.total_tokens == 0
    end
  end

  describe "extract_rate_limits/1" do
    test "extracts a direct rate_limits bucket map" do
      rl = %{"limit_id" => "primary", "primary" => %{"remaining" => 10, "limit" => 100}}
      assert Tokens.extract_rate_limits(%{"rate_limits" => rl}) == rl
    end

    test "finds rate limits nested deep under payload" do
      rl = %{"limit_name" => "x", "credits" => %{"remaining" => 1}}
      assert Tokens.extract_rate_limits(%{"payload" => %{"deep" => rl}}) == rl
    end

    test "finds rate limits inside a list" do
      rl = %{:limit_id => "primary", :secondary => %{remaining: 2}}
      assert Tokens.extract_rate_limits(%{"payload" => [%{"noise" => 1}, rl]}) == rl
    end

    test "returns nil when no rate limits are present or input is not a map" do
      assert Tokens.extract_rate_limits(%{"foo" => "bar"}) == nil
      assert Tokens.extract_rate_limits(:not_a_map) == nil
    end
  end
end
