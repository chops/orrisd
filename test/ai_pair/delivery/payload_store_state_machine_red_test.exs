defmodule AiPair.Delivery.PayloadStoreStateMachineRedTest do
  @moduledoc """
  NS-15.G.003 S1 (scope r1, RED design r3), pane level: a v2 send that is queued has its
  payload object durable before its queued receipt; an immediate paste writes no object; a
  full or unusable payload store refuses the send with a typed v2 reply and no paste; a
  restart restores nothing (S1).

  Rows: Q1 queue then drain, Q2 the immediate path, Q3 payload_store_full, Q4
  payload_store_unavailable, Q5 restart control.

  Every pane and store here is started unlinked and unsupervised.

  Expected at Orrisd 413916b7: Q1, Q3, Q4 and Q5 fail (no payload object, no new refusal
  words); Q2 passes there and after (no object on the immediate path).
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @paste_deadline_ms 1_000

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "payload_sm_" <> Integer.to_string(n))
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    performed = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :performed))
    seen = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :seen))
    screen = start_supervised!(Supervisor.child_spec({Agent, fn -> "IDLE_MARKER" end}, id: :screen))
    {:ok, n: n, inbox: inbox, performed: performed, seen: seen, screen: screen}
  end

  test "Q1 a queued send's object is durable before its queued receipt and removed after delivery",
       c do
    store = start_store!(c)
    pane = pane_id(c, "q1")
    msg = id(c, "q1")
    text = "q1 queued text"
    busy(c)
    sm = start_pane!(c, pane, store)
    assert :ok = await_state(sm, :busy)

    assert %{status: "queued"} = Delivery.dispatch(send_frame(pane, msg, text), store)
    assert File.read!(object_path(c, msg, 1, text)) == text
    assert last_status(c, msg) == {"queued", 1}

    idle(c)
    assert eventually(fn -> performed(c) == 1 end, @paste_deadline_ms)
    assert eventually(fn -> last_status(c, msg) == {"delivered", 1} end, @paste_deadline_ms)
    assert eventually(fn -> not File.exists?(object_path(c, msg, 1, text)) end, @paste_deadline_ms)
    stop_all([sm, store])
  end

  test "Q2 control: an immediate paste writes no payload object", c do
    store = start_store!(c)
    pane = pane_id(c, "q2")
    msg = id(c, "q2")
    sm = start_pane!(c, pane, store)
    assert :ok = await_state(sm, :idle)

    assert %{status: "sent"} = Delivery.dispatch(send_frame(pane, msg, "q2 text"), store)
    assert performed(c) == 1
    assert payload_entries(c) == []
    stop_all([sm, store])
  end

  test "Q3 a full payload store refuses a queued send with payload_store_full and no paste", c do
    store = start_store!(c, payload_limit_objects: 0)
    pane = pane_id(c, "q3")
    msg = id(c, "q3")
    busy(c)
    sm = start_pane!(c, pane, store)
    assert :ok = await_state(sm, :busy)

    assert Delivery.dispatch(send_frame(pane, msg, "q3 text"), store) == %{
             ok: false,
             error: "payload_store_full",
             protocol_version: 2,
             msg_id: msg,
             pane_id: pane
           }

    idle(c)
    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
    assert last_status(c, msg) == {"not_delivered", 1}
    assert payload_entries(c) == []
    stop_all([sm, store])
  end

  test "Q4 an unusable payload directory refuses a queued send with payload_store_unavailable",
       c do
    elsewhere = Path.join(c.inbox, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.mkdir_p!(Path.join(c.inbox, "delivery"))
    :ok = File.ln_s(elsewhere, Path.join([c.inbox, "delivery", "payloads"]))

    store = start_store!(c)
    pane = pane_id(c, "q4")
    msg = id(c, "q4")
    busy(c)
    sm = start_pane!(c, pane, store)
    assert :ok = await_state(sm, :busy)

    assert Delivery.dispatch(send_frame(pane, msg, "q4 text"), store) == %{
             ok: false,
             error: "payload_store_unavailable",
             protocol_version: 2,
             msg_id: msg,
             pane_id: pane
           }

    idle(c)
    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
    assert last_status(c, msg) == {"not_delivered", 1}
    assert File.ls!(elsewhere) == []
    stop_all([sm, store])
  end

  test "Q5 a restart restores nothing: the queued send is ambiguous and its object removed", c do
    store = start_store!(c)
    pane = pane_id(c, "q5")
    msg = id(c, "q5")
    text = "q5 text"
    busy(c)
    sm = start_pane!(c, pane, store)
    assert :ok = await_state(sm, :busy)

    assert %{status: "queued"} = Delivery.dispatch(send_frame(pane, msg, text), store)
    assert File.exists?(object_path(c, msg, 1, text))
    stop_all([sm, store])

    # NS-15.G.003 S2: only an epoch attested in lineage.jsonl restores; without the file the
    # epoch is unattested, as every S1 epoch is (absent at S1, where nothing writes it).
    _ = File.rm(Path.join([c.inbox, "delivery", "lineage.jsonl"]))

    restarted = start_store!(c)
    idle(c)
    sm2 = start_pane!(c, pane, restarted)
    assert :ok = await_state(sm2, :idle)

    assert %{ok: true, duplicate: true, status: "ambiguous"} =
             Delivery.dispatch(send_frame(pane, msg, text), restarted)

    refute eventually(fn -> performed(c) > 0 end, @paste_deadline_ms)
    assert payload_entries(c) == []
    stop_all([sm2, restarted])
  end

  # ===== helpers =====

  defp start_store!(c, opts \\ []) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, [inbox: c.inbox, fs: SystemFs.new()] ++ opts)
    pid
  end

  defp start_pane!(c, pane, store) do
    screen = c.screen
    performed = c.performed

    opts = [
      pane_id: pane,
      name: PaneSupervisor.via_pane(pane),
      receipt_store: store,
      capture_fn: fn _pane -> {:ok, Agent.get(screen, & &1)} end,
      paste_fn: fn _pane, _text ->
        Agent.update(performed, &(&1 + 1))
        :ok
      end,
      classifier: MarkerClassifier,
      poll_interval_ms: 5,
      idle_debounce_ms: 0
    ]

    assert {:ok, sm} = :gen_statem.start(PaneSupervisor.via_pane(pane), StateMachine, opts, [])
    on_exit(fn -> if Process.alive?(sm), do: Process.exit(sm, :kill) end)
    sm
  end

  defp stop_all(pids) do
    refs = Enum.map(pids, &Process.monitor/1)
    Enum.each(pids, &if(Process.alive?(&1), do: Process.exit(&1, :kill)))
    Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _, _}, 2_000 end)
  end

  defp busy(c), do: Agent.update(c.screen, fn _ -> "BUSY_MARKER" end)
  defp idle(c), do: Agent.update(c.screen, fn _ -> "IDLE_MARKER" end)
  defp performed(c), do: Agent.get(c.performed, & &1)

  defp object_path(c, msg_id, attempt, text) do
    "sha256:" <> hex = Payload.hash(Payload.new(text))
    Path.join([c.inbox, "delivery", "payloads", "#{msg_id}.#{attempt}.#{hex}.payload"])
  end

  defp payload_entries(c) do
    case File.ls(Path.join([c.inbox, "delivery", "payloads"])) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  defp last_status(c, msg_id) do
    [c.inbox, "delivery", "receipts.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg_id))
    |> Enum.map(&{&1["status"], &1["delivery_attempt"]})
    |> List.last()
  end

  defp pane_id(c, tag), do: "%" <> "payload_sm_" <> Integer.to_string(c.n) <> "_" <> tag

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
