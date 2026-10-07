defmodule AiPair.PaneSupervisorBudgetTest do
  @moduledoc """
  Guard rows for the test-only restart pacing helper `AiPair.Test.PaneSupervisorBudget`
  (test/support): a stamp stays live one whole second longer than the supervisor counts it, and
  `await!/1` returns only once the real supervisor has a free restart slot.
  """

  use ExUnit.Case, async: false

  alias AiPair.Test.PaneSupervisorBudget

  test "a stamp is live through max_seconds plus one whole second, and not after" do
    assert PaneSupervisorBudget.live_count([10], 5, 15) == 1
    assert PaneSupervisorBudget.live_count([10], 5, 16) == 1
    assert PaneSupervisorBudget.live_count([10], 5, 17) == 0
    assert PaneSupervisorBudget.live_count([10, 12, 13], 5, 17) == 2
    assert PaneSupervisorBudget.live_count([], 5, 17) == 0
  end

  test "await! returns once the running AiPair.PaneSupervisor has a free restart slot" do
    if Process.whereis(AiPair.PaneSupervisor) == nil do
      assert_raise RuntimeError, ~r/is not running/, fn -> PaneSupervisorBudget.await!(100) end
    else
      assert PaneSupervisorBudget.await!() == :ok

      %{restarts: restarts, max_restarts: max, max_seconds: period} =
        :sys.get_state(AiPair.PaneSupervisor)

      assert PaneSupervisorBudget.live_count(restarts, period, :erlang.monotonic_time(1)) < max
    end
  end
end
