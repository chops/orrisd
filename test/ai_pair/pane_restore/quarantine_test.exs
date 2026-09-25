defmodule AiPair.PaneRestore.QuarantineTest do
  # R04 slice S6: the quarantine field and gate on AiPair.Pane.StateMachine,
  # ported from the reviewed lane (integrate/boot-abc-a2-reviewed-20260913,
  # ff8650e) onto main. Rows that depended on the lane-only
  # AiPair.Test.RouteGuard support module (its setup guard, the ISOLATION and
  # EFFECT-WIRING controls) are NOT ported here: RouteGuard is the S11 test
  # support slice. Every row below drives the state machine through the same
  # injected :capture_fn / :paste_fn fakes the existing state-machine tests
  # use, so no tmux server, daemon or socket is ever addressed.
  #
  # The drain rows seed controlled pending work with :sys.replace_state on a
  # state machine THIS TEST owns (an intrusion into an owned process, not a new
  # product escape API), then drive the real debounce timer.
  #
  # No release API is asserted anywhere: S6 ships the field and the gate, not
  # the opener, because no agent-binding producer exists.
  use ExUnit.Case, async: false

  alias AiPair.Pane.StateMachine

  defp setup_pane(opts) do
    {:ok, capture_agent} =
      start_supervised({Agent, fn -> Keyword.get(opts, :initial_capture, "") end},
        id: {:capture, System.unique_integer([:positive])}
      )

    {:ok, paste_agent} =
      start_supervised({Agent, fn -> [] end}, id: {:paste, System.unique_integer([:positive])})

    capture_fn = fn _pane_id -> {:ok, Agent.get(capture_agent, & &1)} end

    paste_fn = fn _pane_id, text ->
      Agent.update(paste_agent, &[text | &1])
      :ok
    end

    {:ok, sm} =
      StateMachine.start_link(
        Keyword.merge(
          [
            pane_id: "%quarantine-" <> Integer.to_string(System.unique_integer([:positive])),
            capture_fn: capture_fn,
            paste_fn: paste_fn,
            classifier: AiPair.Test.MarkerClassifier,
            poll_interval_ms: 5,
            idle_debounce_ms: 40
          ],
          Keyword.drop(opts, [:initial_capture])
        )
      )

    on_exit(fn ->
      if Process.alive?(sm) do
        ref = Process.monitor(sm)

        try do
          :gen_statem.stop(sm, :normal, 500)
        catch
          # Already down is a legitimate join; any other exit is still joined
          # by the DOWN below, which must ARRIVE.
          :exit, _ -> :ok
        end

        # A timeout returning :ok is not a join — it is an unproven teardown.
        # Fail loudly instead.
        receive do
          {:DOWN, ^ref, :process, ^sm, _} -> :ok
        after
          500 ->
            raise "state machine #{inspect(sm)} did not terminate; teardown is unproven"
        end
      end
    end)

    {sm, capture_agent, paste_agent}
  end

  defp pastes(agent), do: Agent.get(agent, &Enum.reverse(&1))

  # ===== DRAIN WITNESS =====
  #
  # The DEFAULT subject of await_drain_event!/4's failure, raised from BOTH of
  # its exits (already-expired on entry, and receive timeout). Defined once so
  # the two exits cannot drift.
  #
  # THE SUBJECT IS A PARAMETER because await_drain_event!/4 is called on TWO
  # DIFFERENT CHILDREN: the quarantined child, and the paired legacy clock. A
  # single shared message would kill a CLOCK-side failure with a sentence
  # naming the QUARANTINED child, sending the next debugger to the wrong
  # process.
  #
  # This wording is the quarantined row's named assertion. It is pinned
  # byte-for-byte by the control rows' assert_raise below: do not reword it.
  @drain_witness_failure "the quarantined child never processed a drain event; the row proves nothing"

  # The clock's subject. The clock does have a correctly worded companion
  # assertion on its paste, but the witness is awaited FIRST and so fails
  # first; this is the message that actually reaches the debugger.
  @clock_witness_failure "the paired clock pane never processed a drain event; the debounce window is unproven"

  # The default bound, named so the clock call site can pass its own subject
  # without restating — and later drifting from — the deadline.
  @drain_witness_deadline_ms 1_000

  # Raised when the witness sees a drain-SHAPED system event it cannot match
  # exactly.
  #
  # FAIL CLOSED, BUT ONLY WITHIN THE SHAPE IT ALREADY MATCHES.
  # classify_witness_event/1's :unknown clauses catch only SAME-ARITY,
  # SAME-TAG drift: a 4-tuple `{:consume | :postpone, {:state_timeout, _}, _,
  # _}`. Drift that changes the ARITY or the TAG falls through to the
  # `:ignore` catch-all and the witness goes INERT, not loud. The defense
  # against that class is the CLOCK POSITIVE CONTROL: a witness gone inert
  # emits no envelope for the clock either, so the clock's await FAILS and the
  # row stops there instead of promoting the quarantined child's silence to
  # evidence.
  @drain_witness_unknown "the drain witness saw a drain-shaped event it cannot match exactly: "

  # WHY A `:sys.install/3` DEBUG CALLBACK AND NOT RECEIVE TRACING.
  #
  # In OTP 29 (stdlib-8.0.3) gen_statem arms a state time-out with
  # `erlang:start_timer(Time, self(), TimeoutType, TimeoutOpts)`, so the
  # mailbox message is `{timeout, ref, :state_timeout}` and the atom
  # `:drain_pending` NEVER appears in any message this process receives. The
  # EventContent is re-attached only after receipt, from the process's own
  # timer map. Receive tracing therefore cannot observe the event the row is
  # named for.
  #
  # gen_statem reports the RESOLVED event to sys debug at the state
  # transition as `{consume, Event, State, NextState}` (a documented
  # `sys:system_event()`), where `Event` is exactly
  # `{:state_timeout, :drain_pending}`.
  #
  # WHY `:consume` AND NOT `{:in,...}` — THE ORDERING IS THE POINT. `{:in,...}`
  # is emitted when the event is dequeued, BEFORE the callback runs.
  # `{:consume,...}` is emitted from loop_state_transition/8, only after
  # handle_event/4 has RETURNED — and drain_queue/2 calls do_paste/5
  # synchronously inside that callback. So by the time this witness fires,
  # any paste the drain was going to perform has already happened.
  #
  # THE CALLBACK DECIDES NOTHING THAT COULD RAISE. sys.erl's handle_debug/4
  # wraps every installed debug function in a try: an ERROR or EXIT is
  # SWALLOWED and the callback is silently dropped from the debug list. A
  # witness that tried to fail closed by raising in there would fail by
  # DISAPPEARING. The callback only pattern-matches and forwards; every
  # verdict is reached in the test process, where a raise is actually fatal.
  defp install_drain_witness!(sm) do
    owner = self()
    ref = make_ref()

    # `self()` inside the callback is evaluated when the callback RUNS, i.e. in
    # the observing child, so the envelope carries the identity of the process
    # that actually consumed the event rather than a pid copied in from here.
    # `ref` pins the envelope to THIS installation.
    fun = fn func_state, event, _name ->
      case classify_witness_event(event) do
        :ignore ->
          func_state

        payload ->
          send(owner, {:drain_witness, ref, self(), payload})
          # One-shot: `done` removes this debug function (sys.erl handle_debug/4),
          # so a single bounded envelope is produced and the child is not left
          # streaming events at a test process that has stopped listening.
          :done
      end
    end

    # THE FRESH `ref` IN THE FuncId IS LOAD-BEARING. sys.erl's install_debug/3
    # is a SILENT NO-OP on a duplicate FuncId and debug_cmd/2 still returns
    # {ok, ...}, so the `:ok =` match below would NOT catch a constant id being
    # discarded on a second installation. make_ref/0 makes that unreachable by
    # construction. The FuncId must also never be `trace`, `log`, `log_to_file`
    # or `statistics`: handle_debug/4 matches those four AHEAD of the
    # {FuncId, {Func, FuncState}} clause.
    :ok = :sys.install(sm, {{:drain_witness, ref}, fun, :installed}, 1_000)
    ref
  end

  # Total, exact, and fail-closed. Order matters: the events that legitimately
  # MENTION :drain_pending without being the drain being processed are ignored
  # by the catch-all, while a drain-shaped event that is not exactly the one
  # this fixture understands is reported as :unknown rather than ignored.
  defp classify_witness_event({:consume, {:state_timeout, :drain_pending}, :idle, :idle}),
    do: :drained

  # A state time-out CONSUMED in some other state, or with some other content.
  # Only one state time-out exists in the product (:drain_pending), so this can
  # fire only if the runtime's event shape or the product's timer has drifted.
  defp classify_witness_event({:consume, {:state_timeout, _}, _, _} = event),
    do: {:unknown, event}

  # POSTPONED is not PROCESSED. Accepting it would let the row claim a drain
  # that the state machine deliberately deferred.
  defp classify_witness_event({:postpone, {:state_timeout, _}, _, _} = event),
    do: {:unknown, event}

  # Everything else: poll time-outs, calls, state entries, and in particular
  # `{:start_timer, {:state_timeout, _, :drain_pending, _}, _}` (the timer being
  # ARMED) and `{:in, {:state_timeout, :drain_pending}, _}` (the event being
  # DISPATCHED). Both mention :drain_pending and both are reported BEFORE the
  # drain has been handled, so accepting either would be a false positive.
  defp classify_witness_event(_event), do: :ignore

  # Exactly ONE bounded `receive` and no recursion, so the function cannot
  # loop however many events the child produces (the callback is one-shot and
  # emits at most one envelope). The deadline is checked BEFORE the receive is
  # entered, so no queued witness can rescue an expired call and
  # `after deadline_ms` is always strictly positive.
  defp await_drain_event!(
         sm,
         ref,
         deadline_ms \\ @drain_witness_deadline_ms,
         failure_message \\ @drain_witness_failure
       ) do
    if deadline_ms <= 0 do
      raise failure_message
    end

    # Pinned to BOTH the installation `ref` and the exact child pid. The paired
    # clock child below is deliberately witnessed too, and its envelope cannot
    # match this pattern: it stays in the mailbox and the deadline still governs.
    result =
      receive do
        {:drain_witness, ^ref, ^sm, payload} -> payload
      after
        deadline_ms -> :expired
      end

    case result do
      :drained -> :ok
      :expired -> raise failure_message
      other -> raise @drain_witness_unknown <> inspect(other)
    end
  end

  defp wait_until_state(sm, target, deadline_ms \\ 1_000) do
    end_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> StateMachine.state(sm) end)
    |> Enum.reduce_while(:no, fn s, _ ->
      cond do
        s == target -> {:halt, :ok}
        System.monotonic_time(:millisecond) > end_at -> {:halt, {:timeout, s}}
        true -> Process.sleep(5) && {:cont, :no}
      end
    end)
  end

  # Canonicalised because a store root reached through a /tmp SYMLINK is
  # rejected before the behaviour under test, surfacing as a fixture
  # MatchError.
  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc ->
      joined = Path.join(acc, seg)

      case File.read_link(joined) do
        {:ok, "/" <> _ = absolute} -> absolute
        {:ok, relative} -> Path.expand(Path.join(Path.dirname(joined), relative))
        {:error, _} -> joined
      end
    end)
  end

  defp owned_store do
    inbox = Path.join(canonical_tmp(), "quarantine-#{System.unique_integer([:positive])}")

    # Registered BEFORE the directory exists: an on_exit added after mkdir is
    # never registered at all if mkdir raises, and the directory leaks.
    on_exit(fn -> File.rm_rf!(inbox) end)

    File.mkdir_p!(inbox)

    start_supervised!(%{
      id: {AiPair.Delivery.ReceiptStore, inbox},
      start: {AiPair.Delivery.ReceiptStore, :start_link, [[inbox: inbox]]},
      restart: :temporary
    })
  end

  describe "a pane started the existing way is not quarantined" do
    test "status reports quarantined: false and a send lands through the supplied paste" do
      {sm, _capture, paste} = setup_pane(initial_capture: "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)

      assert %{quarantined: false} = StateMachine.status(sm)

      # DISPATCHABLE means a send actually lands, not merely that a flag is
      # false. The return value is deliberately not asserted (it may be :ok or
      # {:queued, :debounce} depending on the debounce race); the evidence is
      # the observed paste.
      _ = StateMachine.send_text(sm, "legacy")

      assert eventually(fn -> pastes(paste) == ["legacy"] end),
             "a pane started without :quarantine_token must still dispatch"
    end
  end

  describe "every dispatch entry point is refused, and nothing is enqueued" do
    for {name, call} <- [
          {"send_text", :send_text},
          {"send_legacy", :send_legacy},
          {"send_receipted", :send_receipted}
        ] do
      test "#{name} is refused in :idle with zero paste and zero queued work" do
        store = if unquote(call) == :send_receipted, do: owned_store(), else: nil

        opts =
          [initial_capture: "IDLE_MARKER", quarantine_token: make_ref()] ++
            if(store, do: [receipt_store: store], else: [])

        {sm, _capture, paste} = setup_pane(opts)
        assert :ok = wait_until_state(sm, :idle)

        # Past the debounce: an ordinary idle pane would paste SYNCHRONOUSLY
        # here, so a refusal below is discriminated from a mere queueing.
        Process.sleep(60)

        result =
          case unquote(call) do
            :send_text ->
              StateMachine.send_text(sm, "hello")

            :send_legacy ->
              StateMachine.send_legacy(sm, "hello", 1_000, nil)

            :send_receipted ->
              id = "snd_" <> String.duplicate("a", 64)
              StateMachine.send_receipted(sm, "hello", 1_000, id, store)
          end

        assert {:error, :pane_quarantined} = result
        # Zero runner calls: the injected paste fake was never invoked.
        assert pastes(paste) == []
        # Refusal, not enqueueing: a queued send would paste when the gate opened.
        assert StateMachine.pending_count(sm) == 0
      end

      test "#{name} is refused in a NON-IDLE state with zero queued work" do
        store = if unquote(call) == :send_receipted, do: owned_store(), else: nil

        opts =
          [initial_capture: "BUSY_MARKER", quarantine_token: make_ref()] ++
            if(store, do: [receipt_store: store], else: [])

        {sm, _capture, paste} = setup_pane(opts)
        assert :ok = wait_until_state(sm, :busy)

        result =
          case unquote(call) do
            :send_text ->
              StateMachine.send_text(sm, "hello")

            :send_legacy ->
              StateMachine.send_legacy(sm, "hello", 1_000, nil)

            :send_receipted ->
              id = "snd_" <> String.duplicate("b", 64)
              StateMachine.send_receipted(sm, "hello", 1_000, id, store)
          end

        assert {:error, :pane_quarantined} = result
        # A busy pane normally QUEUES. Quarantine must refuse instead, or the
        # work drains the moment the pane reaches idle.
        assert StateMachine.pending_count(sm) == 0
        assert pastes(paste) == []
      end

      # BASE-GREEN CHARACTERISATION (S2 step 2G), never a RED row: it pins the
      # behaviour the base already has, so it is qualified GREEN before any RED
      # step and is never listed in a RED receipt. The quarantine clause is
      # matched ahead of every state-specific send clause, including :dead's.
      test "#{name} is refused in :dead with zero paste and zero queued work (base-GREEN characterisation)" do
        store = if unquote(call) == :send_receipted, do: owned_store(), else: nil

        opts =
          [initial_capture: "BUSY_MARKER", quarantine_token: make_ref()] ++
            if(store, do: [receipt_store: store], else: [])

        {sm, _capture, paste} = setup_pane(opts)
        assert :ok = wait_until_state(sm, :busy)

        StateMachine.mark_dead(sm)
        assert :ok = wait_until_state(sm, :dead)

        result =
          case unquote(call) do
            :send_text ->
              StateMachine.send_text(sm, "hello")

            :send_legacy ->
              StateMachine.send_legacy(sm, "hello", 1_000, nil)

            :send_receipted ->
              id = "snd_" <> String.duplicate("c", 64)
              StateMachine.send_receipted(sm, "hello", 1_000, id, store)
          end

        assert {:error, :pane_quarantined} = result
        # Zero runner calls: the injected paste fake was never invoked.
        assert pastes(paste) == []
        # Refusal, not enqueueing, in the terminal state as well.
        assert StateMachine.pending_count(sm) == 0
      end
    end
  end

  describe "the drain guard is discriminated by SEEDED work, not an empty queue" do
    test "pending work present before idle is never drained while quarantined" do
      {sm, capture, paste} =
        setup_pane(initial_capture: "BUSY_MARKER", quarantine_token: make_ref())

      assert :ok = wait_until_state(sm, :busy)

      # Install the witness BEFORE the drain window can open. The child is still
      # :busy here and the drain time-out is armed only on ENTERING :idle
      # (state_machine.ex handle_event(:enter, _, :idle, _)), so the callback is
      # in place strictly before the window it observes can exist.
      drain_ref = install_drain_witness!(sm)

      # Seed controlled work directly into the owned state machine. Without this
      # the queue is empty and deleting the drain guard still passes.
      entry = {"seeded", :otel_ctx.get_current(), nil, System.monotonic_time(:millisecond)}

      :sys.replace_state(sm, fn {state, data} ->
        {state, %{data | pending_sends: :queue.in(entry, data.pending_sends)}}
      end)

      assert StateMachine.pending_count(sm) == 1

      # A PAIRED LEGACY pane on the same debounce is the clock: the window is
      # proven elapsed by an OBSERVED drain on an identically seeded sibling,
      # rather than asserted by a fixed sleep.
      {clock_sm, clock_capture, clock_paste} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(clock_sm, :busy)

      # POSITIVE CONTROL FOR THE WITNESS MECHANISM ITSELF, installed on the
      # clock child BEFORE EITHER pane is transitioned to idle. Without this
      # pairing, a witness that had gone inert would be indistinguishable from
      # a quarantined child that correctly refused to drain.
      clock_ref = install_drain_witness!(clock_sm)

      clock_entry = {"clock", :otel_ctx.get_current(), nil, System.monotonic_time(:millisecond)}

      :sys.replace_state(clock_sm, fn {state, data} ->
        {state, %{data | pending_sends: :queue.in(clock_entry, data.pending_sends)}}
      end)

      Agent.update(capture, fn _ -> "IDLE_MARKER" end)
      assert :ok = wait_until_state(sm, :idle)

      Agent.update(clock_capture, fn _ -> "IDLE_MARKER" end)
      assert :ok = wait_until_state(clock_sm, :idle)

      # BOTH halves of the positive control: the exact consume event on the
      # clock child, and the paste that event's handler actually performed.
      assert :ok =
               await_drain_event!(
                 clock_sm,
                 clock_ref,
                 @drain_witness_deadline_ms,
                 @clock_witness_failure
               )

      assert eventually(fn -> pastes(clock_paste) == ["clock"] end),
             "the paired legacy pane never drained, so the debounce window is unproven"

      # The clock alone is insufficient: it shows elapsed time and a SIBLING
      # drain, not that THIS child's drain event was processed. Suppressing
      # only the quarantined timer would satisfy everything above. This waits
      # for the event to actually reach the quarantined child, so deleting the
      # drain guard fails the row instead of passing it — and so does moving
      # the guard to the ARMING site (the timer must still be armed, delivered
      # and consumed; only the paste is suppressed).
      assert :ok = await_drain_event!(sm, drain_ref)

      assert pastes(paste) == [],
             "a quarantined pane drained seeded work; the drain guard is missing"

      assert StateMachine.pending_count(sm) == 1
    end

    test "the same seeded work DOES drain on a legacy pane" do
      # Positive control for the row above: if this fails, the seeding technique
      # is broken and the quarantined row proves nothing.
      {sm, capture, paste} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy)

      entry = {"seeded", :otel_ctx.get_current(), nil, System.monotonic_time(:millisecond)}

      :sys.replace_state(sm, fn {state, data} ->
        {state, %{data | pending_sends: :queue.in(entry, data.pending_sends)}}
      end)

      Agent.update(capture, fn _ -> "IDLE_MARKER" end)
      assert :ok = wait_until_state(sm, :idle)

      assert eventually(fn -> pastes(paste) == ["seeded"] end),
             "seeded work must drain on a legacy pane, or the seeding technique is invalid"
    end
  end

  describe "WITNESS MECHANISM CONTROLS: the drain witness can observe, and can fail" do
    # The clock child in the drain row above is the control that the witness can
    # observe a REAL consumed drain on a REAL child. These rows control the
    # other half — that the classifier is EXACT, fails CLOSED, and is PINNED —
    # by driving the helpers directly with fabricated events and envelopes. They
    # start no pane, so no product behaviour can satisfy them, and a witness
    # weakened into always-accepting or always-ignoring fails them.

    test "only the exact CONSUMED drain event is accepted" do
      assert classify_witness_event({:consume, {:state_timeout, :drain_pending}, :idle, :idle}) ==
               :drained

      # The timer being ARMED is reported as {:start_timer, Action, State} and
      # mentions :drain_pending. It is emitted when the debounce window OPENS,
      # so accepting it would let the row pass before the drain was ever due.
      armed = {:start_timer, {:state_timeout, 40, :drain_pending, []}, :idle}
      assert classify_witness_event(armed) == :ignore

      # DISPATCH, not consumption: emitted before handle_event/4 runs, so the
      # paste assertions would race the handler.
      assert classify_witness_event({:in, {:state_timeout, :drain_pending}, :idle}) == :ignore

      assert classify_witness_event({:in, {{:timeout, :poll}, nil}, :idle}) == :ignore
    end

    test "a drain-shaped event that cannot be matched exactly fails CLOSED" do
      # Consumed in a different state: the shape drifted, so the row must stop
      # rather than quietly treat it as the drain it was waiting for.
      drifted = {:consume, {:state_timeout, :drain_pending}, :idle, :dead}
      assert {:unknown, ^drifted} = classify_witness_event(drifted)

      # POSTPONED is not PROCESSED.
      postponed = {:postpone, {:state_timeout, :drain_pending}, :idle, :idle}
      assert {:unknown, ^postponed} = classify_witness_event(postponed)

      # ... and an unrecognised payload reaching the waiter is FATAL, not
      # ignored and not silently waited out as an ordinary timeout.
      ref = make_ref()
      send(self(), {:drain_witness, ref, self(), {:unknown, drifted}})

      assert_raise RuntimeError, ~r/cannot match exactly/, fn ->
        await_drain_event!(self(), ref, 200)
      end

      # A payload shape the waiter has never seen is fatal too, so the classifier
      # cannot be bypassed by a future envelope it does not understand.
      send(self(), {:drain_witness, ref, self(), :something_new})

      assert_raise RuntimeError, ~r/cannot match exactly/, fn ->
        await_drain_event!(self(), ref, 200)
      end
    end

    test "a sibling's drain, or another installation's, can never satisfy a pinned wait" do
      sibling = spawn(fn -> receive do: (:never -> :ok) end)
      on_exit(fn -> Process.exit(sibling, :kill) end)

      ref = make_ref()

      # Right event, right installation, WRONG CHILD. This is the paired clock
      # sibling's case: its drain must never stand in for the quarantined one.
      send(self(), {:drain_witness, ref, sibling, :drained})

      assert_raise RuntimeError, @drain_witness_failure, fn ->
        await_drain_event!(self(), ref, 50)
      end

      # Right event, right child, WRONG INSTALLATION, so one row's witness can
      # never be satisfied by an envelope another install left in the mailbox.
      send(self(), {:drain_witness, make_ref(), self(), :drained})

      assert_raise RuntimeError, @drain_witness_failure, fn ->
        await_drain_event!(self(), ref, 50)
      end
    end

    test "an already-expired deadline raises without consulting the mailbox" do
      ref = make_ref()
      send(self(), {:drain_witness, ref, self(), :drained})

      # A satisfying envelope is queued RIGHT NOW. It must not rescue a wait
      # whose deadline has already passed.
      assert_raise RuntimeError, @drain_witness_failure, fn ->
        await_drain_event!(self(), ref, 0)
      end

      # ... and that same queued envelope still satisfies a live wait, so the
      # row above failed for the deadline and not because the witness is inert.
      assert :ok = await_drain_event!(self(), ref, 200)
    end
  end

  describe "read-only calls stay open while quarantined" do
    test "state, status, get_info and pending_count answer, and the token is not exposed" do
      token = make_ref()
      {sm, _capture, _paste} = setup_pane(initial_capture: "IDLE_MARKER", quarantine_token: token)
      assert :ok = wait_until_state(sm, :idle)

      # Precondition: without this the pane is an ordinary one and the row
      # passes for the wrong reason.
      status = StateMachine.status(sm)
      assert status.quarantined == true

      assert StateMachine.state(sm) == :idle
      assert %{state: :idle} = StateMachine.get_info(sm)
      assert StateMachine.pending_count(sm) == 0
      refute Map.has_key?(status, :quarantine_token)
      refute inspect(status) =~ inspect(token)

      # The struct's Inspect derivation withholds the token from the paths
      # nobody asserts on (:sys.get_state/1, crash dumps, supervisor reports).
      {_state, data} = :sys.get_state(sm)
      refute inspect(data) =~ inspect(token)
    end
  end

  describe "the owned supervisor's transient restart" do
    # Both rows start the child through the REAL AiPair.PaneSupervisor with the
    # injected capture/paste fakes supplied, exactly as pane_supervisor_test.exs
    # and the IPC contract tests already do on main, so no default tmux route
    # is reachable. Cleanup is an explicit stop_pane of whichever child holds
    # the pane id at exit (the lane registered the id with RouteGuard instead).

    test "a restarted RESTORATION child comes back quarantined" do
      pane_id = "%quarantine-sup-" <> Integer.to_string(System.unique_integer([:positive]))
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      {:ok, first} =
        AiPair.PaneSupervisor.start_pane(pane_id,
          capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
          paste_fn: fn _, _ -> :ok end,
          classifier: AiPair.Test.MarkerClassifier,
          quarantine_token: make_ref()
        )

      assert StateMachine.status(first).quarantined == true

      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 1_000

      # restart: :transient (pane_supervisor.ex) brings it back under the same
      # via-name from the same child spec. It must not come back dispatchable.
      #
      # IDENTITY-BOUND barrier: the killed child's Registry entry is reaped
      # asynchronously, so a plain `match?({:ok, _}, ...)` is satisfied by the
      # not-yet-reaped entry. Require a DIFFERENT, live pid before calling it.
      assert eventually(fn ->
               case AiPair.PaneSupervisor.whereis_pane(pane_id) do
                 {:ok, pid} -> pid != first and Process.alive?(pid)
                 :error -> false
               end
             end),
             "no replacement child distinct from the killed pid registered for #{pane_id}"

      {:ok, restarted} = AiPair.PaneSupervisor.whereis_pane(pane_id)
      assert restarted != first
      assert StateMachine.status(restarted).quarantined == true
      assert {:error, :pane_quarantined} = StateMachine.send_text(restarted, "hello")
    end

    test "a restarted LEGACY child comes back dispatchable, unchanged" do
      pane_id = "%quarantine-legacy-" <> Integer.to_string(System.unique_integer([:positive]))
      on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

      # A RECORDING paste callback: an unexercised callback proves nothing
      # about dispatch.
      {:ok, paste_agent} =
        start_supervised({Agent, fn -> [] end},
          id: {:legacy_paste, System.unique_integer([:positive])}
        )

      {:ok, first} =
        AiPair.PaneSupervisor.start_pane(pane_id,
          capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
          paste_fn: fn _, text ->
            Agent.update(paste_agent, &[text | &1])
            :ok
          end,
          classifier: AiPair.Test.MarkerClassifier
        )

      ref = Process.monitor(first)
      Process.exit(first, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 1_000

      assert eventually(fn ->
               case AiPair.PaneSupervisor.whereis_pane(pane_id) do
                 {:ok, pid} -> pid != first and Process.alive?(pid)
                 :error -> false
               end
             end),
             "no replacement child distinct from the killed pid registered for #{pane_id}"

      {:ok, restarted} = AiPair.PaneSupervisor.whereis_pane(pane_id)
      assert restarted != first
      refute Map.get(StateMachine.status(restarted), :quarantined, false)

      # DISPATCHABLE means a send actually lands, not merely that a flag is
      # absent. The replacement inherits the recording paste_fn through its
      # child spec, so an accepted send must surface as an observed paste on
      # the NEW pid.
      _ = StateMachine.send_text(restarted, "after-restart")

      assert eventually(fn -> Agent.get(paste_agent, & &1) == ["after-restart"] end),
             "the restarted legacy child accepted no send; dispatchability is unproven"
    end
  end

  describe "regression: fingerprint classification is not agent binding" do
    test "one captured string classifies :busy under BOTH shipped fingerprints" do
      # Pinned so nobody 'repairs' the absent release path by broadening these
      # patterns: a fingerprint match cannot identify WHICH agent owns a pane,
      # which is why quarantine has no classifier-driven release.
      {:ok, claude} = AiPair.Fingerprint.load(fingerprint_path("claude_code.json"))
      {:ok, codex} = AiPair.Fingerprint.load(fingerprint_path("codex_cli.json"))

      shared = "esc to interrupt"

      assert {:ok, :busy} = AiPair.Fingerprint.match(shared, claude)
      assert {:ok, :busy} = AiPair.Fingerprint.match(shared, codex)
    end
  end

  defp fingerprint_path(file) do
    case Application.get_env(:ai_pair, :fingerprint_dir) do
      nil -> Path.join([to_string(:code.priv_dir(:ai_pair)), "fingerprints", file])
      dir -> Path.join(dir, file)
    end
  end

  defp eventually(fun, deadline_ms \\ 1_000) do
    stop_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fun)
    |> Enum.reduce_while(false, fn ok, _ ->
      cond do
        ok -> {:halt, true}
        System.monotonic_time(:millisecond) > stop_at -> {:halt, false}
        true -> Process.sleep(10) && {:cont, false}
      end
    end)
  end
end
