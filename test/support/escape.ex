defmodule AiPair.Test.Escape do
  @moduledoc """
  Independent fixture cleanup for the containment controls, ported to Orrisd
  main for R04 slice S11 from the reviewed lane RED
  `test/ai_pair/pane_restore/boot_wiring_test.exs` at
  `56b5c7b500a9c1f51b0ff8b5afce70c966142e24`. Contract and logic are the lane
  text; only the module name was changed so it can live under `test/support`.
  """

  # INDEPENDENT FIXTURE CLEANUP for the containment controls (F5, B4). The
  # controls drive contain!/restore! by hand (register_teardown: false) and
  # deliberately make containment fail, so they cannot rely on the mechanism
  # under test to clean up after them.
  #
  # CONTRACT (m_1789249820, m_1789251280): responsibility exists BEFORE
  # creation, for EVERY creation. A control calls `Escape.start!/1` first; that
  # starts this unlinked GenServer AND registers `teardown!/1` as the on_exit.
  # Before ANY process is created - boundary (guard, owner registry, collector),
  # root, child, grandchild, late spawn, helper caller - its creator calls
  # `reserve!/2` with a tag; the created process's FIRST action is
  # `enroll!/2` with that tag, which fulfils the reservation and blocks until
  # this registry has RECORDED it and answered; boundary processes are fulfilled
  # by their creator with `fulfil!/3`. Nothing is created without a prior
  # reservation; a self-enrolling fixture does nothing before it is recorded,
  # while a creator-fulfilled one (a boundary process, CC15's creator) may act
  # between its creation and its fulfilment - its reservation, not a record, is
  # what covers that interval.
  #
  # `abort!/2` (what teardown!/1 runs): phase :aborting (creation stops: every
  # later enrolment is answered `{:error, :aborting}` and the newborn exits);
  # kill and JOIN every recorded pid - creators included; then drain the
  # enrolment calls queued in this mailbox, each answered with the refusal and
  # its pid recorded, killed and joined; then the boundary: collector (its
  # terminate destroys the session), our guard (only when the name still
  # resolves to the pid we started - never an unrelated holder), owner. The
  # summary lists unjoined fixtures, unjoined boundary entries and PENDING
  # reservations. A pending reservation is an UNKNOWN acquisition: the abort is
  # UNRESOLVED, not empty, and nothing is cleared by calling it a fixture that
  # never existed. `teardown!/1` therefore raises on any non-empty summary and
  # leaves the Escape ALIVE with its ownership evidence; only a proven-empty
  # summary lets it stop and join the Escape LAST. A newborn that enrols after
  # an unresolved abort is recorded against its reservation, refused, killed
  # and joined, so a later abort can close.
  #
  # Seam: `hold_enrolments: true` records but withholds enrolment replies until
  # abort answers them with the refusal - the held cut point of CC15. Real
  # adapter restart is never called here.
  use GenServer

  def start!(opts \\ []) do
    {:ok, escape} = GenServer.start(__MODULE__, opts)
    ExUnit.Callbacks.on_exit(fn -> teardown!(escape) end)
    escape
  end

  @doc "Record responsibility for a process that does not exist yet."
  def reserve!(escape, tag), do: :ok = GenServer.call(escape, {:reserve, tag})

  @doc "Called by a fixture process as its FIRST action; fulfils `tag`, blocks until recorded, exits if aborting."
  def enroll!(escape, tag) do
    case GenServer.call(escape, {:enroll, tag}, :infinity) do
      :ok -> :ok
      {:error, :aborting} -> exit(:escape_aborting)
    end
  end

  @doc "Fulfil a reservation for a process the creator itself started (boundary processes)."
  def fulfil!(escape, tag, pid) when is_pid(pid),
    do: :ok = GenServer.call(escape, {:fulfil, tag, pid})

  @doc "Record the inert boundary (guard, owner registry, collector) for joining at abort."
  def own_boundary!(escape, boundary) when is_map(boundary),
    do: :ok = GenServer.call(escape, {:own_boundary, boundary})

  @doc "Stop creation, kill+join every recorded pid, drain queued newborns, stop+join the boundary. Returns the summary."
  def abort!(escape, budget_ms), do: GenServer.call(escape, {:abort, budget_ms}, budget_ms + 1_000)

  @doc """
  The registered on_exit: aborts and REQUIRES an empty summary. On anything
  unresolved it raises with the summary and leaves the Escape alive; only on
  proven completion does it stop and join the Escape, LAST.
  """
  def teardown!(escape) do
    summary = abort!(escape, 10_000)

    if resolved?(summary) do
      ref = Process.monitor(escape)
      GenServer.stop(escape, :normal, 1_000)

      receive do
        {:DOWN, ^ref, :process, ^escape, _} -> :ok
      after
        1_000 -> raise "escape registry #{inspect(escape)} did not stop"
      end
    else
      raise "fixture cleanup UNRESOLVED (escape #{inspect(escape)} retained): #{inspect(summary)}"
    end
  end

  def resolved?(%{fixture_unjoined: [], boundary_unjoined: [], pending: []}), do: true
  def resolved?(_), do: false

  def recorded(escape), do: GenServer.call(escape, :recorded)
  def pending(escape), do: GenServer.call(escape, :pending)
  def boundary(escape), do: GenServer.call(escape, :boundary)

  @impl true
  def init(opts) do
    {:ok,
     %{
       phase: :open,
       pids: [],
       pending: [],
       held: [],
       hold: Keyword.get(opts, :hold_enrolments, false),
       boundary: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, tag}, _from, %{phase: :open} = state),
    do: {:reply, :ok, %{state | pending: [tag | state.pending]}}

  def handle_call({:reserve, _tag}, _from, state), do: {:reply, {:error, :aborting}, state}

  def handle_call({:enroll, tag}, {pid, _} = from, %{phase: :open} = state) do
    state = record(state, tag, pid)

    if state.hold,
      do: {:noreply, %{state | held: [from | state.held]}},
      else: {:reply, :ok, state}
  end

  # After abort began: still RECORD it (so it is accounted for and joined),
  # answer the refusal, and join it here - the newborn exits on the refusal.
  def handle_call({:enroll, tag}, {pid, _} = from, state) do
    state = record(state, tag, pid)
    GenServer.reply(from, {:error, :aborting})
    _ = kill_join(pid, System.monotonic_time(:millisecond) + 1_000)
    {:noreply, state}
  end

  def handle_call({:fulfil, tag, pid}, _from, state), do: {:reply, :ok, record(state, tag, pid)}

  def handle_call({:own_boundary, boundary}, _from, state),
    do: {:reply, :ok, %{state | boundary: Map.merge(state.boundary, boundary)}}

  def handle_call(:recorded, _from, state), do: {:reply, Enum.reverse(state.pids), state}
  def handle_call(:pending, _from, state), do: {:reply, Enum.reverse(state.pending), state}
  def handle_call(:boundary, _from, state), do: {:reply, state.boundary, state}

  def handle_call({:abort, budget_ms}, _from, state) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    state = %{state | phase: :aborting}
    # Held newborns are released into a refusal: they exit on their own, and are
    # joined below like everything else recorded.
    Enum.each(state.held, &GenServer.reply(&1, {:error, :aborting}))
    state = %{state | held: []}

    unjoined = Enum.reject(state.pids, &kill_join(&1, deadline))

    # Enrolments already queued behind this call belong to newborns whose
    # creators are now dead; each is recorded, refused and joined here rather
    # than left for the next handle_call.
    {state, late_unjoined} = drain_queued_enrolments(state, deadline, [])

    boundary = state.boundary
    collector = Map.get(boundary, :collector)
    guard = Map.get(boundary, :guard)
    name = Map.get(boundary, :name)
    owner = Map.get(boundary, :owner)

    boundary_unjoined =
      Enum.reject(
        [
          {:collector, collector, fn -> stop_join(collector, deadline) end},
          {:guard, guard,
           fn ->
             # Only OUR guard: the name must still resolve to the pid we started.
             if is_atom(name) and Process.whereis(name) == guard,
               do: stop_join(guard, deadline),
               else: not (is_pid(guard) and Process.alive?(guard))
           end},
          {:owner, owner, fn -> stop_join(owner, deadline) end}
        ],
        fn {_, pid, f} -> is_nil(pid) or f.() end
      )
      |> Enum.map(fn {what, pid, _} -> {what, pid} end)

    {:reply,
     %{
       fixture_unjoined: unjoined ++ late_unjoined,
       boundary_unjoined: boundary_unjoined,
       pending: Enum.reverse(state.pending),
       recorded: length(state.pids)
     }, state}
  end

  defp record(state, tag, pid) do
    %{
      state
      | pids: if(pid in state.pids, do: state.pids, else: [pid | state.pids]),
        pending: List.delete(state.pending, tag)
    }
  end

  defp drain_queued_enrolments(state, deadline, acc) do
    receive do
      {:"$gen_call", {pid, _} = from, {:enroll, tag}} ->
        state = record(state, tag, pid)
        GenServer.reply(from, {:error, :aborting})
        acc = if kill_join(pid, deadline), do: acc, else: [pid | acc]
        drain_queued_enrolments(state, deadline, acc)
    after
      0 -> {state, acc}
    end
  end

  defp kill_join(pid, deadline) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> true
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> false
    end
  end

  defp stop_join(pid, deadline) do
    if is_pid(pid) and Process.alive?(pid) do
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, max(deadline - System.monotonic_time(:millisecond), 1))
      catch
        :exit, _ -> :ok
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> true
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> false
      end
    else
      true
    end
  end
end
