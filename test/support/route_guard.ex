defmodule AiPair.Test.RouteGuard do
  @moduledoc """
  Fail-closed default-route boundary, plus the owned-lifecycle helpers the
  pane-restore isolation rows need.

  Ported to Orrisd main for R04 slice S11 from the reviewed lane file
  `test/support/route_guard.ex` at `ff8650eda777240f60866b1930837b2d4b3263bf`.
  The decision logic is the lane text; only the source citations below were
  re-derived against main, where `AiPair.Tmux` gained the S4 census and
  session-option calls.

  ## Why owning the registered name is the boundary

  Every tmux operation is `GenServer.call(server, ..)` with `server \\\\ AiPair.Tmux`
  (`tmux.ex:132` list_panes, `:158` capture_pane, `:196` send_keys, `:205`
  set_buffer, `:220` paste_buffer, `:239` delete_buffer, `:246` display_message,
  and the S4 additions `:292` observe_panes, `:331` show_options, `:349`
  set_option, `:375` set_option_if_absent). The only `System.cmd` site,
  `run_tmux/2` (`tmux.ex:543`), executes INSIDE that GenServer, and
  `prepend_socket/2` (`tmux.ex:571-572`) emits no `-L` when `socket_name` is nil
  — the user's REAL server. The state machine's defaults address the registered
  atom by name (`state_machine.ex:246-247` selecting `default_capture/1` /
  `default_paste/2`; `:847-858`), the application starts the adapter with `[]`
  (`application.ex:32`, so `socket_name` is nil),
  `PaneSupervisor.start_pane/2` (`pane_supervisor.ex:37-57`) forwards opts
  verbatim into the child spec, and `IPC.Server.attach_pane/3`
  (`ipc/server.ex:387-391`) supplies no callbacks at all. Holding the name
  therefore refuses a default route BEFORE any external command can exist.

  TOTALITY. The refusal is a catch-all `handle_call/3` clause placed after the
  four guard-protocol clauses (`:violations`, `{:own, _}`,
  `{:fulfil_collector, _, _}`, `:registry`, `:finalize`), so it answers EVERY
  request shape the real adapter answers — all eleven of
  `tmux.ex:406-450` — including any added later. Nothing is enumerated, so a new
  adapter call cannot silently escape the boundary; `route_guard_test.exs`
  asserts that every one of main's eleven shapes is refused and recorded, and
  that the set the guard refuses is exactly the set the adapter serves.

  An ACTIVE rejector is required rather than mere absence: `capture_call/3`
  (`tmux.ex:175-180`) catches `:exit {:timeout, ..}` and returns a synthetic
  error, so a merely terminated adapter would let a dropped callback pass
  unnoticed.

  ## Containment before restoration

  Reporting a cleanup failure is NOT containment. An earlier lane revision
  restored the real adapter from an unconditional exit hook even after an owned
  child failed to stop, and killed whichever process happened to hold the name —
  including the application's own child on an installation failure. Both are
  fixed here:

    * the adapter is restored ONLY after every owned child is positively
      terminated and joined; if containment is unresolved the rejecting guard is
      deliberately LEFT RUNNING so any leaked child still hits a refusing
      target, and the failure is raised;
    * destructive cleanup is bound to the pid this module started. A registered
      name is reusable and is never accepted as proof of ownership.

  ## Known limits, stated rather than implied

    * This guards the `AiPair.Tmux` funnel only. `cli/consult.ex` and
      `calibrator.ex` run `tmux` directly, and `mix ai_pair.smoke` shells out;
      `tmux.ex`'s moduledoc claims the funnel is total, and it is not.
    * The guard is row-scoped, not an application-start sandbox.
    * `drain_pane!/2` finishes with a SYNCHRONOUS supervisor round-trip, not a
      stability window. `DynamicSupervisor` routes `start_child`,
      `terminate_child`, `which_children` and `count_children` through the same
      GenServer mailbox, so the final lookup is ordered after any `start_child`
      already queued. `terminate_child` also deletes the child and `:transient`
      restart applies only to a child's own exit, so our own termination cannot
      produce a replacement. An earlier revision polled three times at 5ms and
      called that containment; a replacement pending behind a busy supervisor
      for longer than 15ms would have registered after the guard stopped, and no
      amount of extra sleeping fixes a timing guess.
    * An unresolved containment leaves the rejector alive AND retains its
      registry: a LATE `own_pane/1` / `own_process/1` is answered
      `{:error, :containment_failed}` and default-routed calls keep being refused
      and recorded. Containment failure is still terminal for the file by design
      (the surviving guard holds the name); do not continue a file after it.
    * Admission closes when `contain!/1` snapshots the registry. A late
      registration that carries an acquired resource is refused AND marks the
      pass failed, so `restore!/1` withholds; a refused reservation carries
      nothing and marks nothing.
    * The containment deadline bounds the guard's own steps (collector calls,
      pane supervisor requests, DOWN waits, plain-process stops), all issued
      from the draining process itself with no worker Task. It cannot recall a
      `{:terminate_child, pid}` request already dispatched inside the
      supervisor: at the deadline the request is reported UNRESOLVED (never
      cancelled), the entry fails, and the supervisor may still complete it.
    * Restoration is decided by the guard's `:finalize` handshake and its
      pinned DOWN, not by the map `restore!/1` read first; the registry is
      released only after that DOWN.
    * Under the guard a default-routed capture returns status `-2`, which
      `classify_error/1` (`tmux.ex:815-823`) reads as `"nonzero_exit"`, NOT
      `"pane_not_found"` — so guarded rows take a different product path than
      rows that reached real tmux. `capture_pane/3` then leaves the raw map
      (`normalize_capture_error/1`, `tmux.ex:825-831`) rather than
      `{:error, :pane_gone}`.
  """

  use GenServer

  @name AiPair.Tmux
  @supervisor AiPair.Supervisor

  # Default budget for ONE absolute containment deadline per guard (F3,
  # m_1789249509): computed once in contain!/1 and threaded through every
  # blocking step; never renewed per entry. Overridable per install!/1 with
  # `containment_budget_ms:` (the deadline controls use 0 and 300).
  @containment_budget_ms 10_000

  # ===== installation =====

  @doc """
  Real collaborators. Injectable so a control can exercise the installation and
  restoration WIRING against an inert recorder instead of the live supervisor —
  a control that only called a decision helper could not catch `restore!/1`
  ignoring that decision.
  """
  @spec real_effects() :: map()
  def real_effects do
    %{
      terminate_child: &Supervisor.terminate_child/2,
      restart_child: &Supervisor.restart_child/2
    }
  end

  @doc """
  Install the boundary BEFORE any child starts. Returns the guard pid.

  Registers two exit callbacks. ExUnit runs callbacks LIFO and executes every
  one even when an earlier callback raises (`ExUnit.OnExitHandler`
  `run/2:56`, `exec_on_exit_callbacks/3:72-85`), so the containment pass
  registered second runs FIRST, and the restoration pass registered first runs
  LAST and always runs.
  """
  @spec install!(keyword()) :: pid()
  def install!(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    effects = Keyword.get(opts, :effects, real_effects())
    budget_ms = Keyword.get(opts, :containment_budget_ms, @containment_budget_ms)

    # Unlinked on purpose: this outlives the test process so the exit callbacks
    # can read it. An ExUnit-supervised child would already be dead, because the
    # test supervisor is terminated BEFORE on_exit callbacks run.
    #
    # `closing` is set irreversibly by contain!/1 in the same Agent transaction
    # that snapshots `owned`, so no registration can land after the snapshot and
    # escape the pass (F1). `failed` marks a containment or restoration failure;
    # the registry is then RETAINED with the rejecting guard so late own_*
    # requests get a refusal rather than a crash of the boundary (F4).
    {:ok, owner} =
      Agent.start(fn ->
        %{
          guard: nil,
          contained: false,
          closing: false,
          failed: false,
          finalized: false,
          late_unaccounted: [],
          owned: [],
          name: name,
          effects: effects,
          budget_ms: budget_ms
        }
      end)

    # Controls pass false and drive contain!/1 and restore!/1 themselves, so the
    # row can assert on the recorder instead of waiting for teardown.
    if Keyword.get(opts, :register_teardown, true) do
      ExUnit.Callbacks.on_exit(fn -> restore!(owner) end)
    end

    case effects.terminate_child.(@supervisor, name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> raise "terminating #{inspect(name)} failed: #{inspect(other)}"
    end

    # UNLINKED on purpose, like the owner above. A LINKED guard receives the test
    # process's exit signal on a FAILING row and can die before teardown decides
    # whether containment succeeded — destroying the very guarantee below, that
    # the rejecting boundary stays up while owned children are unaccounted for.
    {:ok, guard} =
      GenServer.start(
        __MODULE__,
        [
          owner: self(),
          registry: owner,
          finalize_mode: Keyword.get(opts, :finalize_mode, :stop)
        ],
        name: name
      )

    Agent.update(owner, &%{&1 | guard: guard})

    if Keyword.get(opts, :register_teardown, true) do
      ExUnit.Callbacks.on_exit(fn -> contain!(owner) end)
    end

    guard
  end

  @doc false
  @spec owner_of(pid()) :: pid()
  def owner_of(guard), do: GenServer.call(guard, :registry)

  # Registration is routed THROUGH the guard on purpose. An earlier draft probed
  # the supplied handle with `Agent.get/3` to decide whether it was the registry
  # or the guard; against the guard that probe is an unmatched `GenServer.call`,
  # which the catch-all clause below treats as a forbidden default route. It
  # would have recorded a bogus violation and corrupted the very evidence these
  # rows assert on.

  @doc "Record a pane this row started, so teardown drains it BEFORE routing is restored."
  @spec own_pane(pid(), String.t()) :: :ok
  def own_pane(guard, pane_id) when is_pid(guard) and is_binary(pane_id) do
    GenServer.call(guard, {:own, {:pane, pane_id}})
  end

  @doc """
  Same, resolving the guard through its registered name.

  Defined adjacent to `own_pane/2` on purpose: Elixir warns when clauses sharing
  a name are separated by other definitions, and `bin/verify:64` runs
  `mix test --warnings-as-errors`.

  Most rows do not carry the guard in their context, and root requires every
  named row preserved, so demanding the two-arity form everywhere would mean
  rewriting dozens of test heads. `install!/0` runs in `setup`, so the name is
  bound before any row body executes.

  LIMIT, stated rather than implied: this cannot tell our guard apart from the
  real adapter holding the same name. It raises when NOTHING holds the name,
  which catches the common mistake of registering ownership without installing
  the boundary; it cannot catch a row that never installed one while the
  application's own child is live.
  """
  @spec own_pane(String.t()) :: :ok
  def own_pane(pane_id) when is_binary(pane_id) do
    case Process.whereis(@name) do
      nil -> raise "no route guard installed; call install!/0 in setup before owning a pane"
      guard -> own_pane(guard, pane_id)
    end
  end

  @doc """
  Record a raw process this row started — a `PaneIntentFaultFs` Agent
  (`pane_intent_fault_fs.ex:133` starts a linked Agent, not an
  ExUnit-supervised child), a store, or a Task.
  """
  @spec own_process(pid(), pid()) :: :ok
  def own_process(guard, pid) when is_pid(guard) and is_pid(pid) do
    GenServer.call(guard, {:own, {:process, pid}})
  end

  @doc """
  Same, resolving the guard through its registered name. Adjacent to
  `own_process/2` so the clause-grouping warning cannot fire.

  Only for processes `GenServer.stop/3` can stop — an `Agent` qualifies, a
  `Task` does NOT, and a Task registered here would fail its join rather than
  be cleaned up.
  """
  @spec own_process(pid()) :: :ok
  def own_process(pid) when is_pid(pid) do
    case Process.whereis(@name) do
      nil -> raise "no route guard installed; call install!/0 in setup before owning a process"
      guard -> own_process(guard, pid)
    end
  end

  @doc """
  Record a CONTAINMENT COLLECTOR: a test-owned GenServer that has established
  spawn PROVENANCE over the fixture's producer roots (a dedicated dynamic trace
  session with `procs` + `set_on_spawn` armed on each parked root BEFORE it may
  create anything) and can, on request, stop and join every discovered
  descendant to a fixed point. Enrol it BEFORE any root exists.

  Containment order (m_1789247933): collectors are drained FIRST in
  `contain!/1`, irrespective of enrolment order, under ONE absolute deadline;
  only then are panes and plain processes drained. The collector answers
  `{:contain!, deadline}` with `:ok` or an error; an error, a timeout, an exit
  or a dead collector is a containment FAILURE, so `contained` stays false and
  `restore!/1` withholds real routing. On success the guard requires the
  collector to destroy its session (`{:destroy, deadline}` -> `:ok` only when
  `:trace.session_destroy/1` returned `true`) and then stops and joins the
  collector, BEFORE restoration.

  Coverage claim, scoped: a collector covers the roots it armed and their
  spawn-descendants. Processes with other ancestors (a pane child started by
  the real `PaneSupervisor`, full-Application children, IPC handlers) are not
  covered by it; pane children stay with `own_pane/1`. Adjacent clauses.

  ACQUISITION PROTOCOL (F2, m_1789249509): cleanup responsibility is recorded
  BEFORE the collector or its trace session can exist. The starter first calls
  `reserve_collector/2` with a fresh ref, which records
  `{:collector_reservation, ref}`; only then does it start the collector, whose
  `init` fulfils the reservation with `fulfil_collector/3` (replacing it with
  `{:collector, pid}`) or, if that fails, destroys its own session and stops.
  A reservation still unfulfilled when `contain!/1` runs is an UNKNOWN
  acquisition and fails containment - it never reads as "nothing to contain".
  `own_collector/2` remains for a collector that is already fully owned by the
  caller in some other way; the collector module in this suite uses the
  reservation path only.
  """
  @spec own_collector(pid(), pid()) :: :ok | {:error, term()}
  def own_collector(guard, pid) when is_pid(guard) and is_pid(pid) do
    GenServer.call(guard, {:own, {:collector, pid}})
  end

  @spec own_collector(pid()) :: :ok | {:error, term()}
  def own_collector(pid) when is_pid(pid) do
    case Process.whereis(@name) do
      nil -> raise "no route guard installed; call install!/0 in setup before owning a collector"
      guard -> own_collector(guard, pid)
    end
  end

  @doc "Record cleanup responsibility for a collector that does not exist yet (F2)."
  @spec reserve_collector(pid(), reference()) :: :ok | {:error, term()}
  def reserve_collector(guard, ref) when is_pid(guard) and is_reference(ref) do
    GenServer.call(guard, {:own, {:collector_reservation, ref}})
  end

  @doc "Replace a reservation with the started collector's pid; refused if no such reservation is recorded."
  @spec fulfil_collector(pid(), reference(), pid()) :: :ok | {:error, term()}
  def fulfil_collector(guard, ref, pid) when is_pid(guard) and is_reference(ref) and is_pid(pid) do
    GenServer.call(guard, {:fulfil_collector, ref, pid})
  end

  # ===== teardown: containment first, restoration only on proof =====

  # PUBLIC so a control can drive the same function install!/1 registers. A
  # control that called a separate decision helper could not catch restore!/1
  # ignoring the decision; driving the real callback can.
  #
  # ONE ABSOLUTE DEADLINE (F3): computed once from the installed budget and
  # threaded through EVERY blocking step below - collector calls, the collector's
  # stop, pane supervisor calls, pane DOWN waits, plain-process stop AND its DOWN
  # wait. Each step recomputes the positive remainder immediately before it
  # blocks and refuses to start when nothing remains; no step clamps an expired
  # deadline into a fresh allowance and no entry renews it.
  @doc false
  def contain!(owner) do
    # CLOSE ADMISSION AND SNAPSHOT IN ONE TRANSACTION (F1): after this, the
    # guard refuses every {:own, _} with {:error, :containment_closed}, so no
    # registration can land behind the snapshot and escape the pass. A second
    # contain! is refused rather than re-run over a stale view.
    {owned, budget_ms} =
      case Agent.get_and_update(owner, fn s ->
             if s.closing,
               do: {:already_closing, s},
               else: {{s.owned, s.budget_ms}, %{s | closing: true}}
           end) do
        :already_closing -> raise "containment already ran for this guard; refusing a second pass"
        snapshot -> snapshot
      end

    deadline = System.monotonic_time(:millisecond) + budget_ms

    # COLLECTORS FIRST, regardless of enrolment order: producers (Boot, its
    # workers, the coordinator and its effect workers) must be stopped and
    # joined before any pane or plain process is drained, or a still-live
    # producer can submit new target work into a pane we are about to declare
    # drained. Then panes/processes, most recently owned first as before. An
    # UNFULFILLED collector reservation is an unknown acquisition: it is a
    # failure entry, never an empty set (F2).
    collectors = for {:collector, _} = e <- owned, do: e
    reservations = for {:collector_reservation, _} = e <- owned, do: e

    others =
      for e <- owned,
          not match?({:collector, _}, e),
          not match?({:collector_reservation, _}, e),
          do: e

    seeded =
      for r <- reservations,
          do: {r, "collector acquisition outcome UNKNOWN (reservation never fulfilled)"}

    failures =
      Enum.reduce(collectors ++ Enum.reverse(others), seeded, fn entry, acc ->
        try do
          drain_entry!(entry, deadline)
          acc
        rescue
          error -> [{entry, Exception.message(error)} | acc]
        catch
          :exit, reason -> [{entry, "exit " <> inspect(reason)} | acc]
        end
      end)

    # A pass that ran past its own deadline is not a pass, even over an empty
    # set (F3): the budget is part of the guarantee, not a per-step courtesy.
    failures =
      if System.monotonic_time(:millisecond) >= deadline,
        do: [{:deadline, "containment pass reached its deadline; containment unproven"} | failures],
        else: failures

    if failures == [] do
      Agent.update(owner, &%{&1 | contained: true})
    else
      Agent.update(owner, &%{&1 | failed: true})
      raise "owned children were not contained: #{inspect(Enum.reverse(failures))}"
    end
  end

  defp drain_entry!({:pane, pane_id}, deadline), do: drain_pane_by!(pane_id, deadline)
  defp drain_entry!({:process, pid}, deadline), do: stop_and_join_by!(pid, deadline)
  defp drain_entry!({:collector, pid}, deadline), do: drain_collector!(pid, deadline)

  # Positive time left before `deadline`, or a raise naming the step that was
  # refused. Never clamps: an expired deadline refuses the step outright.
  defp remaining!(deadline, step) do
    left = deadline - System.monotonic_time(:millisecond)

    if left > 0,
      do: left,
      else: raise("containment deadline expired before #{step}; containment unproven")
  end

  # The collector performs the fixed-point stop/join/flush over the producers it
  # has provenance for, inside its own handle_call (it must consume its own
  # trace and monitor messages there). Any error, timeout or exit here is a
  # containment failure. On :ok the session is destroyed (boolean checked) and
  # the collector itself is stopped and joined BEFORE restoration can happen.
  # Every one of these three steps is refused once the shared deadline passed.
  defp drain_collector!(pid, deadline) do
    unless Process.alive?(pid) do
      raise "containment collector #{inspect(pid)} is dead; producer provenance is UNKNOWN"
    end

    case GenServer.call(pid, {:contain!, deadline}, remaining!(deadline, "collector containment")) do
      :ok -> :ok
      {:error, reason} -> raise "producer containment failed: #{inspect(reason)}"
      other -> raise "producer containment answered #{inspect(other)}; treated as failure"
    end

    case GenServer.call(pid, {:destroy, deadline}, remaining!(deadline, "trace session destroy")) do
      :ok -> :ok
      other -> raise "trace session not destroyed: #{inspect(other)}"
    end

    stop_and_join_by!(pid, deadline)
  end

  @doc false
  def restore!(owner) do
    state = Agent.get(owner, & &1)

    try do
      cond do
        # CHECKED FIRST, and that order is the whole point. `contained` can only
        # become true inside contain!/1, which install!/1 registers AFTER storing
        # the guard pid — so `contained == true` implies a pid, and testing
        # containment first made this branch UNREACHABLE. The effect was that
        # every install! error path (a raising terminate_child, or a MatchError
        # when the name is already held) fell into the containment raise and left
        # the application's adapter TERMINATED for the remainder of the suite:
        # the precise fail-open half the five deleted copies existed to prevent.
        # Nothing of ours holds the name here and no child was ever registered,
        # so there is nothing to contain and the adapter must come back.
        is_nil(state.guard) ->
          restart_app_adapter!(state)

        not state.contained ->
          # DELIBERATELY leave the rejecting guard running. Restoring real
          # routing now would hand any leaked child the user's actual tmux
          # server, which is exactly what this module exists to prevent. NOTE
          # this is terminal for the file: the surviving guard holds the name,
          # so every later install!/1 fails loudly rather than silently
          # reopening the route. The registry is RETAINED with it (F4): the
          # surviving guard consults it on every late own_* request and answers
          # a refusal; stopping it here would turn the next such request into a
          # crash of the very boundary this branch keeps.
          Agent.update(owner, &%{&1 | failed: true})
          raise "containment unresolved; default routing deliberately NOT restored"

        # contained:true was earned, but a registration carrying an acquired
        # resource arrived AFTER the snapshot (F1, m_1789249820): that resource
        # is unaccounted for and the earlier decision does not stand.
        state.failed ->
          raise "containment unresolved; late acquisition after the snapshot: " <>
                  "#{inspect(state.late_unaccounted)}; default routing deliberately NOT restored"

        true ->
          finalize_and_restore!(owner, state)
      end
    after
      # The registry is stopped only where the guard is provably gone: the
      # no-guard branch here, and inside finalize_and_restore!/2 only after the
      # guard's pinned DOWN was observed. On every failure branch registry and
      # rejector survive together (F4, m_1789247933 point 4).
      if is_nil(state.guard), do: Agent.stop(owner)
    end
  end

  # Budget for the finalization handshake and the guard's DOWN (B1). Separate
  # from the containment budget: containment has already succeeded here.
  @finalize_budget_ms 2_000

  # THE FINAL DECISION IS MADE ON THE GUARD'S MAILBOX, NOT FROM AN EARLIER READ
  # (B1, m_1789250979). The map read at the top of restore!/1 can be stale: a
  # late own_* carrying an acquired resource may be acknowledged (and mark the
  # registry failed) between that read and the stop. So restoration proceeds
  # only through `:finalize`, which the guard serialises with every ownership
  # request it has acknowledged: inside its handle_call it re-reads and updates
  # the registry in ONE transaction and either refuses (late unaccounted work,
  # not contained) and stays alive, or marks the registry finalized and stops
  # itself in the same step. This function then waits for THAT pid's DOWN and
  # only afterwards runs the restart effect and stops the registry. A finalize
  # exit/timeout, a refusal, or a missing DOWN leaves rejector and registry in
  # place, records failed:true and raises - no restart on any of those paths.
  # No further unlocked read is consulted after the handshake.
  defp finalize_and_restore!(owner, %{guard: guard, name: name} = state) do
    deadline = System.monotonic_time(:millisecond) + @finalize_budget_ms

    case Process.whereis(name) do
      ^guard ->
        :ok

      nil ->
        Agent.update(owner, &%{&1 | failed: true})

        raise "guard #{inspect(guard)} is gone before finalization; restoration unproven, registry retained"

      other ->
        # Ownership is the pid we started, never the registered name. Some other
        # process holds it; killing it would be an arbitrary destructive act.
        Agent.update(owner, &%{&1 | failed: true})
        raise "#{inspect(other)} holds #{inspect(name)}, not our guard #{inspect(guard)}"
    end

    ref = Process.monitor(guard)

    decision =
      try do
        GenServer.call(guard, :finalize, remaining!(deadline, "guard finalization"))
      catch
        :exit, reason -> {:error, {:finalize_exit, reason}}
      end

    case decision do
      :ok ->
        receive do
          {:DOWN, ^ref, :process, ^guard, _} -> :ok
        after
          remaining!(deadline, "guard DOWN after finalization") ->
            Agent.update(owner, &%{&1 | failed: true})

            raise "guard #{inspect(guard)} acknowledged finalization but did not stop; " <>
                    "restoration withheld, registry retained"
        end

        # Only now is the boundary provably gone: restore, then release the
        # registry.
        restart_app_adapter!(state)
        Agent.stop(owner)

      {:error, reason} ->
        Agent.update(owner, &%{&1 | failed: true})

        raise "containment unresolved at finalization: #{inspect(reason)}; " <>
                "default routing deliberately NOT restored, rejector and registry retained"
    end
  end

  defp restart_app_adapter!(%{effects: effects, name: name}) do
    case effects.restart_child.(@supervisor, name) do
      {:ok, _} -> :ok
      {:ok, _, _} -> :ok
      {:error, :running} -> :ok
      {:error, :not_found} -> :ok
      other -> raise "restoring #{inspect(@name)} failed: #{inspect(other)}"
    end
  end

  # ===== owned-child draining =====

  @doc """
  Terminate and JOIN a pane child, then require the name to stay free.

  `stop_pane/1` looks the pane up again internally, so monitoring a pid that
  already died would deliver an immediate `:noproc` DOWN and let a caller claim
  a join it never performed while a different child was terminated. This loops
  on identity instead, and finishes with a synchronous supervisor round-trip
  (see `confirm_free!/2`) so the final lookup is ordered after any queued
  `start_child` — an empty Registry lookup alone cannot show that.
  """
  @spec drain_pane!(String.t(), pos_integer()) :: :ok
  def drain_pane!(pane_id, deadline_ms \\ 2_000) do
    drain_pane_by!(pane_id, System.monotonic_time(:millisecond) + deadline_ms)
  end

  # Absolute-deadline form used by contain!/1 (F3): the supervisor round-trips
  # and the DOWN wait are all bounded by the SAME instant; nothing here gets a
  # fresh relative allowance.
  @doc false
  @spec drain_pane_by!(String.t(), integer()) :: :ok
  def drain_pane_by!(pane_id, deadline), do: drain_pane_loop!(pane_id, deadline)

  # NO WORKER PROCESSES (B2, m_1789250979): the supervisor requests are issued
  # directly, deadline-bounded, from the draining process. `stop_pane/1` is
  # `DynamicSupervisor.terminate_child(sup, pid)` (pane_supervisor.ex:93-97),
  # which is `GenServer.call(sup, {:terminate_child, pid}, :infinity)`
  # (dynamic_supervisor.ex:479-480, :1114-1115 as pinned by the review); the
  # barrier below is `count_children`'s `GenServer.call(sup, :count_children,
  # :infinity)` (:536-537) whose reply is the keyword list BEFORE
  # `:maps.from_list`. Issuing those requests ourselves with the positive
  # remaining time keeps the same supervisor semantics with no Task to abandon.
  # A timed-out request means the dispatched operation is UNRESOLVED - it may
  # still complete inside the supervisor later - never that it was cancelled;
  # contain!/1 records the exit as this entry's failure.
  defp pane_supervisor!(pane_id) do
    case Process.whereis(AiPair.PaneSupervisor) do
      pid when is_pid(pid) -> pid
      nil -> raise "AiPair.PaneSupervisor is not running; pane #{pane_id} cannot be drained"
    end
  end

  defp drain_pane_loop!(pane_id, stop_at) do
    _ = remaining!(stop_at, "pane #{pane_id} lookup")

    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error ->
        confirm_free!(pane_id, stop_at)

      {:ok, pid} ->
        ref = Process.monitor(pid)
        sup = pane_supervisor!(pane_id)

        reply =
          try do
            GenServer.call(
              sup,
              {:terminate_child, pid},
              remaining!(stop_at, "pane #{pane_id} terminate_child")
            )
          catch
            :exit, {:timeout, _} ->
              raise "pane #{pane_id} terminate_child dispatched to #{inspect(sup)} but UNRESOLVED at the deadline " <>
                      "(not cancelled); containment unproven"
          end

        case reply do
          :ok -> :ok
          {:error, :not_found} -> :ok
          other -> raise "pane #{pane_id} terminate_child answered #{inspect(other)}"
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          remaining!(stop_at, "pane #{pane_id} child DOWN") ->
            raise "pane child #{inspect(pid)} for #{pane_id} did not terminate"
        end

        drain_pane_loop!(pane_id, stop_at)
    end
  end

  # A REAL barrier, not a stability sleep. DynamicSupervisor routes start_child,
  # terminate_child, which_children and count_children through the SAME GenServer
  # mailbox (dynamic_supervisor.ex:398, :480, :509, :537), so a synchronous
  # count_children returns only after any start_child already queued ahead of it
  # has been processed. An earlier revision polled the Registry three times at
  # 5ms and called that containment; a replacement pending behind a busy or
  # suspended supervisor for longer than 15ms would have registered after the
  # guard stopped, and no amount of extra sleeping fixes a timing guess.
  #
  # Structural companion: terminate_child DELETES the child
  # (dynamic_supervisor.ex:716), and :transient restart applies only to a child's
  # OWN exit (:1006), so our own termination cannot produce a replacement. A
  # replacement can therefore only come from a fresh start_child, which the
  # barrier above orders against.
  defp confirm_free!(pane_id, stop_at) do
    # The barrier is the same synchronous supervisor request count_children/1
    # makes, issued directly and bounded by the shared deadline; its reply is
    # validated as the pre-maps.from_list keyword list.
    sup = pane_supervisor!(pane_id)

    counts =
      try do
        GenServer.call(
          sup,
          :count_children,
          remaining!(stop_at, "pane #{pane_id} supervisor barrier")
        )
      catch
        :exit, {:timeout, _} ->
          raise "pane #{pane_id} supervisor barrier (count_children) UNRESOLVED at the deadline; " <>
                  "containment unproven"
      end

    unless is_list(counts) and Keyword.keyword?(counts) do
      raise "pane #{pane_id} supervisor barrier answered #{inspect(counts)}, not a count list"
    end

    case AiPair.PaneSupervisor.whereis_pane(pane_id) do
      :error -> :ok
      {:ok, _} -> drain_pane_loop!(pane_id, stop_at)
    end
  end

  @doc """
  Stop a raw process and require its DOWN to actually arrive, within
  `timeout_ms` IN TOTAL: the relative timeout is converted once, at entry, into
  an absolute deadline that the stop call and the DOWN wait share (F3). An
  earlier revision allowed the full timeout to GenServer.stop and then again to
  the DOWN wait.
  """
  @spec stop_and_join!(pid(), pos_integer()) :: :ok
  def stop_and_join!(pid, timeout_ms \\ 1_000),
    do: stop_and_join_by!(pid, System.monotonic_time(:millisecond) + timeout_ms)

  @doc false
  @spec stop_and_join_by!(pid(), integer()) :: :ok
  def stop_and_join_by!(pid, deadline) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :normal, remaining!(deadline, "stop of #{inspect(pid)}"))
      catch
        :exit, _ -> :ok
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        remaining!(deadline, "DOWN of #{inspect(pid)}") ->
          raise "#{inspect(pid)} did not terminate; cleanup unproven"
      end
    else
      :ok
    end
  end

  # ===== recorded refusals =====

  @doc "Every forbidden default-routed call, oldest first, as `{op, caller}`."
  @spec violations(pid() | atom()) :: [{atom(), pid()}]
  def violations(guard \\ @name), do: GenServer.call(guard, :violations)

  @impl true
  def init(opts) do
    {:ok,
     %{
       violations: [],
       owner: Keyword.get(opts, :owner),
       registry: Keyword.fetch!(opts, :registry),
       finalize_mode: Keyword.get(opts, :finalize_mode, :stop)
     }}
  end

  @impl true
  def handle_call(:violations, _from, state),
    do: {:reply, Enum.reverse(state.violations), state}

  # Must precede the catch-all: ownership registration is a legitimate request,
  # not a default-routed tmux call.
  #
  # Admission is CLOSED once contain!/1 has snapshotted the registry (F1) and
  # refused once a containment or restoration has FAILED (F4); both answer an
  # error instead of recording. A registry that cannot be reached (it is stopped
  # only after a successful restoration, when this guard is gone too) answers
  # an error as well; the boundary never crashes on an ownership request.
  #
  # A refused registration that CARRIES an already-acquired resource (a pane, a
  # process, a started collector) is not merely refused: that resource is now
  # unaccounted for, so the pass is marked failed and restore!/1 withholds
  # (m_1789249820: no stale contained:true). A refused RESERVATION carries
  # nothing - the collector is never started on refusal - and marks nothing.
  def handle_call({:own, entry}, _from, state) do
    reply =
      try do
        Agent.get_and_update(state.registry, fn s ->
          cond do
            s.failed ->
              {{:error, :containment_failed}, s}

            s.closing and carries_resource?(entry) ->
              {{:error, :containment_closed},
               %{s | failed: true, late_unaccounted: [entry | s.late_unaccounted]}}

            s.closing ->
              {{:error, :containment_closed}, s}

            true ->
              {:ok, %{s | owned: [entry | s.owned]}}
          end
        end)
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end

    {:reply, reply, state}
  end

  # A reservation is fulfilled by the collector's own init (F2). Refused when no
  # such reservation is recorded or admission is closed; recorded exactly once.
  def handle_call({:fulfil_collector, ref, pid}, _from, state) do
    reply =
      try do
        Agent.get_and_update(state.registry, fn s ->
          cond do
            s.failed ->
              {{:error, :containment_failed}, s}

            s.closing ->
              {{:error, :containment_closed}, s}

            {:collector_reservation, ref} in s.owned ->
              owned =
                Enum.map(s.owned, fn
                  {:collector_reservation, ^ref} -> {:collector, pid}
                  other -> other
                end)

              {:ok, %{s | owned: owned}}

            true ->
              {{:error, :no_reservation}, s}
          end
        end)
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end

    {:reply, reply, state}
  end

  # Must also precede the catch-all. Without this clause `owner_of/1` would fall
  # through to the forbidden-default-route handler, recording a bogus violation
  # and corrupting the very evidence these rows assert on.
  def handle_call(:registry, _from, state), do: {:reply, state.registry, state}

  # FINALIZATION (B1): serialised with every ownership request this guard has
  # acknowledged, because they all pass through this mailbox. One registry
  # transaction decides: a failed pass (including a late acquired-resource
  # refusal acknowledged earlier) or an uncontained one is REFUSED and the
  # guard stays up; otherwise the registry is marked finalized and the guard
  # stops in the same step, so restore!/1's pinned DOWN is the proof it acts on.
  # `finalize_mode: :ack_without_stop` is a test seam (install!/1 option) for
  # the guard-stop-failure control: it acknowledges but does not stop.
  def handle_call(:finalize, _from, state) do
    decision =
      try do
        Agent.get_and_update(state.registry, fn s ->
          cond do
            s.failed -> {{:error, {:late_unaccounted, s.late_unaccounted}}, s}
            not s.contained -> {{:error, :not_contained}, s}
            s.finalized -> {{:error, :already_finalized}, s}
            true -> {:ok, %{s | finalized: true}}
          end
        end)
      catch
        :exit, _ -> {:error, :registry_unavailable}
      end

    case {decision, state.finalize_mode} do
      {:ok, :stop} -> {:stop, :normal, :ok, state}
      {:ok, :ack_without_stop} -> {:reply, :ok, state}
      {error, _} -> {:reply, error, state}
    end
  end

  # Refuse and record, in AiPair.Tmux's own documented error shape
  # (tmux.ex:72), so the refusal travels the product's path rather than crashing
  # the caller for an unrelated reason.
  def handle_call(request, {caller, _}, state) do
    op = if is_tuple(request), do: elem(request, 0), else: request
    if state.owner, do: send(state.owner, {:forbidden_default_route, op, caller})

    reply =
      {:error,
       %{
         cmd: ["FORBIDDEN-DEFAULT-ROUTE", to_string(op)],
         status: -2,
         stderr: "test route guard refused a default-routed #{op}"
       }}

    {:reply, reply, %{state | violations: [{op, caller} | state.violations]}}
  end

  defp carries_resource?({:collector_reservation, _}), do: false
  defp carries_resource?(_), do: true
end
