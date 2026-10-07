defmodule AiPair.Delivery.ReceiptStoreGateTest do
  @moduledoc """
  NS-15.G.003 S3a: a gated delivery transaction is bound to the exact attempt it names.
  begin_command opens a transaction only for the receipt's own pane and attempt, after its
  durable paste_started and with its live token; any other gate is refused and the effect
  journal is byte-unchanged.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  @pane_a "%" <> "gate_a"
  @pane_b "%" <> "gate_b"

  setup do
    inbox = Path.join(System.tmp_dir!(), "store-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    {:ok, store} = GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new())
    on_exit(fn -> if Process.alive?(store), do: Process.exit(store, :kill) end)

    {:ok, inbox: inbox, store: store, journal: Path.join([inbox, "delivery", "effects.jsonl"])}
  end

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  defp started!(c, seed, pane \\ @pane_a) do
    hash = Payload.hash(Payload.new(seed <> " bytes"))

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id(seed), pane, hash, self())

    :ok = ReceiptStore.begin_paste(c.store, id(seed), token)
    token
  end

  defp gate(seed, pane, token, attempt \\ 1),
    do: %{pane: pane, msg_id: id(seed), attempt: attempt, token: token, buffer: "ai_pair_7"}

  defp journal(c) do
    case File.read(c.journal) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> ""
    end
  end

  test "G1 a valid token for pane A cannot open a transaction under pane B; under A it can", c do
    token = started!(c, "g1")
    before = journal(c)

    assert {:error, :gate_mismatch} =
             ReceiptStore.begin_command(c.store, gate("g1", @pane_b, token))

    assert {:error, :gate_mismatch} =
             ReceiptStore.begin_command(c.store, gate("g1", @pane_a, token, 2))

    assert journal(c) == before
    assert ReceiptStore.effect_status(c.store).unresolved == []

    assert {:ok, "mk_" <> _} = ReceiptStore.begin_command(c.store, gate("g1", @pane_a, token))
  end

  test "G2 a gate before the durable paste_started, or with a stale token, is refused", c do
    hash = Payload.hash(Payload.new("g2 bytes"))

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id("g2"), @pane_a, hash, self())

    before = journal(c)

    assert {:error, :gate_mismatch} =
             ReceiptStore.begin_command(c.store, gate("g2", @pane_a, token))

    :ok = ReceiptStore.begin_paste(c.store, id("g2"), token)
    assert {:error, _} = ReceiptStore.begin_command(c.store, gate("g2", @pane_a, make_ref()))
    assert journal(c) == before
  end

  # Through the Coordinator a second fence of a pane cannot be submitted while the first holds
  # the pane's lock, so fence_pending is measured here with this test as the issuer: one
  # outstanding fence request, then a second one.
  test "G3 a deferred fence: a second fence and any begin are fence_pending; one terminal reply",
       c do
    inbox = Path.join(c.inbox, "issuer")
    File.mkdir_p!(inbox)

    {:ok, store} =
      GenServer.start(ReceiptStore,
        inbox: inbox,
        fs: SystemFs.new(),
        restore_issuer: self(),
        fence_bound_ms: 300
      )

    on_exit(fn -> if Process.alive?(store), do: Process.exit(store, :kill) end)
    c = %{c | store: store}
    token = started!(c, "g3")
    assert {:ok, marker} = ReceiptStore.begin_command(store, gate("g3", @pane_a, token))

    # Elixir 1.20's GenServer has no send_request/2: the OTP request API is used directly
    first = :gen_server.send_request(store, {:fence_restore, @pane_a, make_ref()})
    assert {:error, :fence_pending} = ReceiptStore.fence_restore(store, @pane_a, make_ref())

    assert {:error, :fence_pending} =
             ReceiptStore.begin_command(store, gate("g3", @pane_a, token))

    assert {:reply, {:error, :command_in_flight}} = :gen_server.receive_response(first, 5_000)
    assert :timeout = :gen_server.receive_response(first, 100)

    assert :ok = ReceiptStore.end_command(store, marker, 0, nil)
    assert {:ok, _ref} = ReceiptStore.fence_restore(store, @pane_a, make_ref())
  end

  # The store spawns every gated step itself (run_step/4): only for the Tmux server that began
  # the marker, only while it is started, and never once the gate is poisoned, even for a
  # transaction STARTED before another pane's journal failure (scope r12, write failure).
  test "G4 run_step spawns only for the beginning caller, a started marker and an unpoisoned gate",
       c do
    inbox = Path.join(c.inbox, "fault")
    File.mkdir_p!(inbox)
    fs = FaultFs.new()

    FaultFs.inject(
      fs,
      :write,
      fn [_fd, data] ->
        line = IO.iodata_to_binary(data)
        String.contains?(line, "paste-effect") and String.contains?(line, "gate_b")
      end,
      {:error, :eio}
    )

    {:ok, store} = GenServer.start(ReceiptStore, inbox: inbox, fs: fs)
    on_exit(fn -> if Process.alive?(store), do: Process.exit(store, :kill) end)
    c = %{c | store: store}

    log = Path.join(inbox, "steps.log")
    File.write!(log, "")
    exe = Path.join(inbox, "step")
    File.write!(exe, "#!/usr/bin/env bash\nprintf 'step\\n' >> '#{log}'\nexit 3\n")
    File.chmod!(exe, 0o700)
    steps = fn -> log |> File.read!() |> String.split("\n", trim: true) |> length() end

    token_a = started!(c, "g4a")
    assert {:ok, marker} = ReceiptStore.begin_command(store, gate("g4a", @pane_a, token_a))

    other = Task.async(fn -> ReceiptStore.run_step(store, marker, exe, []) end)
    assert {:error, :not_gate_owner} = Task.await(other)
    assert {:error, :unknown_marker} = ReceiptStore.run_step(store, "mk_none", exe, [])
    assert steps.() == 0

    assert {:ok, 3} = ReceiptStore.run_step(store, marker, exe, [])
    assert steps.() == 1

    token_b = started!(c, "g4b", @pane_b)

    assert {:error, :effect_journal_unavailable} =
             ReceiptStore.begin_command(store, gate("g4b", @pane_b, token_b))

    assert ReceiptStore.effect_status(store).poisoned
    assert {:error, :effect_journal_unavailable} = ReceiptStore.run_step(store, marker, exe, [])
    assert steps.() == 1, "a poisoned gate spawns no later step of a STARTED transaction"
  end
end
