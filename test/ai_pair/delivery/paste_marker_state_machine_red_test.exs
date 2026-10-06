defmodule AiPair.Delivery.PasteMarkerStateMachineRedTest do
  @moduledoc """
  NS-15.G.003 S0b (scope r2, RED design r3), pane level: a receipted send never reaches
  `paste_fn` without a durable version 2 `paste_started` record, a failed marker never
  pastes, and a crash between the marker and the paste never yields a second paste.

  Rows:

    * M1 immediate receipted send: when `paste_fn` runs, the marker is already on disk.
    * M2 the same on the queue-drain path.
    * M3 each of the four marker faults on an immediate send: no paste, a same-id resend in
      the same process pastes nothing, and after a restart a resend is a duplicate,
      ambiguous, with no paste. M3d-drain runs the fsync fault on the drain path.
    * M4 a failed paste after the marker ends ambiguous, never not_delivered.
    * M5 control: an unreceipted send pastes once and writes no receipt (unchanged).
    * M6 the test coordinator kills the pane and the store while `paste_fn` is blocked at
      entry (marker acknowledged, nothing pasted); after a restart nothing is pasted.
    * M6b the same with the kill after the paste was performed: exactly one paste.

  Every pane and store here is started unlinked and unsupervised, so the coordinator can kill
  both and see both go down without a supervisor restarting either.

  Expected at Orrisd 9faf41c3: every row except M5 fails, because `begin_paste` writes no
  marker and the writer writes version 1.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.{FaultFs, MarkerClassifier}

  @paste_deadline_ms 1_000

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "paste_marker_sm_" <> Integer.to_string(n))
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    performed = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :performed))
    seen = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :seen))
    screen = start_supervised!(Supervisor.child_spec({Agent, fn -> "IDLE_MARKER" end}, id: :screen))
    {:ok, n: n, inbox: inbox, performed: performed, seen: seen, screen: screen}
  end

  test "M1 an immediate receipted send pastes only after the marker is durable", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m1")
    sm = start_pane!(c, pane, store, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm, :idle)

    reply = Delivery.dispatch(send_frame(pane, id(c, "m1"), "m1 text"), store)

    assert reply.status == "sent"
    assert performed(c) == 1
    # RS3: this build writes version 3 records.
    assert seen(c) == [{id(c, "m1"), "paste_started", 3}]
    assert last_record(c) == {id(c, "m1"), "delivered", 3}
    stop_all([sm, store])
  end

  test "M2 a drained receipted send pastes only after the marker is durable", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m2")
    Agent.update(c.screen, fn _ -> "BUSY_MARKER" end)
    sm = start_pane!(c, pane, store, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm, :busy)

    reply = Delivery.dispatch(send_frame(pane, id(c, "m2"), "m2 text"), store)
    assert reply.status == "queued"
    Agent.update(c.screen, fn _ -> "IDLE_MARKER" end)

    assert eventually(fn -> performed(c) == 1 end, @paste_deadline_ms)
    assert seen(c) == [{id(c, "m2"), "paste_started", 3}]
    assert eventually(fn -> last_record(c) == {id(c, "m2"), "delivered", 3} end, @paste_deadline_ms)
    stop_all([sm, store])
  end

  faults = [
    {"write error", :write, {:error, :eio}},
    {"torn prefix", :write, {:torn, 8}},
    {"complete line then error", :write, :complete_line},
    {"fsync error", :sync, {:error, :eio}}
  ]

  for {label, op, fault} <- faults do
    test "M3 a failed marker never pastes, before or after a restart: #{label}", c do
      fs = FaultFs.new()
      store = start_store!(c, fs)
      pane = pane_id(c, "m3")
      msg = id(c, "m3")
      sm = start_pane!(c, pane, store, &observing_paste(c, &1, &2))
      assert :ok = await_state(sm, :idle)

      fault =
        case unquote(Macro.escape(fault)) do
          :complete_line -> torn_full(pane, msg, "m3 text")
          other -> other
        end

      inject_marker_fault!(fs, unquote(op), fault)

      assert %{ok: false, error: "receipt_store_unavailable"} =
               Delivery.dispatch(send_frame(pane, msg, "m3 text"), store)

      refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)

      # The poisoned store answers the same-id resend unavailable: it cannot finalize the
      # attempt, so it never claims an outcome and never pastes.
      assert %{ok: false, error: "receipt_store_unavailable"} =
               Delivery.dispatch(send_frame(pane, msg, "m3 text"), store)

      assert performed(c) == 0

      stop_all([sm, store])
      restarted = start_store!(c, SystemFs.new())
      sm2 = start_pane!(c, pane, restarted, &observing_paste(c, &1, &2))
      assert :ok = await_state(sm2, :idle)

      assert %{ok: true, duplicate: true, status: "ambiguous"} =
               Delivery.dispatch(send_frame(pane, msg, "m3 text"), restarted)

      refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
      assert performed(c) == 0
      assert seen(c) == []
      refute Enum.any?(records(c), &(&1["status"] == "not_delivered"))
      stop_all([sm2, restarted])
    end
  end

  test "M3d-drain a failed marker on the drain path never pastes", c do
    fs = FaultFs.new()
    store = start_store!(c, fs)
    pane = pane_id(c, "m3d")
    msg = id(c, "m3d")
    Agent.update(c.screen, fn _ -> "BUSY_MARKER" end)
    sm = start_pane!(c, pane, store, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm, :busy)

    assert %{status: "queued"} = Delivery.dispatch(send_frame(pane, msg, "m3d text"), store)
    inject_marker_fault!(fs, :sync, {:error, :eio})
    Agent.update(c.screen, fn _ -> "IDLE_MARKER" end)

    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)

    assert %{ok: false, error: "receipt_store_unavailable"} =
             Delivery.dispatch(send_frame(pane, msg, "m3d text"), store)

    stop_all([sm, store])
    restarted = start_store!(c, SystemFs.new())
    sm2 = start_pane!(c, pane, restarted, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm2, :idle)

    assert %{ok: true, duplicate: true, status: "ambiguous"} =
             Delivery.dispatch(send_frame(pane, msg, "m3d text"), restarted)

    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
    assert performed(c) == 0
    stop_all([sm2, restarted])
  end

  test "M4 a failed paste after the marker ends ambiguous, never not_delivered", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m4")

    sm =
      start_pane!(c, pane, store, fn p, t ->
        _ = observing_paste(c, p, t)
        {:error, :tmux_refused}
      end)

    assert :ok = await_state(sm, :idle)

    assert %{ok: false, error: "paste_failed"} =
             Delivery.dispatch(send_frame(pane, id(c, "m4"), "m4 text"), store)

    assert seen(c) == [{id(c, "m4"), "paste_started", 3}]

    assert Enum.map(records(c), &{&1["status"], &1["schema_version"]}) == [
             {"pending", 3},
             {"paste_started", 3},
             {"ambiguous", 3}
           ]

    stop_all([sm, store])
  end

  test "M5 control: an unreceipted send pastes once and writes no receipt", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m5")
    sm = start_pane!(c, pane, store, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm, :idle)

    assert :ok = StateMachine.send_text(sm, "m5 text")
    assert performed(c) == 1
    assert records(c) == []
    stop_all([sm, store])
  end

  test "M6 a crash between the durable marker and the paste never pastes", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m6")
    msg = id(c, "m6")
    coordinator = self()

    sm =
      start_pane!(c, pane, store, fn _p, _t ->
        send(coordinator, {:at_paste_entry, self(), last_record(c) == {msg, "paste_started", 3}})
        block()
      end)

    assert :ok = await_state(sm, :idle)
    spawn(fn -> Delivery.dispatch(send_frame(pane, msg, "m6 text"), store) end)

    assert_receive {:at_paste_entry, ^sm, marker_ok}, 2_000
    assert marker_ok, "paste_fn was entered without a durable paste_started record"
    kill_both!(sm, store)
    assert performed(c) == 0

    restarted = start_store!(c, SystemFs.new())

    assert Enum.map(records(c), &{&1["status"], &1["schema_version"]}) == [
             {"pending", 3},
             {"paste_started", 3},
             {"ambiguous", 3}
           ]

    sm2 = start_pane!(c, pane, restarted, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm2, :idle)

    assert %{ok: true, duplicate: true, status: "ambiguous"} =
             Delivery.dispatch(send_frame(pane, msg, "m6 text"), restarted)

    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
    assert performed(c) == 0
    stop_all([sm2, restarted])
  end

  test "M6b a crash after the paste but before delivered yields exactly one paste", c do
    store = start_store!(c, SystemFs.new())
    pane = pane_id(c, "m6b")
    msg = id(c, "m6b")
    coordinator = self()

    sm =
      start_pane!(c, pane, store, fn _p, _t ->
        Agent.update(c.performed, &(&1 + 1))
        send(coordinator, {:after_paste, self(), last_record(c) == {msg, "paste_started", 3}})
        block()
      end)

    assert :ok = await_state(sm, :idle)
    spawn(fn -> Delivery.dispatch(send_frame(pane, msg, "m6b text"), store) end)

    assert_receive {:after_paste, ^sm, marker_ok}, 2_000
    assert marker_ok, "paste_fn was entered without a durable paste_started record"
    kill_both!(sm, store)
    assert performed(c) == 1

    restarted = start_store!(c, SystemFs.new())

    assert Enum.map(records(c), &{&1["status"], &1["schema_version"]}) == [
             {"pending", 3},
             {"paste_started", 3},
             {"ambiguous", 3}
           ]

    sm2 = start_pane!(c, pane, restarted, &observing_paste(c, &1, &2))
    assert :ok = await_state(sm2, :idle)

    assert %{ok: true, duplicate: true, status: "ambiguous"} =
             Delivery.dispatch(send_frame(pane, msg, "m6b text"), restarted)

    refute eventually(fn -> performed(c) > 1 end, @paste_deadline_ms)
    assert performed(c) == 1
    stop_all([sm2, restarted])
  end

  # ===== helpers =====

  # The default spy: record what the receipt log held when paste_fn was entered, then paste.
  defp observing_paste(c, _pane, _text) do
    case List.last(records(c)) do
      nil ->
        :ok

      last ->
        Agent.update(
          c.seen,
          &(&1 ++ [{last["message_id"], last["status"], last["schema_version"]}])
        )
    end

    Agent.update(c.performed, &(&1 + 1))
    :ok
  end

  defp block do
    receive do
      :never_sent -> :ok
    end
  end

  defp kill_both!(sm, store) do
    refs = Enum.map([sm, store], &Process.monitor/1)
    Enum.each([sm, store], &Process.exit(&1, :kill))

    for ref <- refs do
      assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
    end
  end

  defp stop_all(pids), do: Enum.each(pids, &if(Process.alive?(&1), do: Process.exit(&1, :kill)))

  defp start_store!(c, fs) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: fs)
    pid
  end

  defp start_pane!(c, pane, store, paste_fn) do
    screen = c.screen

    opts = [
      pane_id: pane,
      name: PaneSupervisor.via_pane(pane),
      receipt_store: store,
      capture_fn: fn _pane -> {:ok, Agent.get(screen, & &1)} end,
      paste_fn: paste_fn,
      classifier: MarkerClassifier,
      poll_interval_ms: 5,
      idle_debounce_ms: 0
    ]

    assert {:ok, sm} = :gen_statem.start(PaneSupervisor.via_pane(pane), StateMachine, opts, [])
    on_exit(fn -> if Process.alive?(sm), do: Process.exit(sm, :kill) end)
    sm
  end

  defp inject_marker_fault!(fs, :sync, fault) do
    # The marker's fsync is the first sync after the marker write: fail every sync from the
    # moment that write lands, so no earlier record is affected.
    FaultFs.inject(
      fs,
      :write,
      &marker_write?/1,
      {:hook, fn -> FaultFs.inject(fs, :sync, FaultFs.count(fs, :sync) + 1, fault) end}
    )
  end

  defp inject_marker_fault!(fs, :write, fault),
    do: FaultFs.inject(fs, :write, &marker_write?/1, fault)

  # The complete-line fault needs the marker's exact length. Every field of the marker has a
  # fixed width here (seq 2, a sha256 link, a 24-hex epoch, a 64-hex id), so a record with
  # placeholder values of the same widths has the same length.
  defp torn_full(pane, msg, text) do
    record = %{
      "schema" => "ai-pair/delivery-receipt",
      # RS3: the marker is a version 3 record with the attempt's (null) pair.
      "schema_version" => 3,
      "seq" => 2,
      "prev_line_sha256" => "sha256:" <> String.duplicate("0", 64),
      "daemon_epoch" => "ep_" <> String.duplicate("0", 24),
      "message_id" => msg,
      "pane_id" => pane,
      "payload_hash" => Payload.hash(Payload.new(text)),
      "status" => "paste_started",
      "delivery_attempt" => 1,
      "registration_id" => nil,
      "generation" => nil
    }

    {:torn, byte_size(Jason.encode!(record) <> "\n")}
  end

  defp marker_write?([_fd, data]), do: IO.iodata_to_binary(data) =~ ~s("status":"paste_started")

  defp performed(c), do: Agent.get(c.performed, & &1)
  defp seen(c), do: Agent.get(c.seen, & &1)

  defp records(c) do
    path = Path.join([c.inbox, "delivery", "receipts.jsonl"])

    case File.read(path) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp last_record(c) do
    case List.last(records(c)) do
      nil -> nil
      last -> {last["message_id"], last["status"], last["schema_version"]}
    end
  end

  defp pane_id(c, tag), do: "%" <> "paste_marker_" <> Integer.to_string(c.n) <> "_" <> tag

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp send_frame(pane, id, text),
    do: %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "text" => text
    }

  defp await_state(sm, target, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        StateMachine.state(sm) == target -> :ok
        System.monotonic_time(:millisecond) > deadline -> {:timeout, StateMachine.state(sm)}
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end

  defp eventually(fun, deadline_ms) do
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
