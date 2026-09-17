defmodule AiPair.PaneRestore.Coordinator do
  @moduledoc """
  Per-pane ownership of transactions and their outstanding lifecycle effects.

  A transaction holder, its final disposition, and each submitted operation are
  separate ledger entries. Neither finishing a body nor receiving one reply can
  release other outstanding work. Request terms are sent once to the target PID
  resolved at admission, by a Coordinator-owned Task.Supervisor worker.

  Timeout and caller loss end waiting, not the effect. The worker remains owned
  and a late actual reply can discharge its own operation. A holder lost with
  pending operations can release only after all those operations answer. An
  explicit abort or unresolved body stays fenced until operator intervention,
  even after its owned effects reply. Those replies settle only their operations;
  they cannot resolve the separate uncertainty reported by the holder. Worker or
  target death is never a successful reply.

  This process has a temporary child specification: an automatic empty-ledger
  replacement would silently reopen unresolved panes. Its private supervisor is
  unlinked from the ledger, so even ledger loss does not cancel accepted effects.
  A guardian monitors the ledger and drains the actual workers before stopping
  and joining that supervisor. An unanswered live worker keeps its owner alive;
  no timeout is used to pretend that the effect has ended.
  """

  use GenServer, restart: :temporary
  require Logger

  @default_timeout 5_000
  @ledger_call_timeout 5_000

  @type pane_id :: String.t()
  @type target :: GenServer.server()
  @type op_ref :: reference()
  @type token :: reference()
  @type admission_error :: :pane_busy | :unresolved_operation | :coordinator_unavailable
  @type cause :: term()
  @type body_result :: {:ok, term()} | {:unresolved, cause()}
  @type submit_error ::
          admission_error()
          | :timeout
          | {:target_not_found, target()}
          | {:target_not_local, node()}
          | {:unresolved_operation, cause()}

  defmodule State do
    @moduledoc false
    defstruct panes: %{}, monitors: %{}, supervisor: nil, guardian: nil
  end

  @doc "Starts one ledger; only the optional registered name is configurable."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.split(opts, [:name]) do
      {known, []} ->
        GenServer.start_link(__MODULE__, :no_arguments, name: Keyword.get(known, :name, __MODULE__))

      {_known, unknown} ->
        {:error, {:unknown_options, Keyword.keys(unknown)}}
    end
  end

  @doc """
  Runs a tagged body once under a fence, or refuses before running it.

  Returns the exact `{:ok, value}` or `{:unresolved, cause}` only after its
  disposition is acknowledged by the admitting PID. A failed update returns
  `{:fence_update_failed, body_result, reason}` without losing the body result.
  Raises, throws and exits attempt a fail-closed abort and retain their original
  stack; any other body shape raises `{:bad_body_result, value}` after abort.
  """
  @spec transaction(pane_id(), (-> body_result())) ::
          body_result()
          | {:error, admission_error()}
          | {:fence_update_failed, body_result(), term()}
  def transaction(pane, fun) when is_binary(pane) and is_function(fun, 0) do
    with {:ok, owner} <- owner_for(pane),
         {:ok, token} <- admit(owner, {:acquire, pane}) do
      key = {__MODULE__, pane}
      previous = Process.put(key, owner)

      try do
        run_under_fence(owner, pane, token, fun)
      after
        if previous == nil, do: Process.delete(key), else: Process.put(key, previous)
      end
    end
  end

  defp run_under_fence(owner, pane, token, fun) do
    result =
      try do
        case fun.() do
          {tag, _value} = result when tag in [:ok, :unresolved] -> result
          invalid -> :erlang.error({:bad_body_result, invalid})
        end
      catch
        kind, reason ->
          stack = __STACKTRACE__
          _ = call_owner(owner, {:release, pane, token, {:aborted, kind, reason}})
          :erlang.raise(kind, reason, stack)
      end

    case call_owner(owner, {:release, pane, token, result}) do
      :ok -> result
      {:error, reason} -> {:fence_update_failed, result, reason}
    end
  end

  @doc """
  Sends a request term through an owned worker and waits for its actual reply.
  A timeout stops waiting and retains the operation and its worker in the ledger.
  The current transaction holder may submit without releasing its existing fence.
  """
  @spec submit(pane_id(), target(), term(), timeout()) :: {:ok, term()} | {:error, submit_error()}
  def submit(pane, target, request, timeout \\ @default_timeout)
      when is_binary(pane) and
             (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    with {:ok, owner} <- owner_for(pane),
         {:ok, op_ref, _worker} <- admit(owner, {:submit, pane, target, request, :awaited}) do
      await_outcome(owner, pane, op_ref, timeout)
    end
  end

  defp await_outcome(owner, pane, op_ref, timeout) do
    monitor = Process.monitor(owner)

    try do
      receive do
        {:operation_outcome, ^op_ref, outcome} -> outcome
        {:DOWN, ^monitor, :process, ^owner, _reason} -> {:error, :coordinator_unavailable}
      after
        timeout ->
          _ = call_owner(owner, {:caller_timed_out, pane, op_ref})
          {:error, :timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc "Submits a request term without waiting; returns the actual carrier PID."
  @spec submit_async(pane_id(), target(), term()) :: {:ok, pid()} | {:error, submit_error()}
  def submit_async(pane, target, request) when is_binary(pane) do
    with {:ok, owner} <- owner_for(pane),
         {:ok, _op_ref, worker} <- admit(owner, {:submit, pane, target, request, :detached}) do
      {:ok, worker}
    end
  end

  @doc "Lists live carriers of unresolved operations; unavailable is never an empty list."
  @spec effect_workers(GenServer.server()) ::
          {:ok, [{pane_id(), pid()}]} | {:error, :coordinator_unavailable}
  def effect_workers(server \\ __MODULE__) do
    with {:ok, owner} <- resolve_owner(server) do
      case call_owner(owner, :effect_workers) do
        {:error, _reason} -> {:error, :coordinator_unavailable}
        result -> result
      end
    end
  end

  # Holders keep using their admitting incarnation even if its name is replaced.
  defp owner_for(pane), do: resolve_owner(Process.get({__MODULE__, pane}, __MODULE__))

  defp resolve_owner(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :coordinator_unavailable}
    end
  end

  defp admit(owner, message) do
    case call_owner(owner, message) do
      {:error, :timeout} -> {:error, :coordinator_unavailable}
      result -> result
    end
  end

  defp call_owner(owner, message) do
    GenServer.call(owner, message, @ledger_call_timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _args}} -> {:error, :timeout}
    :exit, {_reason, {GenServer, :call, _args}} -> {:error, :coordinator_unavailable}
  end

  @impl true
  def init(:no_arguments) do
    owner = self()
    ready = make_ref()
    {guardian, monitor} = spawn_monitor(fn -> supervise_effects(owner, ready) end)

    receive do
      {^ready, supervisor} ->
        {:ok,
         %State{
           supervisor: supervisor,
           guardian: guardian,
           monitors: %{monitor => {:guardian, guardian}}
         }}

      {:DOWN, ^monitor, :process, ^guardian, reason} ->
        {:stop, {:effect_supervisor_start_failed, reason}}
    after
      @ledger_call_timeout ->
        # The guardian observes this process's resulting exit and owns teardown.
        {:stop, :effect_supervisor_start_timeout}
    end
  end

  # The guardian is the Task.Supervisor's actual parent. It is unlinked from the
  # ledger, but linked to the supervisor, and is itself monitored by the ledger.
  # After ledger death no new work can be admitted; the stable child inventory
  # is joined, followed by the supervisor. Normal teardown has the same path.
  defp supervise_effects(owner, ready) do
    owner_monitor = Process.monitor(owner)
    {:ok, supervisor} = Task.Supervisor.start_link()
    supervisor_monitor = Process.monitor(supervisor)
    send(owner, {ready, supervisor})

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        workers = Task.Supervisor.children(supervisor)
        monitors = Enum.map(workers, &{Process.monitor(&1), &1})

        Enum.each(monitors, fn {monitor, worker} ->
          receive do
            {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
          end
        end)

        Supervisor.stop(supervisor, :normal, @ledger_call_timeout)

        receive do
          {:DOWN, ^supervisor_monitor, :process, ^supervisor, _reason} -> :ok
        after
          @ledger_call_timeout -> exit(:effect_supervisor_join_timeout)
        end

      {:DOWN, ^supervisor_monitor, :process, ^supervisor, reason} ->
        exit({:effect_supervisor_lost, reason})
    end
  end

  @impl true
  def handle_call({:acquire, pane}, {caller, _tag}, state) do
    case Map.get(state.panes, pane) do
      nil ->
        token = make_ref()
        monitor = Process.monitor(caller)
        holder = %{owner: caller, token: token, monitor: monitor}
        entry = %{holder: holder, disposition: :completed, operations: %{}}

        state =
          state
          |> put_pane(pane, entry)
          |> put_monitor(monitor, {:holder, pane, token})

        {:reply, {:ok, token}, state}

      %{holder: holder} when holder != nil ->
        {:reply, {:error, :pane_busy}, state}

      _entry ->
        {:reply, {:error, :unresolved_operation}, state}
    end
  end

  def handle_call({:release, pane, token, result}, {caller, _tag}, state) do
    case Map.get(state.panes, pane) do
      %{holder: %{owner: ^caller, token: ^token, monitor: monitor}} = entry ->
        disposition = disposition(result, entry.operations)
        entry = %{entry | holder: nil, disposition: disposition}
        state = state |> forget_monitor(monitor) |> put_or_release(pane, entry)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_holder}, state}
    end
  end

  def handle_call({:submit, pane, target, request, mode}, {caller, _tag}, state) do
    case Map.get(state.panes, pane) do
      nil ->
        entry = %{holder: nil, disposition: :completed, operations: %{}}
        begin_operation(state, pane, entry, target, request, mode, caller)

      %{holder: %{owner: ^caller}} = entry ->
        begin_operation(state, pane, entry, target, request, mode, caller)

      %{holder: holder} when holder != nil ->
        {:reply, {:error, :pane_busy}, state}

      _ ->
        {:reply, {:error, :unresolved_operation}, state}
    end
  end

  def handle_call({:caller_timed_out, pane, ref}, {caller, _tag}, state) do
    case operation(state, pane, ref) do
      %{awaiting: %{pid: ^caller}} = op ->
        {:reply, :ok, stop_waiting(state, pane, op, :submit_caller_timeout)}

      _ ->
        {:reply, {:error, :not_awaiting}, state}
    end
  end

  # A private key, the operation reference, the pinned target, and the carrier's
  # call identity must all agree. Public introspection exposes none of the keys.
  # The acknowledgment precedes carrier exit, so a joined carrier's result is
  # already reflected in the ledger. Old worker_replied messages do nothing.
  def handle_call({:effect_result, pane, ref, key, target, outcome}, {worker, _tag}, state) do
    case operation(state, pane, ref) do
      %{worker: ^worker, reply_key: ^key, target: ^target, worker_alive: true} = op ->
        state =
          case outcome do
            {:reply, value} -> resolve_operation(state, pane, op, value)
            {:unanswered, cause} -> stop_waiting(state, pane, op, cause)
          end

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :stale_operation}, state}
    end
  end

  def handle_call(:effect_workers, _from, state) do
    workers =
      for {pane, entry} <- state.panes,
          {_ref, op} <- entry.operations,
          op.worker_alive,
          Process.alive?(op.worker),
          do: {pane, op.worker}

    {:reply, {:ok, workers}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.get(state.monitors, monitor) do
      {:guardian, ^pid} -> {:stop, {:effect_supervisor_lost, reason}, state}
      nil -> {:noreply, state}
      watched -> {:noreply, attribute_down(state, monitor, pid, watched, reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp disposition({:ok, _value}, _operations), do: :completed

  defp disposition({:unresolved, cause}, _operations), do: {:closed, cause}

  defp disposition({:aborted, kind, reason}, _operations),
    do: {:closed, {:transaction_aborted, kind, reason}}

  defp deferred_disposition(cause, operations) when map_size(operations) == 0,
    do: {:closed, cause}

  defp deferred_disposition(cause, operations),
    do: {:awaiting_replies, cause, MapSet.new(Map.keys(operations))}

  defp begin_operation(state, pane, entry, target, request, mode, caller) do
    case GenServer.whereis(target) do
      pid when is_pid(pid) and node(pid) == node() ->
        start_operation(state, pane, entry, pid, request, mode, caller)

      pid when is_pid(pid) ->
        {:reply, {:error, {:target_not_local, node(pid)}}, state}

      nil ->
        {:reply, {:error, {:target_not_found, target}}, state}

      {_name, remote} ->
        {:reply, {:error, {:target_not_local, remote}}, state}
    end
  end

  defp start_operation(state, pane, entry, target, request, mode, caller) do
    ref = make_ref()
    key = make_ref()
    owner = self()
    target_monitor = Process.monitor(target)

    {:ok, worker} =
      Task.Supervisor.start_child(state.supervisor, fn ->
        outcome =
          try do
            {:reply, GenServer.call(target, request, :infinity)}
          catch
            :exit, {_reason, {GenServer, :call, _args}} -> {:unanswered, :target_lost}
          end

        _ = call_owner(owner, {:effect_result, pane, ref, key, target, outcome})
      end)

    worker_monitor = Process.monitor(worker)

    awaiting =
      if mode == :awaited, do: %{pid: caller, monitor: Process.monitor(caller)}, else: nil

    op = %{
      ref: ref,
      reply_key: key,
      target: target,
      target_monitor: target_monitor,
      worker: worker,
      worker_monitor: worker_monitor,
      worker_alive: true,
      awaiting: awaiting,
      cause: nil
    }

    entry = %{entry | operations: Map.put(entry.operations, ref, op)}

    state =
      state
      |> put_pane(pane, entry)
      |> put_monitor(target_monitor, {:target, pane, ref})
      |> put_monitor(worker_monitor, {:worker, pane, ref})
      |> watch_awaiting(awaiting, pane, ref)

    {:reply, {:ok, ref, worker}, state}
  end

  defp watch_awaiting(state, nil, _pane, _ref), do: state

  defp watch_awaiting(state, %{monitor: monitor}, pane, ref),
    do: put_monitor(state, monitor, {:submit_caller, pane, ref})

  defp resolve_operation(state, pane, op, value) do
    entry = Map.fetch!(state.panes, pane)

    if op.cause != nil or entry.disposition != :completed do
      Logger.info("Late lifecycle effect reply for pane #{pane}")
    end

    notify(op, {:ok, value})
    disposition = discharge(entry.disposition, op.ref)
    entry = %{entry | operations: Map.delete(entry.operations, op.ref), disposition: disposition}

    state
    |> forget_monitor(op.worker_monitor)
    |> forget_monitor(op.target_monitor)
    |> forget_awaiting(op.awaiting)
    |> put_or_release(pane, entry)
  end

  defp discharge({:awaiting_replies, cause, refs}, ref) do
    remaining = MapSet.delete(refs, ref)
    if MapSet.size(remaining) == 0, do: :completed, else: {:awaiting_replies, cause, remaining}
  end

  defp discharge(disposition, _ref), do: disposition

  # Preserve the first cause and every unanswered operation/target/worker.
  # Only the waiter monitor is retired; a later actual reply remains attributable.
  defp stop_waiting(state, pane, op, cause) do
    if op.cause == nil, do: notify(op, {:error, {:unresolved_operation, cause}})
    updated = %{op | awaiting: nil, cause: op.cause || cause}
    state |> forget_awaiting(op.awaiting) |> put_operation(pane, updated)
  end

  defp notify(%{awaiting: %{pid: pid}, ref: ref}, result),
    do: send(pid, {:operation_outcome, ref, result})

  defp notify(%{awaiting: nil}, _result), do: :ok

  defp attribute_down(state, monitor, pid, {:holder, pane, token}, _reason) do
    case Map.get(state.panes, pane) do
      %{holder: %{owner: ^pid, token: ^token, monitor: ^monitor}} = entry ->
        entry = %{
          entry
          | holder: nil,
            disposition: deferred_disposition(:transaction_caller_lost, entry.operations)
        }

        state |> drop_monitor(monitor) |> put_or_release(pane, entry)

      _ ->
        state
    end
  end

  defp attribute_down(state, monitor, pid, {kind, pane, ref}, reason) do
    case operation(state, pane, ref) do
      nil -> state
      op -> operation_down(state, monitor, pid, kind, pane, op, reason)
    end
  end

  defp operation_down(state, monitor, pid, :submit_caller, pane, op, _reason) do
    case op.awaiting do
      %{pid: ^pid, monitor: ^monitor} ->
        state |> drop_monitor(monitor) |> stop_waiting(pane, op, :submit_caller_lost)

      _ ->
        state
    end
  end

  defp operation_down(state, monitor, pid, :worker, pane, op, reason) do
    if op.worker == pid and op.worker_monitor == monitor do
      cause = if reason == :normal, do: :worker_silent, else: {:worker_down, reason}
      op = %{op | worker_alive: false}
      state |> drop_monitor(monitor) |> stop_waiting(pane, op, cause)
    else
      state
    end
  end

  defp operation_down(state, monitor, pid, :target, pane, op, _reason) do
    if op.target == pid and op.target_monitor == monitor do
      state |> drop_monitor(monitor) |> stop_waiting(pane, op, :target_lost)
    else
      state
    end
  end

  defp operation(state, pane, ref) do
    case Map.get(state.panes, pane) do
      nil -> nil
      entry -> Map.get(entry.operations, ref)
    end
  end

  defp put_operation(state, pane, op) do
    entry = Map.fetch!(state.panes, pane)
    put_pane(state, pane, %{entry | operations: Map.put(entry.operations, op.ref, op)})
  end

  defp put_or_release(state, pane, %{holder: nil, disposition: :completed, operations: operations})
       when map_size(operations) == 0,
       do: %{state | panes: Map.delete(state.panes, pane)}

  defp put_or_release(state, pane, entry), do: put_pane(state, pane, entry)
  defp put_pane(state, pane, entry), do: %{state | panes: Map.put(state.panes, pane, entry)}

  defp put_monitor(state, monitor, watched),
    do: %{state | monitors: Map.put(state.monitors, monitor, watched)}

  defp drop_monitor(state, monitor), do: %{state | monitors: Map.delete(state.monitors, monitor)}
  defp forget_awaiting(state, nil), do: state
  defp forget_awaiting(state, %{monitor: monitor}), do: forget_monitor(state, monitor)

  defp forget_monitor(state, monitor) do
    Process.demonitor(monitor, [:flush])
    drop_monitor(state, monitor)
  end
end
