defmodule CymphonyElixir.Claude.DynamicToolTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Claude.DynamicTool

  test "tool_specs returns empty list since Claude has built-in tools" do
    assert [] = DynamicTool.tool_specs()
  end

  test "execute returns unsupported message for any tool" do
    response = DynamicTool.execute("linear_graphql", %{"query" => "{}"})

    assert response["success"] == false
    assert response["output"] =~ "not supported"
  end

  test "execute returns unsupported message for unknown tools" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false
    assert response["output"] =~ "not supported"
  end
end
