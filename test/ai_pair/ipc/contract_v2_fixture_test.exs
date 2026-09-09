defmodule AiPair.IPC.ContractV2FixtureTest do
  use ExUnit.Case, async: false
  import AiPair.Test.OtelHelper

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Delivery
  alias AiPair.IPC.Server
  alias AiPair.CLI.Client
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @root Path.expand("../../fixtures/contracts/ipc/v2", __DIR__)
  @text "fixture delivery input"
  @id "snd_" <> String.duplicate("a", 64)
  @hash "sha256:" <> Base.encode16(:crypto.hash(:sha256, @text), case: :lower)

  setup do
    suffix = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ipc-fixture-#{suffix}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    pastes = start_supervised!({Agent, fn -> 0 end})
    {:ok, store: store, pane: "%fixture_#{suffix}", inbox: inbox, pastes: pastes}
  end

  test "CLI versioned stdin send deduplicates and reconciles through the real socket", c do
    File.mkdir_p!(Path.join(c.inbox, "sock"))

    start_supervised!(
      {Server, inbox: c.inbox, name: :versioned_cli_fixture, receipt_store: c.store}
    )

    setup_otel_capture()
    previous = System.get_env("AI_PAIR_DAEMON_SOCK")
    System.put_env("AI_PAIR_DAEMON_SOCK", Path.join(c.inbox, "sock/ai-pair.sock"))

    on_exit(fn ->
      if previous,
        do: System.put_env("AI_PAIR_DAEMON_SOCK", previous),
        else: System.delete_env("AI_PAIR_DAEMON_SOCK")
    end)

    start_pane(c, "IDLE_MARKER")

    ping =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Client.main(["ping", "--protocol-version", "2"]) == 0
      end)

    assert Jason.decode!(ping)["capabilities"] == ["delivery_reconcile"]
    args = ["send", c.pane, "--stdin", "--msg-id", @id, "--protocol-version", "2"]

    first =
      ExUnit.CaptureIO.capture_io(@text, fn -> assert Client.main(args) == 0 end) |> Jason.decode!()

    assert first["status"] == "sent"
    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")
    assert trace_id(cli_span) == trace_id(ipc_span)
    assert trace_id(cli_span) == trace_id(paste_span)
    assert parent_span_id(ipc_span) == span_id(cli_span)
    assert parent_span_id(paste_span) == span_id(ipc_span)
    assert span_attrs(ipc_span)["ipc.protocol_version"] == 2
    refute inspect(span_attrs(ipc_span)) =~ @text

    second =
      ExUnit.CaptureIO.capture_io(@text, fn -> assert Client.main(args) == 0 end) |> Jason.decode!()

    assert second["duplicate"] == true
    assert second["status"] == "delivered"
    assert Agent.get(c.pastes, & &1) == 1

    query = [
      "reconcile",
      c.pane,
      "--msg-id",
      @id,
      "--payload-hash",
      @hash,
      "--protocol-version",
      "2"
    ]

    result =
      ExUnit.CaptureIO.capture_io(fn -> assert Client.main(query) == 0 end) |> Jason.decode!()

    assert result["outcome"] == "delivered"
    assert result["delivery_attempt"] == 1
    assert {:ok, _span} = assert_span(name: "ipc.reconcile")
  end

  for path <- @root |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() do
    name = Path.basename(path)

    test "runtime producer matches #{name}", c do
      name = unquote(name)
      request = prepare(name, c)
      actual = Delivery.dispatch(request, c.store) |> Jason.encode!() |> Jason.decode!()
      expected = @root |> Path.join(name) |> File.read!() |> Jason.decode!()

      actual =
        actual
        |> normalize("msg_id", @id, "<msg_id>")
        |> normalize("pane_id", c.pane, "<pane_id>")
        |> normalize("payload_hash", @hash, "<payload_hash>")
        |> normalize("pong", AiPair.version(), "<version>")

      assert actual == expected
      refute Map.has_key?(actual, "text")
    end
  end

  defp prepare("ping.ok.json", _c), do: %{"cmd" => "ping", "protocol_version" => 2}

  defp prepare("send." <> rest, c) do
    start_pane(c, if(rest == "sent.json", do: "IDLE_MARKER", else: "BUSY_MARKER"))

    request = %{
      "cmd" => "send",
      "protocol_version" => 2,
      "msg_id" => @id,
      "pane_id" => c.pane,
      "text" => @text
    }

    case rest do
      "sent.json" ->
        request

      "queued.json" ->
        request

      "error.missing_msg_id.json" ->
        Map.delete(request, "msg_id")

      "error.conflict.json" ->
        admit(c, c.pane, "sha256:" <> String.duplicate("f", 64), "delivered")
        request

      "duplicate." <> status ->
        admit(c, c.pane, @hash, String.trim_trailing(status, ".json"))
        request
    end
  end

  defp prepare("reconcile." <> rest, c) do
    request = %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "msg_id" => @id,
      "pane_id" => c.pane,
      "payload_hash" => @hash,
      "wait_ms" => 0
    }

    case rest do
      "absent.json" ->
        request

      "error.missing_payload_hash.json" ->
        Map.delete(request, "payload_hash")

      "conflict.json" ->
        admit(c, "%different", @hash, "delivered")
        request

      "absent.not_delivered.json" ->
        admit(c, c.pane, @hash, "not_delivered")
        request

      name when name in ["ambiguous.json", "delivered.json", "queued.json"] ->
        admit(c, c.pane, @hash, String.trim_trailing(name, ".json"))
        request
    end
  end

  defp admit(c, pane, hash, status) do
    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, @id, pane, hash, self())

    if status != "pending", do: :ok = ReceiptStore.transition(c.store, @id, token, status)
  end

  defp start_pane(c, marker) do
    {:ok, pid} =
      PaneSupervisor.start_pane(c.pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, marker} end,
        paste_fn: fn _, _ -> Agent.update(c.pastes, &(&1 + 1)) end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(c.pane) end)
    expected = if marker == "IDLE_MARKER", do: :idle, else: :busy
    await_state(pid, expected, 100)
  end

  defp await_state(_pid, _expected, 0), do: flunk("fixture pane did not classify")

  defp await_state(pid, expected, remaining) do
    if StateMachine.state(pid) != expected do
      Process.sleep(5)
      await_state(pid, expected, remaining - 1)
    end
  end

  defp normalize(map, key, exact, placeholder) do
    if Map.get(map, key) == exact, do: Map.put(map, key, placeholder), else: map
  end
end
