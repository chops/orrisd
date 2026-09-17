defmodule AiPair.PaneRestore.CoordinatorTest do
  # RED successor for wiring scope r7 (f4521e29) after review dadd796c (M3/M6),
  # amended under Charles's 2026-09-12 grant (item 2) to the ruled API:
  # R07-SUCCESSOR-API-RULING-S1-S5 (S5) and scope r9 "Ruled minimal contracts".
  #
  # WHAT THE PREVIOUS REVISION GOT WRONG. It started unlinked Agents that were
  # never joined, used Process.sleep in place of barriers, executed
  # `fn -> :done end` locally (which can impersonate a target reply rather than
  # prove one), used unnamed processes where a same-NAMED replacement was the
  # point, and invented product escape hatches — stop_for_test/2,
  # record_withdrawal/1, admit_cached/2, ledger_entry/1 — so the rows asserted
  # labels instead of effects.
  #
  # THIS REVISION: a real controllable target defined in-file (the r7 allowance
  # is eight paths, so no new test/support module), barriers rather than sleeps,
  # genuine owner death, and forbidden second-body effects COUNTED rather than
  # inferred from a ledger read.
  #
  # THE API THIS FILE NOW ENCODES (grant item 2):
  #
  #   * submit/4 and submit_async/3 take a REQUEST TERM, not a closure. The
  #     coordinator resolves the target to a pid ONCE at submission, and a
  #     coordinator-owned worker performs `GenServer.call(target_pid, request)`.
  #     A closure can run anywhere and impersonate a reply; a request term can
  #     only be answered by the incarnation it was dispatched to.
  #   * transaction/2 returns the BODY RESULT, never a release status:
  #       {:ok, value} | {:unresolved, cause} | {:error, admission_error}
  #       | {:fence_update_failed, body_result, reason}
  #     A bare :ok body is gone — a body must say what it knows — and a known
  #     result is never discarded because the post-body ledger transition could
  #     not be acknowledged.
  #   * The same holder's request-term submission composes under its existing
  #     fence; any other caller is refused.
  #   * child_spec is restart: :temporary. A supervisor that brought the
  #     coordinator back would bring back an EMPTY ledger and silently re-open
  #     every fenced pane.
  use ExUnit.Case, async: false

  alias AiPair.PaneRestore.Coordinator

  # A target whose reply timing the test controls. Every request term this file
  # submits is served by a clause here, because the coordinator's worker
  # dispatches it VERBATIM with GenServer.call:
  #
  #   {:hold, ref}    accepted and never answered until release/2, which is how
  #                   an operation stays genuinely outstanding while its caller
  #                   dies. Notifies {:target_entered, ref}: the barrier that the
  #                   call was actually SERVED.
  #   {:echo, value}  answered at once with {:echoed, value, nonce}, where the
  #                   nonce is minted by this target and appears in no request,
  #                   so an awaited submit can be checked for carrying back the
  #                   ACTUAL relayed reply, not one a worker synthesized from
  #                   the request (F2, m_1789246100).
  #
  # `gate: true` starts the target serving NOTHING until it is sent :proceed
  # (or it stops itself after 5 s so a failing row cannot leak it). Calls sent
  # meanwhile sit unserved in its mailbox, which is how a row places a
  # dispatched request BEFORE the target has answered anything and then kills
  # that incarnation.
  defmodule Target do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)
    def hold(server, from_ref), do: GenServer.call(server, {:hold, from_ref}, :infinity)
    def release(server, value), do: GenServer.cast(server, {:release, value})
    def reply_now(server, value), do: GenServer.call(server, {:reply_now, value})
    def calls(server), do: GenServer.call(server, :calls)
    def nonce(server), do: GenServer.call(server, :nonce)

    @doc """
    Whether a call is outstanding RIGHT NOW. calls/1 is a history list that
    stays populated after a call completes, so it cannot witness that work is
    still in flight.
    """
    def waiting?(server), do: GenServer.call(server, :waiting?)

    @impl true
    def init(opts) do
      # F2 (m_1789246100): a NONCE minted by the target itself and never present
      # in any submitted request. An echo reply carries it, so a worker that
      # dispatches and then SYNTHESIZES the reply from the request data cannot
      # produce it; only a value relayed from this process can.
      state = %{waiting: nil, calls: [], notify: Keyword.get(opts, :notify), nonce: make_ref()}

      if Keyword.get(opts, :gate, false) do
        {:ok, state, {:continue, :gate}}
      else
        {:ok, state}
      end
    end

    # Runs BEFORE any queued message is served: a gated target killed here has
    # served nothing, and a row can prove a request reached its mailbox unserved.
    @impl true
    def handle_continue(:gate, state) do
      receive do
        :proceed -> {:noreply, state}
      after
        5_000 -> {:stop, :gate_timeout, state}
      end
    end

    @impl true
    def handle_call({:hold, ref}, from, state) do
      if state.notify, do: send(state.notify, {:target_entered, ref})
      {:noreply, %{state | waiting: from, calls: [{:hold, ref} | state.calls]}}
    end

    def handle_call({:echo, value}, _from, state) do
      {:reply, {:echoed, value, state.nonce}, %{state | calls: [{:echo, value} | state.calls]}}
    end

    # Test-only accessor for the target-held nonce; the coordinator never sends
    # this request, so knowing the nonce proves the reply came from the target.
    def handle_call(:nonce, _from, state), do: {:reply, state.nonce, state}

    def handle_call({:reply_now, value}, _from, state) do
      {:reply, value, %{state | calls: [{:reply_now, value} | state.calls]}}
    end

    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call(:waiting?, _from, state), do: {:reply, state.waiting != nil, state}

    @impl true
    def handle_cast({:release, _value}, %{waiting: nil} = state), do: {:noreply, state}

    def handle_cast({:release, value}, state) do
      GenServer.reply(state.waiting, value)
      {:noreply, %{state | waiting: nil}}
    end
  end

  defp pane, do: "pane-#{System.unique_integer([:positive])}"

  # Every actor this file starts is supervised and joined by ExUnit, including
  # the holder that the previous revision left running for the whole suite.
  defp start_target(opts \\ []) do
    start_supervised!({Target, Keyword.merge([notify: self()], opts)}, restart: :temporary)
  end

  defp start_coordinator do
    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
  end

  # spawn_joined owns the process we SPAWNED. The transaction body may run
  # somewhere else entirely, and a row learns that pid only from the message the
  # body reports. If an assertion fails between that report and the release, the
  # executor stays blocked in its receive for the rest of the suite, and owning
  # the caller does not free it. Bind termination the moment the pid is known —
  # before any fallible assertion — and JOIN it.
  defp own_reported!(pid) when is_pid(pid) do
    on_exit(fn ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> raise "reported actor #{inspect(pid)} did not terminate; cleanup unproven"
        end
      end
    end)

    pid
  end

  # spawn_monitor alone is NOT supervision or teardown: if an intervening
  # assertion fails, nothing terminates the process and the previous revision
  # left holders blocked for the remainder of the suite. Bounded termination is
  # registered BEFORE any fallible assertion and is JOINED, so a failing row
  # cannot leak a blocked holder.
  defp spawn_joined(fun) do
    {pid, ref} = spawn_monitor(fun)

    on_exit(fn ->
      # A fresh monitor: `ref` belongs to the test process, not to this
      # callback. An already-dead pid yields an immediate :noproc DOWN.
      cleanup_ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^cleanup_ref, :process, ^pid, _} -> :ok
      after
        1_000 -> raise "spawned actor #{inspect(pid)} did not terminate; cleanup unproven"
      end
    end)

    {pid, ref}
  end

  # A transaction body that holds the fence until the row releases it.
  #
  # Reports the ACTUAL executor. The previous revision released to the spawned
  # caller, ASSUMING the transaction body runs there. If an implementation runs
  # bodies in a worker instead, that release goes to the wrong process and the
  # holder never unblocks. The test can only own the executor AFTER
  # assert_receive yields its pid; if that assertion times out the pid is never
  # learned and an unbounded receive here would block for the rest of the
  # suite. Monitoring the parent and bounding the wait removes the dependency
  # on the barrier succeeding at all. Test-local; no product escape hatch.
  #
  # Returns {:ok, :released}, the ruled body shape. A bare :ok is now an
  # INVALID body result that fences the pane and raises — and a holder dying of
  # that raise would still satisfy a DOWN-with-any-reason assertion, so the
  # rows below also assert the holder's reported transaction result.
  defp blocking_body(parent, tag) do
    fn ->
      mon = Process.monitor(parent)
      send(parent, {tag, self()})

      receive do
        :release -> {:ok, :released}
        {:DOWN, ^mon, :process, ^parent, _} -> {:ok, :released}
      after
        5_000 -> {:ok, :released}
      end
    end
  end

  # Whether `request` is queued UNSERVED in `pid`'s mailbox as a GenServer call.
  # `{:"$gen_call", from, request}` is the wire shape GenServer.call/3 has used
  # since OTP's beginning; a dead pid reads as "not queued".
  defp queued_call?(pid, request) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> Enum.any?(messages, &match?({:"$gen_call", _from, ^request}, &1))
      nil -> false
    end
  end

  describe "the fence serialises a pane's lifecycle transaction" do
    test "a second transaction on the same pane is refused while the first holds" do
      _c = start_coordinator()
      p = pane()
      parent = self()

      {holder, ref} =
        spawn_joined(fn ->
          send(parent, {:holder_result, Coordinator.transaction(p, blocking_body(parent, :inside))})
        end)

      assert_receive {:inside, executor}, 1_000

      # Owned the moment it is KNOWN, before the fallible assertion below: if
      # that assertion fails, the executor is still blocked in its receive and
      # only a registration made now can free it.
      own_reported!(executor)

      assert {:error, :pane_busy} = Coordinator.transaction(p, fn -> flunk("must not run") end)

      send(executor, :release)

      # The body result, verbatim, once the fence is released — not a release
      # status, and not a raise the DOWN below would have accepted.
      assert_receive {:holder_result, {:ok, :released}}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1_000
    end

    test "different panes do not contend, and the holder is joined" do
      _c = start_coordinator()
      parent = self()

      {holder, ref} =
        spawn_joined(fn ->
          send(
            parent,
            {:holder_result, Coordinator.transaction(pane(), blocking_body(parent, :held))}
          )
        end)

      assert_receive {:held, executor}, 1_000
      own_reported!(executor)

      assert {:ok, :free} = Coordinator.transaction(pane(), fn -> {:ok, :free} end)

      # Released to the reported executor, not to the assumed caller.
      send(executor, :release)
      assert_receive {:holder_result, {:ok, :released}}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1_000
    end
  end

  describe "caller death and timeout never resolve an outstanding operation" do
    test "caller death with the target still holding leaves the pane fenced CLOSED" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      # A REQUEST TERM: the coordinator's worker performs the call. Nothing in
      # this row's own processes can answer it.
      {caller, mon} = spawn_joined(fn -> Coordinator.submit(p, target, {:hold, ref}) end)

      # Barrier: the target has actually ENTERED the call. No sleep.
      assert_receive {:target_entered, ^ref}, 1_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^mon, :process, ^caller, :killed}, 1_000

      # The lock may be free; the OPERATION is not resolved. Behaviour, not a
      # ledger read: the next transaction must fail closed.
      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)

      # And the target is still genuinely mid-call.
      assert [{:hold, ^ref}] = Target.calls(target)
    end

    test "a caller timeout does not cancel the submitted effect" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      parent = self()

      # Was an UNMONITORED spawn: nothing terminated or joined it.
      {caller, cref} =
        spawn_joined(fn ->
          # Report the EXACT outcome. Requiring only that the caller go DOWN
          # with ANY reason let a crash — or any unrelated exit — satisfy a row
          # named for a timeout.
          outcome =
            try do
              {:returned, Coordinator.submit(p, target, {:hold, ref}, 50)}
            catch
              kind, reason -> {kind, reason}
            end

          send(parent, {:submit_outcome, outcome})
        end)

      assert_receive {:target_entered, ^ref}, 1_000

      assert_receive {:submit_outcome, outcome}, 1_000

      assert match?({:returned, {:error, :timeout}}, outcome) or
               match?({:exit, {:timeout, _}}, outcome),
             "expected the named TIMEOUT outcome, got #{inspect(outcome)}"

      assert_receive {:DOWN, ^cref, :process, ^caller, _}, 1_000

      # CURRENT outstanding witness. Target.calls/1 is a HISTORY list — it stays
      # populated after a call completes — so it cannot show the call is still
      # in flight. waiting?/1 reports the live `from` the target still holds.
      assert Target.waiting?(target),
             "the target is no longer holding; the effect did not survive the caller timeout"

      assert [{:hold, ^ref}] = Target.calls(target)

      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)
    end

    test "worker death while the target is STILL ACTIVE is unknown, not completion" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      {:ok, worker} = Coordinator.submit_async(p, target, {:hold, ref})

      # Owned BEFORE the barrier below. The row kills and joins this worker
      # deliberately, but if assert_receive fails first that kill never runs.
      own_reported!(worker)

      wref = Process.monitor(worker)
      assert_receive {:target_entered, ^ref}, 1_000

      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^wref, :process, ^worker, :killed}, 1_000

      # A worker DOWN after a timed-out call does not prove the target's queued
      # callback finished — and here the target demonstrably has not.
      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)

      assert [{:hold, ^ref}] = Target.calls(target)
    end
  end

  describe "only the target's ACTUAL reply resolves an operation" do
    test "a released reply resolves and the next transaction proceeds" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      {:ok, worker} = Coordinator.submit_async(p, target, {:hold, ref})
      own_reported!(worker)
      assert_receive {:target_entered, ^ref}, 1_000

      # Resolution comes from the target, not from the test executing a closure
      # locally as the previous revision did.
      Target.release(target, {:ok, :committed})

      assert eventually(fn ->
               Coordinator.transaction(p, fn -> {:ok, :probe} end) == {:ok, :probe}
             end),
             "an actual target reply must eventually resolve the operation"
    end

    test "target death resolves only that the target is gone, never that the write did not happen" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      {:ok, worker} = Coordinator.submit_async(p, target, {:hold, ref})
      own_reported!(worker)
      assert_receive {:target_entered, ^ref}, 1_000

      tref = Process.monitor(target)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^tref, :process, ^target, :killed}, 1_000

      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)
    end
  end

  describe "the holder's own request-term submission composes under its fence" do
    # S5: "the same holder may submit its actual target operation under its
    # existing pane fence without releasing and reacquiring it. Other callers
    # remain refused." Encoded as effects: the target's ACTUAL reply comes back
    # to the holder, the intruder's request never reaches the target, and the
    # pane is free once the body returned.
    test "the holder receives the target's ACTUAL reply; another caller on the pane is refused" do
      _c = start_coordinator()
      target = start_target()
      p = pane()
      parent = self()
      ref = make_ref()

      {holder, mon} =
        spawn_joined(fn ->
          result =
            Coordinator.transaction(p, fn ->
              # Barrier: the fence is held. The row probes contention before
              # letting this body submit.
              hmon = Process.monitor(parent)
              send(parent, {:inside, self()})

              receive do
                :submit -> :ok
                {:DOWN, ^hmon, :process, ^parent, _} -> :ok
              after
                5_000 -> :ok
              end

              # Same holder, existing fence, no release-and-reacquire. The
              # request goes to the target and its reply comes back HERE.
              {:ok, Coordinator.submit(p, target, {:echo, ref}, 1_000)}
            end)

          send(parent, {:holder_result, result})
        end)

      assert_receive {:inside, executor}, 1_000
      own_reported!(executor)

      # Another caller is contention, refused before anything reaches the
      # target — the target's history is the witness, not the refusal alone.
      assert {:error, :pane_busy} = Coordinator.submit(p, target, {:echo, :intruder}, 100)
      assert Target.calls(target) == []

      send(executor, :submit)
      assert_receive {:holder_result, result}, 2_000

      # The value carried back is the target's ACTUAL reply to THIS request term:
      # it carries the nonce only the target holds (F2, m_1789246100). A worker
      # that dispatched and then synthesized {:echoed, ref} from the request
      # without relaying the reply cannot know the nonce and fails here.
      nonce = Target.nonce(target)
      assert {:ok, {:ok, {:echoed, ^ref, ^nonce}}} = result
      assert Target.calls(target) == [{:echo, ref}]
      assert_receive {:DOWN, ^mon, :process, ^holder, :normal}, 1_000

      # Composed, then released: the pane is free once the body returned.
      assert {:ok, :after} = Coordinator.transaction(p, fn -> {:ok, :after} end)
    end
  end

  describe "incarnation, not a reusable registered name" do
    test "a same-NAMED replacement does not satisfy an outstanding operation" do
      _c = start_coordinator()
      name = :"coordinator_target_#{System.unique_integer([:positive])}"
      first = start_supervised!({Target, [name: name, notify: self()]}, restart: :temporary)
      p = pane()
      ref = make_ref()

      {:ok, worker} = Coordinator.submit_async(p, name, {:hold, ref})
      own_reported!(worker)
      assert_receive {:target_entered, ^ref}, 1_000

      fref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^fref, :process, ^first, :killed}, 1_000

      # Same registered NAME, different incarnation.
      replacement =
        start_supervised!({Target, [name: name, notify: self()]},
          id: :replacement,
          restart: :temporary
        )

      assert replacement != first

      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)
    end

    test "a request dispatched to an incarnation that dies UNSERVED is lost, never re-dispatched to the same-NAMED replacement" do
      _c = start_coordinator()
      name = :"coordinator_target_#{System.unique_integer([:positive])}"
      parent = self()
      ref = make_ref()
      p = pane()

      # Gated: serves nothing until :proceed, which this row never sends. The
      # worker's request therefore sits in THIS incarnation's mailbox unserved.
      first =
        start_supervised!({Target, [name: name, notify: self(), gate: true]}, restart: :temporary)

      {caller, cref} =
        spawn_joined(fn ->
          outcome =
            try do
              {:returned, Coordinator.submit(p, name, {:echo, ref}, 5_000)}
            catch
              kind, reason -> {kind, reason}
            end

          send(parent, {:submit_outcome, outcome})
        end)

      # Barrier, not a sleep: the request has been DISPATCHED to the pid that
      # was resolved at submission, and is queued there unserved.
      assert eventually(fn -> queued_call?(first, {:echo, ref}) end),
             "the worker never dispatched {:echo, ref} to the submitted incarnation"

      fref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^fref, :process, ^first, :killed}, 1_000

      # Same registered NAME, different incarnation — and one that WOULD answer
      # {:echo, _} at once, so any re-dispatch by name shows up as {:ok, _}.
      replacement =
        start_supervised!({Target, [name: name, notify: self()]},
          id: :replacement,
          restart: :temporary
        )

      assert replacement != first
      assert GenServer.whereis(name) == replacement

      # The caller learns that the TARGET was lost — never a value, and never
      # a completion: an unserved request to a dead incarnation is not an
      # effect that happened.
      assert_receive {:submit_outcome, outcome}, 2_000
      assert {:returned, {:error, {:unresolved_operation, :target_lost}}} = outcome
      assert_receive {:DOWN, ^cref, :process, ^caller, :normal}, 1_000

      # The replacement was never called, and the pane stays fenced closed.
      assert Target.calls(replacement) == []

      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)
    end
  end

  describe "coordinator death does not silently resume with an empty ledger" do
    test "a real owner death fails durable operations closed until an operator restarts" do
      c = start_coordinator()
      target = start_target()
      p = pane()
      ref = make_ref()

      {:ok, worker} = Coordinator.submit_async(p, target, {:hold, ref})
      own_reported!(worker)
      assert_receive {:target_entered, ^ref}, 1_000

      cref = Process.monitor(c)
      Process.exit(c, :kill)
      assert_receive {:DOWN, ^cref, :process, ^c, :killed}, 1_000

      # restart: :temporary — no supervisor brings it back with an empty map.
      assert {:error, :coordinator_unavailable} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)
    end

    test "under a REAL supervisor the module's OWN child_spec brings back nothing: no empty-ledger replacement" do
      # The module's own child_spec, deliberately WITHOUT restart: from the
      # test. `use GenServer` defaults it to :permanent, and a :permanent
      # coordinator is restarted by any supervisor with an EMPTY ledger —
      # silently re-opening every fenced pane. The ruled spec is :temporary.
      # This row fails at today's default.
      sup =
        start_supervised!(%{
          id: :real_supervisor,
          start:
            {Supervisor, :start_link,
             [[{Coordinator, [name: Coordinator]}], [strategy: :one_for_one]]},
          type: :supervisor,
          restart: :temporary
        })

      assert [{Coordinator, c, :worker, [Coordinator]}] = Supervisor.which_children(sup)
      assert is_pid(c)

      p = pane()
      parent = self()

      {holder, mon} =
        spawn_joined(fn ->
          send(parent, {:holder_result, Coordinator.transaction(p, blocking_body(parent, :inside))})
        end)

      assert_receive {:inside, executor}, 1_000
      own_reported!(executor)

      cref = Process.monitor(c)
      Process.exit(c, :kill)
      assert_receive {:DOWN, ^cref, :process, ^c, :killed}, 1_000

      # Ordered AFTER the supervisor's decision: the child's EXIT signal was
      # enqueued at the kill, and this synchronous call is sent only after the
      # DOWN above was observed, so the supervisor serves it after handling
      # that exit. A :temporary child that exits is DELETED from the children
      # list; a restarted child listed here is the empty-ledger replacement.
      assert Supervisor.which_children(sup) == [],
             "the supervisor restarted the coordinator: an empty ledger now holds the name"

      assert Supervisor.count_children(sup).active == 0
      assert Process.whereis(Coordinator) == nil

      # No replacement: durable operations fail closed until an operator acts.
      assert {:error, :coordinator_unavailable} =
               Coordinator.transaction(p, fn -> flunk("must not run") end)

      # The held body still finishes with a KNOWN result, and there is no owner
      # to acknowledge its release. That result is preserved, not discarded.
      send(executor, :release)
      assert_receive {:holder_result, holder_result}, 1_000
      assert {:fence_update_failed, {:ok, :released}, _reason} = holder_result
      assert_receive {:DOWN, ^mon, :process, ^holder, _}, 1_000
    end
  end

  describe "the body result is returned, and a failed fence update never discards it" do
    # S5 result union. `:ok` here describes BODY COMPLETION, not an ok:true
    # business reply: a known application refusal is a value, not an unanswered
    # operation.
    test "{:ok, value} is returned verbatim and releases the fence — including an ok:false value" do
      _c = start_coordinator()
      p = pane()

      assert {:ok, %{stage: :put, persisted: true}} =
               Coordinator.transaction(p, fn -> {:ok, %{stage: :put, persisted: true}} end)

      # Released: the same pane admits the next body.
      assert {:ok, %{ok: false, error: "durable_metadata_missing"}} =
               Coordinator.transaction(p, fn ->
                 {:ok, %{ok: false, error: "durable_metadata_missing"}}
               end)

      # A known refusal is not an unresolved operation: still released.
      assert {:ok, :again} = Coordinator.transaction(p, fn -> {:ok, :again} end)
    end

    test "{:unresolved, cause} is returned verbatim and fences the pane closed; a later body runs zero times" do
      _c = start_coordinator()
      p = pane()
      {:ok, counter} = start_supervised({Agent, fn -> 0 end})

      assert {:unresolved, {:store_timeout, :put}} =
               Coordinator.transaction(p, fn -> {:unresolved, {:store_timeout, :put}} end)

      # Fenced: refused before the body, and the body's effect is COUNTED.
      assert {:error, :unresolved_operation} =
               Coordinator.transaction(p, fn ->
                 Agent.update(counter, &(&1 + 1))
                 {:ok, :counted}
               end)

      assert Agent.get(counter, & &1) == 0

      # Per-pane, not per-coordinator: another pane is unaffected.
      assert {:ok, :other} = Coordinator.transaction(pane(), fn -> {:ok, :other} end)
    end

    test "a body result that becomes known after the admitting coordinator died is preserved, never reported as released" do
      c = start_coordinator()
      p = pane()
      parent = self()

      # F1 (m_1789246100): ORCHESTRATION LIVES IN THE TEST OWNER. The body does
      # only two things - report the pid it actually executes in, then wait to be
      # told to proceed - so it holds no monitor of its own and never calls
      # ExUnit's supervised fixture API from a possibly non-test executor. The
      # test process owns the monitor on the admitting coordinator, kills it,
      # joins its DOWN, starts the same-named replacement under its own
      # supervision, and only then releases the body. Bounded failure cleanup:
      # the holder is joined by spawn_joined/1 and the reported executor is
      # owned by own_reported!/1 whatever happens between.
      {holder, mon} =
        spawn_joined(fn ->
          send(
            parent,
            {:holder_result,
             Coordinator.transaction(p, fn ->
               send(parent, {:body_at, self()})

               receive do
                 :proceed -> :ok
               after
                 5_000 -> exit({:body_never_released, self()})
               end

               # The owner is already gone when this body completes; its tagged
               # result becomes KNOWN only now. S5 (ruling lines 125-134) requires
               # that eventual known result to be preserved in fence_update_failed,
               # never discarded because the release cannot be acknowledged.
               # (Prose-only correction per m_1789247052; assertion and timing
               # unchanged.)
               {:ok, :committed}
             end)}
          )
        end)

      assert_receive {:body_at, executor}, 1_000
      own_reported!(executor)

      # Owner loss happens between the body's knowledge of its outcome and the
      # release the API will attempt: kill the admitting coordinator and JOIN
      # its DOWN in THIS process, so the post-body transition has no owner.
      cref = Process.monitor(c)
      Process.exit(c, :kill)
      assert_receive {:DOWN, ^cref, :process, ^c, :killed}, 1_000

      # A same-NAMED replacement, live BEFORE the release is attempted, started
      # by the test owner. A release that re-resolved the registered name would
      # reach a coordinator that never admitted this body.
      replacement =
        start_supervised!({Coordinator, [name: Coordinator]},
          id: :replacement_coordinator,
          restart: :temporary
        )

      assert replacement != c
      send(executor, :proceed)

      assert_receive {:holder_result, result}, 5_000
      assert_receive {:DOWN, ^mon, :process, ^holder, _}, 1_000

      # The fourth ruled result, carrying the EXACT body result. Today's code
      # throws the known {:ok, ..} away, and a release addressed by name to the
      # replacement is answered {:error, :not_holder} by a ledger that never
      # admitted this pane.
      assert {:fence_update_failed, {:ok, :committed}, reason} = result

      refute reason in [:not_holder, {:error, :not_holder}],
             "the release was addressed to the replacement, not to the admitting pid: " <>
               inspect(reason)
    end
  end

  describe "forbidden second-body effects are COUNTED, not inferred" do
    test "a refused second transaction executes its body zero times" do
      _c = start_coordinator()
      p = pane()
      parent = self()
      {:ok, counter} = start_supervised({Agent, fn -> 0 end})

      {holder, ref} =
        spawn_joined(fn ->
          send(parent, {:holder_result, Coordinator.transaction(p, blocking_body(parent, :inside))})
        end)

      assert_receive {:inside, executor}, 1_000
      own_reported!(executor)

      for _ <- 1..3 do
        Coordinator.transaction(p, fn ->
          Agent.update(counter, &(&1 + 1))
          {:ok, :counted}
        end)
      end

      # The counter assertion can fail. Because spawn_joined registered bounded
      # termination up front, a failure here no longer leaks a blocked holder.
      assert Agent.get(counter, & &1) == 0

      send(executor, :release)
      assert_receive {:holder_result, {:ok, :released}}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 1_000
    end
  end

  defp eventually(fun, deadline_ms \\ 1_000) do
    stop_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.reduce_while(false, fn ok, _ ->
      cond do
        ok -> {:halt, true}
        System.monotonic_time(:millisecond) > stop_at -> {:halt, false}
        true -> Process.sleep(10) && {:cont, false}
      end
    end)
  end
end
