defmodule AiPair.PaneSupervisorTest do
  use ExUnit.Case, async: false

  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  setup do
    pane_id = "%test-#{System.unique_integer([:positive])}"
    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)
    {:ok, pane_id: pane_id}
  end

  defp inert_opts do
    [
      classifier: MarkerClassifier,
      capture_fn: fn _ -> {:ok, ""} end,
      paste_fn: fn _, _ -> :ok end,
      poll_interval_ms: 1_000,
      idle_debounce_ms: 1_000
    ]
  end

  test "start_pane registers the pane and returns {:ok, pid}", %{pane_id: pane_id} do
    assert {:ok, pid} = PaneSupervisor.start_pane(pane_id, inert_opts())
    assert is_pid(pid)
    assert {:ok, ^pid} = PaneSupervisor.whereis_pane(pane_id)
  end

  test "starting the same pane twice returns :already_started", %{pane_id: pane_id} do
    assert {:ok, pid} = PaneSupervisor.start_pane(pane_id, inert_opts())

    assert {:error, {:already_started, ^pid}} =
             PaneSupervisor.start_pane(pane_id, inert_opts())
  end

  test "via_pane resolves through Registry for state/1 calls", %{pane_id: pane_id} do
    assert {:ok, _pid} = PaneSupervisor.start_pane(pane_id, inert_opts())
    via = PaneSupervisor.via_pane(pane_id)

    assert StateMachine.state(via) == :unknown
  end

  test "stop_pane terminates the child and unregisters", %{pane_id: pane_id} do
    assert {:ok, pid} = PaneSupervisor.start_pane(pane_id, inert_opts())
    assert :ok = PaneSupervisor.stop_pane(pane_id)
    refute Process.alive?(pid)
    assert :ok = wait_until_unregistered(pane_id)
  end

  defp wait_until_unregistered(pane_id, deadline_ms \\ 500) do
    end_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> PaneSupervisor.whereis_pane(pane_id) end)
    |> Enum.reduce_while(:not_yet, fn
      :error, _ ->
        {:halt, :ok}

      _, _ ->
        if System.monotonic_time(:millisecond) > end_at do
          {:halt, :timeout}
        else
          Process.sleep(10) && {:cont, :not_yet}
        end
    end)
  end

  test "whereis_pane returns :error for unknown pane" do
    assert :error = PaneSupervisor.whereis_pane("%nonexistent-#{System.unique_integer()}")
  end

  test "stop_pane on unknown pane returns {:error, :not_found}" do
    pane_id = "%nonexistent-#{System.unique_integer()}"
    assert {:error, :not_found} = PaneSupervisor.stop_pane(pane_id)
  end
end
