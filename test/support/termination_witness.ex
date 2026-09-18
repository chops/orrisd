defmodule AiPair.Test.TerminationWitness do
  @moduledoc """
  A plain owned process for the containment ordering control (CC6), ported to
  Orrisd main for R04 slice S11 from the reviewed lane RED at
  `56b5c7b500a9c1f51b0ff8b5afce70c966142e24`; only the module name changed.
  """

  # It enrols with the escape registry first (against the tag its creator
  # reserved), and GenServer.stop/3 runs terminate/2, which timestamps the
  # moment the guard drained it and records whether the collector was still
  # alive at that moment: on the ruled order it is not.
  use GenServer

  alias AiPair.Test.Escape

  @impl true
  def init(%{escape: escape, tag: tag, test: test}) do
    Escape.enroll!(escape, tag)
    {:ok, %{test: test, escape: escape}}
  end

  @impl true
  def terminate(_reason, %{test: test, escape: escape}) do
    # The collector pid is read from the escape's boundary record NOW, so the
    # witness could be enrolled with the guard before the collector existed.
    collector = Map.get(Escape.boundary(escape), :collector)

    send(
      test,
      {:witness_terminated, self(), System.monotonic_time(:microsecond),
       %{collector_alive?: is_pid(collector) and Process.alive?(collector)}}
    )

    :ok
  end
end
