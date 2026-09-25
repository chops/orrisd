defmodule AiPair.Pane.StateMachineTest do
  use ExUnit.Case, async: true

  alias AiPair.Pane.StateMachine
  alias AiPair.Test.MarkerClassifier

  defp setup_pane(opts \\ []) do
    {:ok, capture_agent} = Agent.start_link(fn -> Keyword.get(opts, :initial_capture, "") end)
    {:ok, paste_agent} = Agent.start_link(fn -> [] end)

    capture_fn = fn _pane_id ->
      case Agent.get(capture_agent, & &1) do
        {:error, _} = err -> err
        bin when is_binary(bin) -> {:ok, bin}
      end
    end

    paste_fn = fn _pane_id, text ->
      Agent.update(paste_agent, &[text | &1])
      :ok
    end

    {:ok, sm} =
      StateMachine.start_link(
        Keyword.merge(
          [
            pane_id: "%test",
            capture_fn: capture_fn,
            paste_fn: paste_fn,
            classifier: MarkerClassifier,
            poll_interval_ms: 20,
            idle_debounce_ms: 80
          ],
          opts
        )
      )

    on_exit_stop(sm)
    {sm, capture_agent, paste_agent}
  end

  defp on_exit_stop(pid) do
    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          :gen_statem.stop(pid, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp set_capture(agent, value), do: Agent.update(agent, fn _ -> value end)

  defp pastes(agent), do: Agent.get(agent, &Enum.reverse(&1))

  defp wait_until_state(sm, target, deadline_ms \\ 1_000) do
    end_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> StateMachine.state(sm) end)
    |> Enum.reduce_while(:no, fn s, _ ->
      cond do
        s == target -> {:halt, :ok}
        System.monotonic_time(:millisecond) > end_at -> {:halt, {:timeout, s}}
        true -> Process.sleep(10) && {:cont, :no}
      end
    end)
  end

  test "starts in :unknown and transitions to :idle when classifier flips" do
    {sm, capture_agent, _paste_agent} = setup_pane()

    assert StateMachine.state(sm) == :unknown
    set_capture(capture_agent, "...IDLE_MARKER...")
    assert :ok = wait_until_state(sm, :idle)
  end

  test "transitions :idle -> :busy on capture change" do
    {sm, capture_agent, _paste_agent} = setup_pane(initial_capture: "IDLE_MARKER")
    assert :ok = wait_until_state(sm, :idle)

    set_capture(capture_agent, "BUSY_MARKER")
    assert :ok = wait_until_state(sm, :busy)
  end

  test "send_text in :busy is queued" do
    {sm, _capture_agent, paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
    assert :ok = wait_until_state(sm, :busy)

    assert {:queued, :busy} = StateMachine.send_text(sm, "hello")
    assert StateMachine.pending_count(sm) == 1
    assert pastes(paste_agent) == []
  end

  test "send_text in :dialog is queued" do
    {sm, _capture_agent, paste_agent} = setup_pane(initial_capture: "DIALOG_MARKER")
    assert :ok = wait_until_state(sm, :dialog)

    assert {:queued, :dialog} = StateMachine.send_text(sm, "hello")
    assert StateMachine.pending_count(sm) == 1
    assert pastes(paste_agent) == []
  end

  test "send_text in :idle before debounce is queued; drains after debounce" do
    {sm, _capture_agent, paste_agent} = setup_pane(initial_capture: "IDLE_MARKER")
    assert :ok = wait_until_state(sm, :idle)

    # Race: depending on scheduling, the debounce may or may not have elapsed
    # by the time we send. Do an immediate send and accept either outcome.
    case StateMachine.send_text(sm, "first") do
      :ok ->
        assert pastes(paste_agent) == ["first"]

      {:queued, :debounce} ->
        # Wait for debounce drain
        Process.sleep(150)
        assert pastes(paste_agent) == ["first"]
    end
  end

  test "queued sends from :busy drain when state returns to :idle" do
    {sm, capture_agent, paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
    assert :ok = wait_until_state(sm, :busy)

    assert {:queued, :busy} = StateMachine.send_text(sm, "queued-1")
    assert {:queued, :busy} = StateMachine.send_text(sm, "queued-2")

    set_capture(capture_agent, "IDLE_MARKER")
    assert :ok = wait_until_state(sm, :idle)

    Process.sleep(150)
    assert pastes(paste_agent) == ["queued-1", "queued-2"]
    assert StateMachine.pending_count(sm) == 0
  end

  test "pane_gone capture error transitions to :dead after threshold + grace" do
    {sm, capture_agent, _paste_agent} =
      setup_pane(initial_capture: "IDLE_MARKER", pane_gone_grace_ms: 30)

    assert :ok = wait_until_state(sm, :idle)

    set_capture(capture_agent, {:error, :pane_gone})
    assert :ok = wait_until_state(sm, :dead)
  end

  test "send_text in :dead returns error" do
    {sm, _capture_agent, _paste_agent} = setup_pane()
    StateMachine.mark_dead(sm)
    assert :ok = wait_until_state(sm, :dead)

    assert {:error, :pane_dead} = StateMachine.send_text(sm, "ignored")
  end

  test "a late poll cannot revive a dead pane or invoke capture" do
    capture_fn = fn _pane ->
      send(self(), :late_dead_capture)
      {:ok, "BUSY_MARKER"}
    end

    {:ok, :unknown, data, _actions} =
      StateMachine.init(pane_id: "%test", capture_fn: capture_fn, classifier: MarkerClassifier)

    # Deliver the named timer event directly: it must be harmless even if a
    # poll was already pending when mark_dead transitioned the live process.
    outcome = StateMachine.handle_event({:timeout, :poll}, nil, :dead, data)
    refute_received :late_dead_capture
    assert outcome == :keep_state_and_data
  end

  test "ANSI is stripped before classification" do
    ansi_busy = "\e[31m\e[1mBUSY_MARKER\e[0m"
    {sm, _capture_agent, _paste_agent} = setup_pane(initial_capture: ansi_busy)
    assert :ok = wait_until_state(sm, :busy)
  end

  test "content delta in :idle resets debounce so queued sends don't fire mid-stream" do
    # Simulates Codex CLI 0.128 mid-stream: fingerprint says :idle (the
    # `• Working` spinner is hidden once tokens flow) but content keeps
    # shifting. The state machine must keep the debounce window open
    # until content stabilizes.
    {sm, capture_agent, paste_agent} =
      setup_pane(initial_capture: "IDLE_MARKER frame-0", idle_debounce_ms: 80)

    assert :ok = wait_until_state(sm, :idle)

    # Mutate content faster than the debounce window. Each mutation must
    # reset idle_since_ms; the queued send must NOT drain.
    for i <- 1..6 do
      set_capture(capture_agent, "IDLE_MARKER frame-#{i}")
      Process.sleep(40)
    end

    case StateMachine.send_text(sm, "should-not-fire-mid-stream") do
      {:queued, :debounce} -> :ok
      :ok -> flunk("send fired mid-stream — content-stability gate did not hold")
    end

    # Streaming-equivalent: keep mutating across more debounce windows.
    for i <- 7..12 do
      set_capture(capture_agent, "IDLE_MARKER frame-#{i}")
      Process.sleep(40)
    end

    assert pastes(paste_agent) == [],
           "paste fired while content was still changing in :idle"

    # Now stop mutating; content stabilizes. Debounce should fire.
    Process.sleep(200)
    assert pastes(paste_agent) == ["should-not-fire-mid-stream"]
  end

  describe "paste failure handling" do
    test "immediate :idle paste failure returns {:error, {:paste_failed, reason}}" do
      {:ok, capture_agent} = Agent.start_link(fn -> "IDLE_MARKER" end)

      capture_fn = fn _pane_id ->
        case Agent.get(capture_agent, & &1) do
          {:error, _} = err -> err
          bin when is_binary(bin) -> {:ok, bin}
        end
      end

      paste_fn = fn _pane_id, _text -> {:error, :tmux_busted} end

      {:ok, sm} =
        StateMachine.start_link(
          pane_id: "%paste-fail",
          capture_fn: capture_fn,
          paste_fn: paste_fn,
          classifier: MarkerClassifier,
          poll_interval_ms: 20,
          idle_debounce_ms: 30
        )

      on_exit_stop(sm)
      assert :ok = wait_until_state(sm, :idle)
      Process.sleep(60)

      # Now the pane is idle and debounce has elapsed; this send goes
      # straight to the paste_fn synchronously and must surface the wrap.
      assert {:error, {:paste_failed, :tmux_busted}} = StateMachine.send_text(sm, "hello")
    end

    test "queued sends that fail to paste during drain are dropped, not retried forever" do
      {:ok, capture_agent} = Agent.start_link(fn -> "BUSY_MARKER" end)

      capture_fn = fn _pane_id ->
        case Agent.get(capture_agent, & &1) do
          {:error, _} = err -> err
          bin when is_binary(bin) -> {:ok, bin}
        end
      end

      {:ok, attempts_agent} = Agent.start_link(fn -> [] end)

      paste_fn = fn _pane_id, text ->
        Agent.update(attempts_agent, &[text | &1])
        {:error, :always_fails}
      end

      {:ok, sm} =
        StateMachine.start_link(
          pane_id: "%drain-drop",
          capture_fn: capture_fn,
          paste_fn: paste_fn,
          classifier: MarkerClassifier,
          poll_interval_ms: 20,
          idle_debounce_ms: 30
        )

      on_exit_stop(sm)
      assert :ok = wait_until_state(sm, :busy)

      assert {:queued, :busy} = StateMachine.send_text(sm, "drop-me-1")
      assert {:queued, :busy} = StateMachine.send_text(sm, "drop-me-2")
      assert StateMachine.pending_count(sm) == 2

      # Flip to idle. Drain runs after debounce; both pastes fail and must
      # be dropped — NOT requeued.
      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)

      Process.sleep(200)

      attempts = Agent.get(attempts_agent, &Enum.reverse(&1))
      assert attempts == ["drop-me-1", "drop-me-2"]
      assert StateMachine.pending_count(sm) == 0
    end
  end

  describe "queue cap" do
    test "send_text in :busy at cap returns {:error, {:queue_full, cap}}" do
      cap = StateMachine.max_pending_sends()
      {sm, _capture_agent, _paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy)

      for i <- 1..cap do
        assert {:queued, :busy} = StateMachine.send_text(sm, "fill-#{i}")
      end

      assert StateMachine.pending_count(sm) == cap

      # Cap reached: next send must be rejected, queue depth unchanged.
      assert {:error, {:queue_full, ^cap}} = StateMachine.send_text(sm, "rejected")
      assert StateMachine.pending_count(sm) == cap
    end

    test "send_text in :idle pre-debounce at cap returns {:error, {:queue_full, cap}}" do
      cap = StateMachine.max_pending_sends()

      # Long debounce so we stay pre-debounce while filling the queue.
      {sm, _capture_agent, _paste_agent} =
        setup_pane(initial_capture: "IDLE_MARKER", idle_debounce_ms: 60_000)

      assert :ok = wait_until_state(sm, :idle)

      for i <- 1..cap do
        assert {:queued, :debounce} = StateMachine.send_text(sm, "fill-#{i}")
      end

      assert StateMachine.pending_count(sm) == cap
      assert {:error, {:queue_full, ^cap}} = StateMachine.send_text(sm, "rejected")
      assert StateMachine.pending_count(sm) == cap
    end

    test "after a queued send drains, a previously-rejected send would now succeed" do
      cap = StateMachine.max_pending_sends()
      {sm, capture_agent, paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy)

      for i <- 1..cap do
        assert {:queued, :busy} = StateMachine.send_text(sm, "q-#{i}")
      end

      assert {:error, {:queue_full, ^cap}} = StateMachine.send_text(sm, "rejected-while-busy")

      # Flip to idle; queue drains, leaving room.
      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)
      Process.sleep(200)

      assert StateMachine.pending_count(sm) == 0
      assert length(pastes(paste_agent)) == cap
    end

    test "queue-full rejection emits [:ai_pair, :ipc, :send_rejected] telemetry" do
      cap = StateMachine.max_pending_sends()

      ref = make_ref()
      handler_id = {:send_rejected_test, ref}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ai_pair, :ipc, :send_rejected],
        fn _event, measurements, meta, _config ->
          send(test_pid, {:send_rejected, ref, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {sm, _capture_agent, _paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy)

      for i <- 1..cap do
        assert {:queued, :busy} = StateMachine.send_text(sm, "fill-#{i}")
      end

      assert {:error, {:queue_full, ^cap}} = StateMachine.send_text(sm, "rejected")

      assert_receive {:send_rejected, ^ref, %{count: 1, cap: ^cap},
                      %{reason: :queue_full, pane_id: "%test", from_state: :busy}},
                     500
    end
  end

  describe "pane_gone reaper" do
    test "non-pane capture error clears stale idle without advancing the reaper" do
      {sm, capture_agent, _paste_agent} =
        setup_pane(initial_capture: "IDLE_MARKER", pane_gone_grace_ms: 30)

      assert :ok = wait_until_state(sm, :idle)

      # Random transient error — must NOT cause a transition to :dead.
      set_capture(capture_agent, {:error, :random_failure})

      # Wait long enough that the reaper *would* have fired if this were
      # a :pane_gone error (grace=30ms, poll=20ms).
      Process.sleep(150)
      assert StateMachine.state(sm) == :unknown
    end

    test "capture failure preserves queued sends until a fresh idle observation" do
      {sm, capture_agent, paste_agent} = setup_pane(initial_capture: "BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy)
      assert {:queued, :busy} = StateMachine.send_text(sm, "retained message")
      set_capture(capture_agent, {:error, %{status: 124, stderr: "capture timeout"}})
      assert :ok = wait_until_state(sm, :unknown)
      assert Process.alive?(sm)
      assert StateMachine.pending_count(sm) == 1
      assert pastes(paste_agent) == []
      assert {:queued, :unknown} = StateMachine.send_text(sm, "second message")
      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)
      Process.sleep(150)
      assert StateMachine.pending_count(sm) == 0
      assert pastes(paste_agent) == ["retained message", "second message"]
    end

    test "recovery requires two matching captures even when debounce is shorter than polling" do
      {sm, capture_agent, paste_agent} =
        setup_pane(
          initial_capture: {:error, :random_failure},
          poll_interval_ms: 200,
          idle_debounce_ms: 10
        )

      assert :unknown = StateMachine.state(sm)
      assert {:queued, :unknown} = StateMachine.send_text(sm, "held message")
      set_capture(capture_agent, "IDLE_MARKER")
      Process.sleep(260)
      assert StateMachine.state(sm) == :unknown
      assert pastes(paste_agent) == []
      assert :ok = wait_until_state(sm, :idle)
      Process.sleep(40)
      assert pastes(paste_agent) == ["held message"]
    end

    test "capture failure cancels an idle debounce before queued delivery" do
      {sm, capture_agent, paste_agent} =
        setup_pane(initial_capture: "BUSY_MARKER", idle_debounce_ms: 300)

      assert :ok = wait_until_state(sm, :busy)
      assert {:queued, :busy} = StateMachine.send_text(sm, "wait for fresh evidence")
      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)
      set_capture(capture_agent, {:error, :random_failure})
      assert :ok = wait_until_state(sm, :unknown)
      Process.sleep(350)
      assert StateMachine.pending_count(sm) == 1
      assert pastes(paste_agent) == []
    end

    test "busy recovery accepts changing output without authorizing queued delivery" do
      {sm, _captures, paste_agent} = streaming_recovery_pane("BUSY_MARKER")
      assert :ok = wait_until_state(sm, :busy, 500)
      assert StateMachine.pending_count(sm) == 1
      assert pastes(paste_agent) == []
    end

    test "idle recovery still requires stable content while output changes" do
      {sm, _captures, paste_agent} = streaming_recovery_pane("IDLE_MARKER")
      Process.sleep(200)
      assert StateMachine.state(sm) == :unknown
      assert StateMachine.pending_count(sm) == 1
      assert pastes(paste_agent) == []
    end

    test "pane_gone with grace not yet elapsed does NOT reap" do
      {sm, capture_agent, _paste_agent} =
        setup_pane(initial_capture: "IDLE_MARKER", pane_gone_grace_ms: 5_000)

      assert :ok = wait_until_state(sm, :idle)

      set_capture(capture_agent, {:error, :pane_gone})

      # Several poll ticks worth, but well under the 5s grace. H-4: the first
      # :pane_gone revokes idle (to :unknown); the reaper still waits for grace.
      Process.sleep(150)
      assert StateMachine.state(sm) == :unknown
    end

    test "successful capture between pane_gone observations resets the reaper window" do
      {sm, capture_agent, _paste_agent} =
        setup_pane(initial_capture: "IDLE_MARKER", pane_gone_grace_ms: 100)

      assert :ok = wait_until_state(sm, :idle)

      # First pane_gone burst — accumulate some elapsed time but stop short
      # of the 100ms grace. H-4: the first :pane_gone revokes idle.
      set_capture(capture_agent, {:error, :pane_gone})
      Process.sleep(60)
      assert StateMachine.state(sm) == :unknown

      # Successful capture resets pane_gone_count + pane_gone_since_ms. H-4:
      # returning to :idle now takes two matching captures (recovery).
      set_capture(capture_agent, "IDLE_MARKER")
      Process.sleep(40)
      assert :ok = wait_until_state(sm, :idle)

      # Second pane_gone burst. If the counter had NOT reset, the cumulative
      # elapsed (60+40+ε) would have already exceeded grace and the next
      # pane_gone tick would reap immediately. Confirm we still need a
      # fresh grace window. H-4: not reaped, but no longer idle.
      set_capture(capture_agent, {:error, :pane_gone})
      Process.sleep(40)
      assert StateMachine.state(sm) == :unknown

      # And after the new grace window plus a poll tick, it does reap.
      assert :ok = wait_until_state(sm, :dead, 500)
    end

    test "fires [:ai_pair, :pane, :reaped] telemetry on reap" do
      ref = make_ref()
      handler_id = {:test_pane_reaped, ref}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ai_pair, :pane, :reaped],
        fn _event, measurements, meta, _config ->
          send(test_pid, {:reaped, ref, self(), measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {sm, capture_agent, _paste_agent} =
        setup_pane(
          initial_capture: "IDLE_MARKER",
          pane_gone_grace_ms: 30,
          agent: "claude_code",
          classifier_name: "fingerprint:claude_code"
        )

      assert :ok = wait_until_state(sm, :idle)

      set_capture(capture_agent, {:error, :pane_gone})
      assert :ok = wait_until_state(sm, :dead)

      :telemetry.execute([:ai_pair, :pane, :reaped], %{capture_count: 0}, %{pane_id: "%foreign"})
      assert_receive {:reaped, ^ref, ^sm, measurements, meta}, 500
      refute_receive {:reaped, ^ref, ^sm, _, _}, 10

      assert %{elapsed_ms: elapsed_ms, capture_count: capture_count, pending_count: 0} =
               measurements

      assert is_integer(elapsed_ms) and elapsed_ms >= 30
      assert is_integer(capture_count) and capture_count >= 2

      assert %{
               pane_id: "%test",
               agent: "claude_code",
               classifier_name: "fingerprint:claude_code",
               from_state: :unknown
             } = meta
    end
  end

  defp streaming_recovery_pane(marker) do
    {:ok, captures} = Agent.start_link(fn -> 0 end)

    capture_fn = fn _pane ->
      count = Agent.get_and_update(captures, &{&1, &1 + 1})
      if count == 0, do: {:error, :random_failure}, else: {:ok, "#{marker} #{count}"}
    end

    {sm, _unused, paste_agent} = setup_pane(capture_fn: capture_fn, idle_debounce_ms: 10)
    assert {:queued, _state} = StateMachine.send_text(sm, "held during recovery")
    {sm, captures, paste_agent}
  end

  describe "telemetry [:ai_pair, :classifier, :decision]" do
    setup do
      ref = make_ref()
      handler_id = {:test_classifier_decision, ref}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ai_pair, :classifier, :decision],
        fn _event, measurements, meta, _config ->
          send(test_pid, {:decision, ref, self(), measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "fires only on next != state, with full metadata", %{ref: ref} do
      {sm, capture_agent, _paste_agent} =
        setup_pane(agent: "claude_code", classifier_name: "fingerprint:claude_code")

      assert StateMachine.state(sm) == :unknown

      # No transition yet -> no event.
      refute_receive {:decision, ^ref, ^sm, _, _}, 50

      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)

      assert_receive {:decision, ^ref, ^sm, %{system_time: _}, meta}, 500

      assert %{
               pane_id: "%test",
               agent: "claude_code",
               classifier_name: "fingerprint:claude_code",
               from_state: :unknown,
               to_state: :idle
             } = meta
    end

    test "does NOT fire on content-stability rearm (next == state, content_changed)", %{ref: ref} do
      {sm, capture_agent, _paste_agent} =
        setup_pane(initial_capture: "IDLE_MARKER frame-0", idle_debounce_ms: 80)

      assert :ok = wait_until_state(sm, :idle)

      # Drain the :unknown -> :idle transition event we expect.
      assert_receive {:decision, ^ref, ^sm, _, %{to_state: :idle}}, 500

      # Mutate content while staying in :idle. This rearms the debounce
      # but is not a state transition; no decision events should fire.
      for i <- 1..6 do
        set_capture(capture_agent, "IDLE_MARKER frame-#{i}")
        Process.sleep(40)
      end

      :telemetry.execute([:ai_pair, :classifier, :decision], %{system_time: 0}, %{
        pane_id: "%foreign",
        from_state: :unknown,
        to_state: :busy
      })

      refute_receive {:decision, ^ref, ^sm, _, _}, 50
    end
  end

  describe "get_info/1" do
    test "returns nil agent and classifier_name when not provided" do
      {sm, _capture_agent, _paste_agent} = setup_pane()

      assert %{agent: nil, classifier_name: nil, state: state} = StateMachine.get_info(sm)
      assert state in ~w(idle busy dialog dead unknown)a
    end

    test "echoes agent and classifier_name supplied at start_link" do
      {sm, capture_agent, _paste_agent} =
        setup_pane(agent: "claude_code", classifier_name: "fingerprint:claude_code")

      assert %{agent: "claude_code", classifier_name: "fingerprint:claude_code", state: :unknown} =
               StateMachine.get_info(sm)

      set_capture(capture_agent, "IDLE_MARKER")
      assert :ok = wait_until_state(sm, :idle)

      assert %{agent: "claude_code", classifier_name: "fingerprint:claude_code", state: :idle} =
               StateMachine.get_info(sm)
    end
  end
end
