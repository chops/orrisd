defmodule AiPair.IPC.ContractV3FixtureTest do
  @moduledoc """
  IPC version 3 identity core (NS-15.G.002 B1a-2; vendored `docs/contracts/ipc-v3.org`).

  PRODUCED: the 14 /core reply/ fixtures the consumer pairing block claims (orris f01631a7, after
  the NS-15.G.003 S3a and NS-32.M.001 RB-1 reciprocal pairings; the release-capable ping, and that
  ping with a build identity record, are among them) are each the reply the real dispatch path
  (`AiPair.IPC.DeliveryV3.dispatch/2`, or `AiPair.IPC.Delivery.dispatch/2` for the version 2
  refusals) gives for a prepared state, compared after the contract's placeholders are substituted.
  EXERCISED: the 2 /client request/ files are sent unchanged (placeholders substituted) and answer
  their paired reply. Examples are not claimed; no release-command request or reply file is
  exercised or compared here.

  BEHAVIOUR: identity is reported only for a live child whose registry id equals its committed
  record's id; every refusal of a v3 send leaves the receipt log, the queue and the paste recorder
  unchanged; reconcile absent/conflict need no child; status reports the CURRENT census pid or
  refuses; the commands run under the pane's Coordinator fence; other unknown version 2 commands
  keep "unknown command".
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @root Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)
  @text "fixture delivery input"
  @id "snd_" <> String.duplicate("a", 64)
  @hash "sha256:" <> Base.encode16(:crypto.hash(:sha256, @text), case: :lower)
  @reg "reg_" <> String.duplicate("3c", 16)
  @generation "213598703592091008239502170616955211460"
  @census_pid 4242

  # The 14 core replies the consumer's pairing block claims (orris f01631a7). Since the S3a
  # reciprocal pairing the paired ping is the release-capable one; since RB-1, that ping with a
  # read build identity record is claimed too. ping.ok.identity_core.json is an example (an
  # identity-core daemon without release) and is not produced here.
  @paired_claims ~w(
    ping.ok.identity_core_release.json ping.ok.identity_core_release_build.json
    send.sent.json send.queued.json
    status.ok.json status.quarantined.json status.error.pane_not_found.json
    reconcile.queued.json reconcile.delivered.json
    status.error.pane_identity_unavailable.json send.error.pane_identity_unavailable.json
    reconcile.error.pane_identity_unavailable.json
    v2_reply.subscribe.unsupported_command.json v2_reply.cancel.unsupported_command.json
  )

  setup do
    suffix = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ipc-v3-fixture-#{suffix}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, [inbox: inbox]})
    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
    pastes = start_supervised!({Agent, fn -> 0 end}, id: :pastes)
    records = start_supervised!({Agent, fn -> %{} end}, id: :records)
    census = start_supervised!({Agent, fn -> {:ok, @census_pid} end}, id: :census)

    {:ok,
     store: store,
     inbox: inbox,
     pane: "%fixture_v3_#{suffix}",
     pastes: pastes,
     records: records,
     census: census}
  end

  test "the paired-claim inventory is exactly the 14 core replies the consumer pairing block names" do
    assert length(@paired_claims) == 14
    assert Enum.all?(@paired_claims, &File.regular?(Path.join(@root, &1)))
  end

  # the 12 paired core replies the identity core produces through DeliveryV3 (the two version 2
  # refusals are produced by the rows below); the build ping is produced with the fixture's
  # record as the server's read build identity (context_for/2)
  for name <- ~w(
        ping.ok.identity_core_release.json ping.ok.identity_core_release_build.json
        send.sent.json send.queued.json
        status.ok.json status.quarantined.json status.error.pane_not_found.json
        reconcile.queued.json reconcile.delivered.json
        status.error.pane_identity_unavailable.json send.error.pane_identity_unavailable.json
        reconcile.error.pane_identity_unavailable.json
      ) do
    test "the identity core produces #{name}", c do
      name = unquote(name)
      request = prepare(name, c)
      assert normalized(v3_dispatch(request, context_for(name, c)), c) == fixture(name)
    end
  end

  for cmd <- ["cancel", "subscribe"] do
    test "the version 2 request for #{cmd} is exercised unchanged and answers its paired refusal",
         c do
      cmd = unquote(cmd)
      request = c |> substitute(fixture("v2_request.#{cmd}.json"))

      assert normalized(Delivery.dispatch(request, c.store), c) ==
               fixture("v2_reply.#{cmd}.unsupported_command.json")
    end
  end

  test "status at version 2 is refused unsupported_command; other unknown commands are unchanged",
       c do
    reply =
      Delivery.dispatch(%{"cmd" => "status", "protocol_version" => 2, "pane_id" => c.pane}, c.store)

    assert reply.error == "unsupported_command" and reply.cmd == "status" and
             reply.pane_id == c.pane

    for cmd <- ["reconsile", "attach_pane", "sessionz"] do
      assert Delivery.dispatch(%{"cmd" => cmd, "protocol_version" => 2}, c.store) ==
               %{ok: false, error: "unknown command", protocol_version: 2},
             cmd
    end
  end

  test "a legacy daemon's version 3 ping does not advertise pane_identity", c do
    reply = v3_dispatch(%{"cmd" => "ping", "protocol_version" => 3}, %{context(c) | durable: false})
    assert reply.capabilities == ["delivery_reconcile", "sessions_read"]
  end

  describe "a v3 send refused for identity has no effect" do
    for {label, setup} <- [
          {"a child with no registration", :nil_id},
          {"an uncommitted id (no record)", :no_record},
          {"a record holding another id", :mismatch},
          {"an unavailable intent store", :store_error},
          {"legacy mode", :legacy}
        ] do
      test "#{label}", c do
        ctx = identity_case(unquote(setup), c)
        before = receipts(c.inbox)
        {:ok, pid} = PaneSupervisor.whereis_pane(c.pane)
        depth = StateMachine.pending_count(pid)

        reply = v3_dispatch(send_request(c), ctx)

        assert reply.ok == false and reply.error == "pane_identity_unavailable"
        refute Map.has_key?(reply, :pane_identity)
        assert receipts(c.inbox) == before, "no receipt was admitted or changed"
        assert StateMachine.pending_count(pid) == depth, "nothing was queued"
        assert Agent.get(c.pastes, & &1) == 0, "nothing was pasted"
      end
    end
  end

  test "reconcile absent and conflict answer without identity, with no child and with an uncommitted id",
       c do
    other = "snd_" <> String.duplicate("b", 64)
    admit(c, other, "%elsewhere", @hash, "delivered")

    for with_child <- [false, true] do
      if with_child, do: start_pane(c, "IDLE_MARKER", registration_id: @reg)

      absent = v3_dispatch(reconcile_request(c), context(c))
      assert absent.ok and absent.outcome == "absent"
      refute Map.has_key?(absent, :pane_identity)

      conflict = v3_dispatch(%{reconcile_request(c) | "msg_id" => other}, context(c))
      assert conflict.ok and conflict.outcome == "conflict"
      refute Map.has_key?(conflict, :pane_identity)
      PaneSupervisor.stop_pane(c.pane)
    end
  end

  test "status reports the CURRENT census pid, never the record's, and refuses when the census cannot",
       c do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    commit(c, @reg, %{"pane_pid" => 1111})

    reply = v3_dispatch(status_request(c), context(c))
    assert reply.ok and reply.pane_pid == @census_pid

    Agent.update(c.census, fn _ -> :error end)
    refused = v3_dispatch(status_request(c), context(c))
    assert refused.ok == false and refused.error == "pane_identity_unavailable"
    refute Map.has_key?(refused, :pane_pid)
  end

  # The fence admits one holder per pane and REFUSES a contender before running its body; a v3
  # command that cannot hold it reports no identity.
  test "a v3 command runs only under the pane's Coordinator fence and refuses while another holds it",
       c do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    commit(c, @reg)
    parent = self()

    holder =
      spawn(fn ->
        Coordinator.transaction(c.pane, fn ->
          send(parent, :held)

          receive do
            :release -> {:ok, :released}
          after
            10_000 -> {:ok, :expired}
          end
        end)
      end)

    assert_receive :held, 5_000
    contended = v3_dispatch(status_request(c), context(c))
    assert contended.ok == false and contended.error == "pane_identity_unavailable"
    refute Map.has_key?(contended, :pane_identity)

    send_reply = v3_dispatch(send_request(c), context(c))
    assert send_reply.error == "pane_identity_unavailable"
    assert Agent.get(c.pastes, & &1) == 0

    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

    assert %{ok: true, pane_identity: %{registration_id: @reg}} =
             v3_dispatch(status_request(c), context(c))
  end

  # apply/3: AiPair.IPC.DeliveryV3 is GREEN's module, absent at the RED base.
  defp v3_dispatch(request, context),
    do: apply(AiPair.IPC.DeliveryV3, :dispatch, [request, context])

  # --- preparation ---------------------------------------------------------------------------

  defp prepare("ping.ok.identity_core_release" <> _, _c),
    do: %{"cmd" => "ping", "protocol_version" => 3}

  defp prepare("status." <> rest, c) do
    case rest do
      "ok.json" ->
        start_pane(c, "IDLE_MARKER", registration_id: @reg)
        commit(c, @reg)

      "quarantined.json" ->
        start_pane(c, "IDLE_MARKER", registration_id: @reg, quarantine_token: make_ref())
        commit(c, @reg)

      "error.pane_not_found.json" ->
        :ok

      "error.pane_identity_unavailable.json" ->
        start_pane(c, "IDLE_MARKER", registration_id: @reg)
    end

    status_request(c)
  end

  defp prepare("send." <> rest, c) do
    case rest do
      "sent.json" ->
        start_pane(c, "IDLE_MARKER", registration_id: @reg)
        commit(c, @reg)

      "queued.json" ->
        start_pane(c, "BUSY_MARKER", registration_id: @reg)
        commit(c, @reg)

      "error.pane_identity_unavailable.json" ->
        start_pane(c, "IDLE_MARKER", registration_id: @reg)
    end

    send_request(c)
  end

  defp prepare("reconcile." <> rest, c) do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)

    case rest do
      "error.pane_identity_unavailable.json" ->
        admit(c, @id, c.pane, @hash, "delivered")

      status ->
        commit(c, @reg)
        admit(c, @id, c.pane, @hash, String.trim_trailing(status, ".json"))
    end

    reconcile_request(c)
  end

  defp identity_case(:nil_id, c) do
    start_pane(c, "IDLE_MARKER", [])
    commit(c, nil)
    context(c)
  end

  defp identity_case(:no_record, c) do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    context(c)
  end

  defp identity_case(:mismatch, c) do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    commit(c, "reg_" <> String.duplicate("9", 32))
    context(c)
  end

  defp identity_case(:store_error, c) do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    %{context(c) | committed: fn _pane -> :error end}
  end

  defp identity_case(:legacy, c) do
    start_pane(c, "IDLE_MARKER", registration_id: @reg)
    commit(c, @reg)
    %{context(c) | durable: false}
  end

  # The build ping is the reply of a server that read this record at start (AiPair.BuildIdentity).
  defp context_for("ping.ok.identity_core_release_build.json" = name, c),
    do: Map.put(context(c), :build_identity, fixture(name)["build_identity"])

  defp context_for(_name, c), do: context(c)

  defp context(c) do
    %{
      receipt_store: c.store,
      durable: true,
      committed: fn pane ->
        case Agent.get(c.records, &Map.get(&1, pane)) do
          nil -> :none
          record -> {:ok, record}
        end
      end,
      current_pid: fn _pane -> Agent.get(c.census, & &1) end
    }
  end

  defp commit(c, registration_id, extra \\ %{}) do
    record = Map.merge(%{"registration_id" => registration_id, "session_gen" => @generation}, extra)
    Agent.update(c.records, &Map.put(&1, c.pane, record))
  end

  defp status_request(c), do: %{"cmd" => "status", "protocol_version" => 3, "pane_id" => c.pane}

  defp send_request(c),
    do: %{
      "cmd" => "send",
      "protocol_version" => 3,
      "msg_id" => @id,
      "pane_id" => c.pane,
      "text" => @text
    }

  defp reconcile_request(c) do
    %{
      "cmd" => "reconcile",
      "protocol_version" => 3,
      "msg_id" => @id,
      "pane_id" => c.pane,
      "payload_hash" => @hash,
      "wait_ms" => 0
    }
  end

  defp admit(c, id, pane, hash, status) do
    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id, pane, hash, self())

    if status != "pending", do: :ok = ReceiptStore.transition(c.store, id, token, status)
    true
  end

  defp start_pane(c, marker, opts) do
    {:ok, pid} =
      PaneSupervisor.start_pane(
        c.pane,
        opts ++
          [
            receipt_store: c.store,
            capture_fn: fn _ -> {:ok, marker} end,
            paste_fn: fn _, _ -> Agent.update(c.pastes, &(&1 + 1)) end,
            classifier: MarkerClassifier,
            poll_interval_ms: 5,
            idle_debounce_ms: 0
          ]
      )

    on_exit(fn -> PaneSupervisor.stop_pane(c.pane) end)
    expected = if marker == "IDLE_MARKER", do: :idle, else: :busy
    await_state(pid, expected, 100)
    true
  end

  defp await_state(_pid, _expected, 0), do: flunk("fixture pane did not classify")

  defp await_state(pid, expected, remaining) do
    if StateMachine.state(pid) != expected do
      Process.sleep(5)
      await_state(pid, expected, remaining - 1)
    end
  end

  defp receipts(inbox) do
    case File.read(Path.join([inbox, "delivery", "receipts.jsonl"])) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> ""
    end
  end

  defp fixture(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()

  # The contract's placeholders, substituted into a request read from a fixture.
  defp substitute(c, request) do
    Map.new(request, fn
      {"msg_id", "<msg_id>"} -> {"msg_id", @id}
      {"pane_id", "<pane_id>"} -> {"pane_id", c.pane}
      pair -> pair
    end)
  end

  # A reply with this run's values replaced by the contract's placeholders.
  defp normalized(reply, c) do
    reply
    |> Jason.encode!()
    |> Jason.decode!()
    |> placeholder("msg_id", @id, "<msg_id>")
    |> placeholder("pane_id", c.pane, "<pane_id>")
    |> placeholder("payload_hash", @hash, "<payload_hash>")
    |> placeholder("pong", AiPair.version(), "<version>")
    |> Map.update("pane_identity", nil, &identity_placeholders(&1, c))
    |> Map.reject(fn {key, value} -> key == "pane_identity" and value == nil end)
  end

  defp identity_placeholders(identity, c) do
    identity
    |> placeholder("pane_id", c.pane, "<pane_id>")
    |> placeholder("registration_id", @reg, "<registration_id>")
    |> placeholder("generation", @generation, "<generation>")
  end

  defp placeholder(map, key, exact, name) do
    if Map.get(map, key) == exact, do: Map.put(map, key, name), else: map
  end
end
