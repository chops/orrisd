defmodule AiPair.Test.ContainmentCollector do
  @moduledoc """
  Producer containment by spawn provenance, ported to Orrisd main for R04 slice
  S11 from the reviewed lane RED `test/ai_pair/pane_restore/boot_wiring_test.exs`
  at `56b5c7b500a9c1f51b0ff8b5afce70c966142e24`. The algorithm is the lane text;
  only the module name (now `AiPair.Test.*`, so it lives under `test/support`
  beside `AiPair.Test.RouteGuard`) and the source citations were changed.
  """

  # PRODUCER CONTAINMENT BY SPAWN PROVENANCE (m_1789247933, the corrected
  # algorithm; F1-F6 of m_1789249509 and B3 of m_1789250979 applied). Replaces
  # the enrolment registry whose C1-C3 defects were: a cleanup that could not
  # veto restoration, enrolment that raced creation, and an inventory read from
  # a coordinator ExUnit had already stopped.
  #
  # The test owns exactly the processes it CREATED, and it creates them only
  # HERE. Every fixture root (the Boot container, the coordinator launcher) is
  # created by this collector, inside `acquire_root/3`, while the collector is
  # :open: the root is spawned PARKED - its body is a bare `receive :go` and can
  # create nothing - then RECORDED as owned, then the dedicated dynamic trace
  # session is armed on it (`:trace.process(session, root, true, [:procs,
  # :set_on_spawn])`, result verified == 1) and the record flips to armed, all
  # before the caller learns the pid. (Order: spawn parked, record, arm - the
  # record precedes the fallible arm, and the parked root cannot act before
  # either.) Release (`:go`) is a second, separately
  # phase-checked step. So no root can exist unowned, none can be created once
  # containment has begun, and none can be released after the owned set was
  # sealed (F1). An arm failure never loses the root (B3): it is killed and
  # joined; joined => retained as an UNARMED dead root, classified :no_trace
  # (killed/joined again in the fixed point, never flushed, never credited with
  # a delivery proof it cannot have); not joined => retained with the
  # acquisition latched UNRESOLVED, and containment fails on that latch
  # whatever else happens - an unresolved acquired root is never an empty set.
  # From release on, every process the root creates, and every process those
  # create, inherits the flags and announces itself here as `{:trace, parent,
  # :spawn, child, mfa}` / `{:trace, child, :spawned, parent, mfa}`. Ownership
  # extends ONLY through such an event whose parent is already owned; an event
  # whose parent is unknown is parked and, if still unresolved at seal time,
  # fails containment. Links and registered names carry no ownership here.
  #
  # LIFECYCLE (explicit and irreversible): :open -> :closing -> :sealed | :failed.
  # `{:contain!, deadline}` moves to :closing BEFORE the worklist snapshot and
  # runs the fixed point INSIDE handle_call, because the trace, monitor and
  # delivery messages it depends on arrive in THIS mailbox and must be consumed
  # here. Other calls that arrive meanwhile are ANSWERED, never swallowed:
  # acquisitions and releases are refused with the phase, inventory reads are
  # served. The fixed point is KILL and JOIN before FLUSH, per pid:
  #   1. Seed the worklist with every pid owned so far.
  #   2. For each pid: monitor it, `Process.exit(pid, :kill)`, and wait for ITS
  #      OWN `:DOWN` (a dead pid answers `:noproc` at once). No child's death is
  #      ever inferred from its parent's DOWN.
  #   3. Only after that DOWN, and only for TRACED pids (armed roots and their
  #      descendants), request `:trace.delivered(session, pid)` and wait for
  #      exactly that `{:trace_delivered, pid, ref}`; every descendant it
  #      announces joins the worklist and is itself killed, joined and flushed.
  #   4. While waiting, spawn events are consumed and ownership extended by
  #      verified parent-child provenance only.
  #   5. Seal (:sealed) when every discovered pid is dead (and flushed where
  #      traced), no parked unknown-parent event remains, no acquisition is
  #      latched unresolved, AND the deadline has not passed. Any wait that
  #      reaches the ONE absolute deadline answers `{:error, ...}` and the phase
  #      becomes :failed. The deadline is never renewed per pid.
  #
  # DESTROY AND STOP are driven by the guard: `{:destroy, deadline}` answers
  # `:ok` only from :sealed, within the deadline, and only when
  # `:trace.session_destroy/1` returned `true`; the guard then stops and joins
  # this process. `terminate/2` destroys the session again (idempotent boolean).
  #
  # ACQUISITION PROTOCOL (F2/B3): `start_and_enroll!/2` records a
  # `{:collector_reservation, ref}` with the guard BEFORE anything is started;
  # `init` creates the session and fulfils the reservation. A RETURNED refusal
  # and an EXIT/timeout of that call are both handled: the created session is
  # destroyed explicitly (`session_destroy/1` inside init, not left to
  # terminate/2, which is not an init-failure callback) and init stops. The
  # guard's reservation then stays unfulfilled and fails its containment as an
  # unknown acquisition. `session_probe:` (controls only) makes init arm a
  # parked probe process on the new session before fulfilling and report it, so
  # a control can observe that NO session traces that probe afterwards
  # (`:trace.session_info(probe) == []`) - the exact session, not a global
  # count. Bounded claim: that observation shows the session is gone; it does
  # not discriminate the explicit `session_destroy/1` call here from OTP's own
  # destruction when the last strong handle is lost (trace.erl documents both).
  # The explicit destroy is source-verified in init, not runtime-proven.
  #
  # Source basis (OTP 29.0.5 installed under the lane's .devenv, module docs
  # read, exports verified with Code.ensure_loaded/1 first): `:trace.session_create/3`,
  # `:trace.process/4` ("Returns a number indicating the number of processes
  # that matched"; `set_on_spawn` "Makes any process created by a traced process
  # inherit all its trace flags, including flag set_on_spawn itself"),
  # `:trace.delivered/2` (session-aware `erlang:trace_delivered/1`; reply
  # `{trace_delivered, Tracee, Ref}`), `:trace.session_destroy/1` ("Returns true
  # if the session was active. Returns false if the session had already been
  # destroyed"; it cleans up "all its settings on processes"),
  # `:trace.session_info/1` ("Return which trace sessions that affect a port,
  # process, function, or event ... a list of weak session handles or
  # `undefined` if the process/port/function does not exists"). Session name is
  # one stable atom; handles are unique per call.
  #
  # COVERAGE CLAIM, scoped: this collector covers the roots it created and their
  # spawn-descendants: the Boot container, Boot, Boot's reconciliation worker,
  # the coordinator launcher, the coordinator and the effect workers it
  # `spawn_monitor`s (coordinator.ex:191). Processes with other ancestors are NOT
  # covered: pane children started by the real PaneSupervisor (owned separately
  # with RouteGuard.own_pane/1), full-Application children and IPC handlers.
  #
  # TEST SEAMS (inert, controls only; absent in ordinary rows): `test:` receives
  # `{:collector_contained, pid, us}` at seal and `{:collector_destroyed, pid,
  # us}` at destroy; `contain_override:` answers a fixed term to contain!
  # instead of working; `after_first_join:` a 0-arity fun run once after the
  # first pid's DOWN and before its flush; `answer_after_deadline:` waits for
  # the guard's deadline to pass, then answers :ok; `arm_override:` replaces the
  # result of the trace arming call; `join_override:` replaces the outcome of
  # the arm-failure kill/join (`:unjoined` latches the acquisition unresolved
  # without needing a process that survives :kill); `session_probe:` as above.
  use GenServer

  alias AiPair.Test.RouteGuard

  @session_name :boot_wiring_containment

  @doc """
  Reserve with the guard, THEN start unlinked under the file-local name; init
  fulfils the reservation or destroys its session and stops. Raises with the
  reservation ref when the collector could not be started or enrolled: the
  reservation stays recorded and the guard's containment fails closed on it.
  """
  def start_and_enroll!(guard, opts \\ []) do
    ref = make_ref()

    case RouteGuard.reserve_collector(guard, ref) do
      :ok -> :ok
      other -> raise "collector reservation refused: #{inspect(other)}; nothing was created"
    end

    case GenServer.start(__MODULE__, [guard: guard, reservation: ref] ++ opts, name: __MODULE__) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        raise "collector not started (#{inspect(reason)}); reservation #{inspect(ref)} stays " <>
                "unfulfilled and containment will fail closed on it"
    end
  end

  @doc "The enrolled collector, or a raise: a root may not be created without one."
  def current! do
    case Process.whereis(__MODULE__) do
      nil -> raise "no containment collector enrolled; roots must be created through one"
      pid -> pid
    end
  end

  @doc """
  Create a PARKED, ARMED, OWNED root. `creator` is the process the root belongs
  to (it exits with `:creator_gone` if that process dies before release);
  `body` runs after `:go`. Returns `{:ok, root}` or `{:error, reason}`; on any
  error the root (if one was spawned) is recorded, killed and joined or latched
  unresolved - nothing owned-but-unrecorded exists.
  """
  def acquire_root(collector, creator, body) when is_pid(creator) and is_function(body, 0),
    do: GenServer.call(collector, {:acquire_root, creator, body}, 5_000)

  @doc "Send `:go` to an owned, armed, unreleased root while still :open; refused otherwise."
  def release(collector, root) when is_pid(root),
    do: GenServer.call(collector, {:release, root}, 5_000)

  @doc "Every pid currently owned by provenance, roots first, then descendants in discovery order."
  def owned(collector), do: GenServer.call(collector, :owned, 5_000)

  @doc "Only the roots (armed or not), oldest first."
  def roots(collector), do: GenServer.call(collector, :roots, 5_000)

  @doc "The lifecycle phase."
  def phase(collector), do: GenServer.call(collector, :phase, 5_000)

  @impl true
  def init(opts) do
    session = :trace.session_create(@session_name, self(), [])
    guard = Keyword.fetch!(opts, :guard)
    reservation = Keyword.fetch!(opts, :reservation)

    # Controls only: arm a parked probe on this exact session and report it,
    # so the control can later prove THIS session was destroyed.
    case Keyword.get(opts, :session_probe) do
      nil ->
        :ok

      test when is_pid(test) ->
        probe = spawn(fn -> receive do: (:never -> :ok) end)
        1 = :trace.process(session, probe, true, [:procs])
        send(test, {:collector_session_probe, self(), probe})
    end

    fulfil =
      try do
        RouteGuard.fulfil_collector(guard, reservation, self())
      catch
        :exit, reason -> {:exit, reason}
      end

    case fulfil do
      :ok ->
        {:ok,
         %{
           phase: :open,
           session: session,
           # pid => %{kind: :root | :descendant, armed: boolean, released: boolean}
           owned: %{},
           order: [],
           unresolved: [],
           unresolved_acquisitions: [],
           deadline: nil,
           contain_override: Keyword.get(opts, :contain_override),
           after_first_join: Keyword.get(opts, :after_first_join),
           answer_after_deadline: Keyword.get(opts, :answer_after_deadline, false),
           arm_override: Keyword.get(opts, :arm_override),
           join_override: Keyword.get(opts, :join_override),
           test: Keyword.get(opts, :test)
         }}

      {:exit, reason} ->
        # The enrolment call itself failed (guard dead, timeout): the acquired
        # session is destroyed HERE, explicitly, before init gives up.
        true = :trace.session_destroy(session)
        {:stop, {:enrollment_exit, reason}}

      other ->
        true = :trace.session_destroy(session)
        {:stop, {:enrollment_refused, other}}
    end
  end

  @impl true
  def terminate(_reason, %{session: session}) do
    _ = :trace.session_destroy(session)
    :ok
  end

  # ---- acquisition (only while :open) ----

  @impl true
  def handle_call({:acquire_root, creator, body}, _from, %{phase: :open} = state) do
    root = spawn(fn -> parked(creator, body) end)
    # RECORDED BEFORE THE FALLIBLE ARM (B3): whatever happens next, this root is
    # owned and accounted for.
    state = own(state, root, :root, armed: false)

    arm =
      case state.arm_override do
        nil ->
          try do
            {:ok, :trace.process(state.session, root, true, [:procs, :set_on_spawn])}
          rescue
            ArgumentError -> {:error, :badarg}
          end

        override ->
          override
      end

    case arm do
      {:ok, 1} ->
        {:reply, {:ok, root}, put_in(state.owned[root].armed, true)}

      other ->
        # Never handed out. Still parked (no :go), so it created nothing; join it
        # now. A joined unarmed root stays recorded as :no_trace; an unjoined one
        # latches the acquisition unresolved.
        ref = Process.monitor(root)
        Process.exit(root, :kill)

        joined =
          case state.join_override do
            nil ->
              receive do
                {:DOWN, ^ref, :process, ^root, _} -> :joined
              after
                1_000 -> :unjoined
              end

            override ->
              # Seam: the kill above was real; only the recorded OUTCOME is
              # replaced, so no impossible process is needed.
              receive do
                {:DOWN, ^ref, :process, ^root, _} -> :ok
              after
                1_000 -> :ok
              end

              override
          end

        state =
          case joined do
            :joined -> state
            :unjoined -> %{state | unresolved_acquisitions: [root | state.unresolved_acquisitions]}
          end

        {:reply, {:error, {:arm_failed, other, joined}}, state}
    end
  end

  def handle_call({:acquire_root, _creator, _body}, _from, state),
    do: {:reply, {:error, {:acquisition_closed, state.phase}}, state}

  def handle_call({:release, root}, _from, %{phase: :open} = state) do
    case state.owned[root] do
      %{kind: :root, armed: true, released: false} ->
        send(root, :go)
        {:reply, :ok, put_in(state.owned[root].released, true)}

      %{kind: :root, armed: false} ->
        {:reply, {:error, :root_not_armed}, state}

      %{kind: :root, released: true} ->
        {:reply, {:error, :already_released}, state}

      _ ->
        {:reply, {:error, :not_an_owned_root}, state}
    end
  end

  def handle_call({:release, _root}, _from, state),
    do: {:reply, {:error, {:acquisition_closed, state.phase}}, state}

  def handle_call(:owned, _from, state), do: {:reply, Enum.reverse(state.order), state}

  def handle_call(:roots, _from, state),
    do: {:reply, for(p <- Enum.reverse(state.order), state.owned[p].kind == :root, do: p), state}

  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}

  # ---- containment ----

  def handle_call({:contain!, _deadline}, _from, %{phase: phase} = state) when phase != :open,
    do: {:reply, {:error, {:phase, phase}}, state}

  def handle_call({:contain!, deadline}, _from, %{contain_override: answer} = state)
      when not is_nil(answer) do
    # Inert seam: report without working. The phase still closes so the rest of
    # the protocol (destroy refusal, no post-seal :go) is exercised truthfully.
    {:reply, answer, %{state | phase: :failed, deadline: deadline}}
  end

  def handle_call({:contain!, deadline}, _from, %{answer_after_deadline: true} = state) do
    # Inert seam for the shared-deadline control: answer :ok only once the
    # guard's own deadline has passed, so the NEXT drain must be refused as
    # expired. This is the bound under test, not a synchronisation sleep.
    wait = max(deadline - now_ms(), 0) + 1

    receive do
    after
      wait -> :ok
    end

    {:reply, :ok, %{state | phase: :sealed, deadline: deadline}}
  end

  def handle_call({:contain!, deadline}, _from, state) do
    # :closing FIRST, then the snapshot: nothing acquired after this instant.
    state = %{state | phase: :closing, deadline: deadline}
    worklist = Enum.reverse(state.order)

    result =
      case fixed_point(worklist, %{}, state, deadline, :first) do
        {:ok, %{unresolved_acquisitions: [_ | _] = roots} = state} ->
          {:error, {:unresolved_acquisition, roots}, state}

        {:ok, state} ->
          if now_ms() > deadline,
            do: {:error, :deadline_expired_at_seal, state},
            else: {:ok, state}

        error ->
          error
      end

    case result do
      {:ok, state} ->
        if state.test,
          do: send(state.test, {:collector_contained, self(), System.monotonic_time(:microsecond)})

        {:reply, :ok, %{state | phase: :sealed}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, %{state | phase: :failed}}
    end
  end

  def handle_call({:destroy, deadline}, _from, %{phase: :sealed} = state) do
    if now_ms() > deadline do
      {:reply, {:error, :deadline_expired}, state}
    else
      case :trace.session_destroy(state.session) do
        true ->
          if state.test,
            do:
              send(state.test, {:collector_destroyed, self(), System.monotonic_time(:microsecond)})

          {:reply, :ok, state}

        false ->
          {:reply, {:error, :session_already_destroyed}, state}
      end
    end
  end

  def handle_call({:destroy, _deadline}, _from, state),
    do: {:reply, {:error, {:phase, state.phase}}, state}

  # Events arriving between rows' actions are folded into ownership here, with
  # the same provenance rule contain! applies.
  @impl true
  def handle_info({:trace, _, _, _, _} = event, state), do: {:noreply, absorb(state, event)}
  def handle_info({:trace, _, _, _}, state), do: {:noreply, state}
  def handle_info({:trace_delivered, _, _}, state), do: {:noreply, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  # ---- the parked root ----

  defp parked(creator, body) do
    ref = Process.monitor(creator)

    receive do
      :go ->
        Process.demonitor(ref, [:flush])
        body.()

      {:DOWN, ^ref, :process, ^creator, _} ->
        exit(:creator_gone)
    end
  end

  # ---- the fixed point ----

  defp fixed_point([], _done, state, _deadline, _seam) do
    case state.unresolved do
      [] -> {:ok, state}
      events -> {:error, {:unknown_provenance, events}, state}
    end
  end

  defp fixed_point([pid | rest], done, state, deadline, seam) do
    if Map.has_key?(done, pid) do
      fixed_point(rest, done, state, deadline, seam)
    else
      with {:ok, state} <- kill_join(pid, state, deadline),
           state <- run_seam(seam, state),
           {:ok, state} <- flush(pid, state, deadline) do
        done = Map.put(done, pid, true)
        # Descendants learned while waiting are appended; already-done pids are
        # skipped above, so the loop terminates when nothing new appears.
        newly =
          for p <- Enum.reverse(state.order),
              not Map.has_key?(done, p),
              p not in rest,
              do: p

        fixed_point(rest ++ newly, done, state, deadline, :later)
      else
        {:error, reason, state} -> {:error, reason, state}
      end
    end
  end

  # CC7 seam: runs exactly once, after the FIRST pid's DOWN and before its
  # flush, so a control can make a surviving descendant create work DURING
  # containment. Inert (nil) in ordinary rows.
  defp run_seam(:first, %{after_first_join: fun} = state) when is_function(fun, 0) do
    fun.()
    state
  end

  defp run_seam(_, state), do: state

  defp kill_join(pid, state, deadline) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    await(state, deadline, fn
      {:DOWN, ^ref, :process, ^pid, _} -> :done
      _ -> :skip
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:timeout, state} -> {:error, {:unjoined, pid}, state}
    end
  end

  # Only TRACED pids are flushed: armed roots and their descendants. An unarmed
  # root is :no_trace - it was never traced, so a delivery barrier would prove
  # nothing about it; its kill/join above is its whole containment.
  defp flush(pid, state, deadline) do
    case state.owned[pid] do
      %{kind: :root, armed: false} ->
        {:ok, state}

      _ ->
        ref = :trace.delivered(state.session, pid)

        await(state, deadline, fn
          {:trace_delivered, ^pid, ^ref} -> :done
          _ -> :skip
        end)
        |> case do
          {:ok, state} -> {:ok, state}
          {:timeout, state} -> {:error, {:unflushed, pid}, state}
        end
    end
  end

  # Selective wait for one message. Trace events are absorbed; calls that
  # arrive meanwhile are ANSWERED with the phase (F1: no swallowed
  # acquisition). Anything else that is neither trace, DOWN, delivery nor call
  # is dropped - none such is expected in this mailbox. Bounded by the absolute
  # deadline only.
  defp await(state, deadline, matcher) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:timeout, state}
    else
      receive do
        {:trace, _, _, _, _} = event ->
          case matcher.(event) do
            :done -> {:ok, state}
            :skip -> await(absorb(state, event), deadline, matcher)
          end

        {:"$gen_call", from, request} ->
          GenServer.reply(from, answer_while_containing(request, state))
          await(state, deadline, matcher)

        msg ->
          case matcher.(msg) do
            :done -> {:ok, state}
            :skip -> await(state, deadline, matcher)
          end
      after
        remaining -> {:timeout, state}
      end
    end
  end

  defp answer_while_containing(:owned, state), do: Enum.reverse(state.order)

  defp answer_while_containing(:roots, state),
    do: for(p <- Enum.reverse(state.order), state.owned[p].kind == :root, do: p)

  defp answer_while_containing(:phase, state), do: state.phase
  defp answer_while_containing(_request, state), do: {:error, {:acquisition_closed, state.phase}}

  # ---- provenance ----

  # `spawn` is emitted by the parent, `spawned` by the child; either proves the
  # same edge. Extend ownership only when the parent is owned; otherwise park
  # the event and retry it whenever ownership grows.
  defp absorb(state, {:trace, parent, :spawn, child, _mfa}), do: learn(state, parent, child)
  defp absorb(state, {:trace, child, :spawned, parent, _mfa}), do: learn(state, parent, child)
  defp absorb(state, {:trace, _, _, _, _}), do: state

  defp learn(state, parent, child) do
    if Map.has_key?(state.owned, parent) do
      state |> own(child, :descendant, armed: true) |> resolve()
    else
      %{state | unresolved: state.unresolved ++ [{parent, child}]}
    end
  end

  defp resolve(state) do
    {ready, still} =
      Enum.split_with(state.unresolved, fn {p, _} -> Map.has_key?(state.owned, p) end)

    case ready do
      [] ->
        state

      _ ->
        Enum.reduce(ready, %{state | unresolved: still}, fn {_, c}, s ->
          own(s, c, :descendant, armed: true)
        end)
        |> resolve()
    end
  end

  defp own(state, pid, kind, armed: armed) do
    if Map.has_key?(state.owned, pid) do
      state
    else
      %{
        state
        | owned:
            Map.put(state.owned, pid, %{kind: kind, armed: armed, released: kind == :descendant}),
          order: [pid | state.order]
      }
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
