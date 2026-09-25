defmodule AiPair.NS15G002RefusalFindingsRedTest do
  @moduledoc """
  NS-15.G.002 refusal findings, RED rows (scope
  CLAUDE-ORRISD-NS15-G002-REFUSAL-FINDINGS-SCOPE-r1.org). This file carries RED-H4 only.

  H-4: an idle pane whose capture returns `{:error, :pane_gone}` stayed `:idle`, and so
  stayed send-eligible, until the reaper's threshold AND grace were both met
  (`state_machine.ex` `handle_pane_gone/3`, non-reap branch). A v2 send in that window
  reached `paste_receipted/5` and pasted to a pane the daemon had already observed gone.

  RED-H4 construction: pane `g` with its capture held in an Agent, `pane_gone_threshold: 2`,
  `pane_gone_grace_ms: 60_000` and debounce 0. After `g` is `:idle` the capture is switched
  to a function that sends `{:gone_captured, g}` to the test process and returns
  `{:error, :pane_gone}`. The capture runs inside the pane process, so once the test has
  received that message the handler for the capture completes before the next call to
  the pane is served. The named assertion is on the v2 send reply.

  Control: pane `h`, the identical option list, capture left IDLE: the same socket and
  store answer `sent` and paste once, so the harness reaches a paste and the RED row is
  not vacuous.

  Harness copied from ns42_c008_timeout_and_validation_test.exs (setup, frame helpers):
  a `ReceiptStore` on a unique inbox, a real `AiPair.IPC.Server` with that store, and a
  recording `paste_fn`. Pane ids are built at runtime.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns15_g002_red_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})

    start_supervised!(
      {Server, inbox: inbox, name: :"ns15_g002_red_server_#{n}", receipt_store: store}
    )

    # One Agent counts pastes per pane id.
    paste = start_supervised!({Agent, fn -> %{} end})

    {:ok, n: n, store: store, paste: paste, sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "RED-H4: a pane observed gone is not send-eligible while unreaped" do
    test "an idle pane whose capture returns pane_gone queues a v2 send instead of pasting",
         c do
      test_pid = self()
      g = pane_id(c, "g")
      assert ReceiptLog.valid_pane?(g)

      {:ok, capture} = Agent.start_link(fn -> fn _pane -> {:ok, "IDLE_MARKER"} end end)
      sm = start_pane!(c, g, capture)
      assert :ok = await_state(sm, :idle)

      # Precondition: the pane is idle before the switch.
      assert StateMachine.state(sm) == :idle

      Agent.update(capture, fn _ ->
        fn pane ->
          send(test_pid, {:gone_captured, pane})
          {:error, :pane_gone}
        end
      end)

      # Precondition: a pane_gone capture has run inside the pane process, and its
      # handler completes before the next call to the pane is served.
      assert_receive {:gone_captured, ^g}, 2_000

      id = id(c, "red-h4")
      text = "RED-H4 send after pane_gone " <> Integer.to_string(c.n)

      # Precondition: the fresh id has no record.
      assert reconcile!(c, g, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(g, id, text))

      assert reply["status"] == "queued",
             "H-4: a pane observed gone must not be pasted to while unreaped; " <>
               "observed status " <> inspect(reply["status"])
    end

    test "control: the identical pane with its capture left idle pastes once", c do
      h = pane_id(c, "h")
      assert ReceiptLog.valid_pane?(h)

      {:ok, capture} = Agent.start_link(fn -> fn _pane -> {:ok, "IDLE_MARKER"} end end)
      sm = start_pane!(c, h, capture)
      assert :ok = await_state(sm, :idle)
      assert StateMachine.state(sm) == :idle

      id = id(c, "red-h4-control")
      text = "RED-H4 control send " <> Integer.to_string(c.n)
      assert reconcile!(c, h, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(h, id, text))

      assert reply["status"] == "sent"
      assert pastes(c, h) == 1
    end
  end

  # ===== helpers =====

  defp pane_id(c, tag),
    do: "%" <> "ns15_g002_red_" <> Integer.to_string(c.n) <> "_" <> tag

  defp start_pane!(c, pane, capture) do
    paste = c.paste

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn pane_id -> Agent.get(capture, & &1).(pane_id) end,
        paste_fn: fn pane_id, _text ->
          Agent.update(paste, &Map.update(&1, pane_id, 1, fn count -> count + 1 end))
          :ok
        end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        pane_gone_threshold: 2,
        pane_gone_grace_ms: 60_000
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  defp pastes(c, pane), do: Agent.get(c.paste, &Map.get(&1, pane, 0))

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp send_frame(pane, id, text) do
    %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "text" => text
    }
  end

  defp reconcile!(c, pane, id, text) do
    send_frame!(c, %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "payload_hash" => hash(text),
      "wait_ms" => 0
    })
  end

  defp send_frame!(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
    end
  end

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
end
