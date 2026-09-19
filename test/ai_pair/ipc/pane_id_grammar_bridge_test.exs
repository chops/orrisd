defmodule AiPair.IPC.PaneIdGrammarBridgeTest do
  @moduledoc """
  The three pane-id grammars a listener bridging the daemon's surfaces meets,
  stated as rows that can fail rather than as a reading of three regexes.

  This is N-6 / T-23 of `phase0/mcp-threat-model.org` in the planning
  repository. That document's verdict on T-23 is PARTIAL, and its whole basis
  is a source reading of:

    * the v1 dispatch clauses, which guard only `is_binary(pane_id) and
      pane_id != ""` (`ipc/server.ex`, the `attach_pane` and `detach_pane`
      heads);
    * the v2 delivery grammar, `%` then 1..128 of `[a-zA-Z0-9_]`, held once in
      `AiPair.Delivery.ReceiptLog` and consulted by `AiPair.IPC.Delivery` for
      both the refusal and the echo;
    * the durable record grammar, `%` then one or more decimal digits, in
      `AiPair.PaneIntentStore.Record`, which
      `docs/contracts/durable-attach-detach.org` states as the rule for any
      request that may be recorded.

  `AiPair.Delivery.IPCIdentityGrammarTest` already pins the v2 grammar against
  itself and against storage. What no row covered is the RELATION between the
  three, which is the whole of the risk: the same bytes are a fact about a pane
  on one surface, a request error on another, and unstorable on the third.

  What these rows pin:

    * the three grammars really are three, ordered strictly by what they admit.
      Each containment is asserted WITH a witness that it is strict, so a
      future change collapsing two of them fails here;
    * one set of bytes, two protocol versions, two different answers: v1
      answers `pane_not_found` -- an assertion about a PANE -- for an id that
      v2 refuses as `invalid_pane_id` and that no store could ever have keyed;
    * a v1 `attach_pane` succeeds for an id the durable record layer refuses,
      so the daemon really does hold a live attachment it could not record.
      That is the bridging hazard, measured rather than inferred.

  Route containment: this file installs `AiPair.Test.RouteGuard` because it
  starts a real IPC server and attaches a pane through the product default
  path.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptLog
  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Delivery
  alias AiPair.PaneIntentStore.Record
  alias AiPair.Test.RouteGuard

  @root "/synthetic/inbox"
  @msg "snd_" <> String.duplicate("ab", 32)
  @hash "sha256:" <> String.duplicate("e5", 32)

  # Storable by the durable record layer, and therefore by all three.
  @recordable ["%1", "%0", "%99999"]

  # Accepted by the v2 delivery grammar and REFUSED by the record layer: the
  # everyday pane ids of this project's own suites are in here.
  @v2_only ["%pane_alpha", "%PaneAlpha9Z", "%a", "%" <> String.duplicate("a", 128)]

  # Accepted by the v1 dispatch clauses and refused by both the others.
  @v1_only ["%pane-alpha", "%pane.alpha", "pane_alpha", "%", "not a pane id at all"]

  setup do
    RouteGuard.install!()

    tmp = Path.join(System.tmp_dir!(), "ai_pair_bridge_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    store = start_supervised!({ReceiptStore, inbox: tmp})

    {:ok, inbox: tmp, sock_path: Path.join(tmp, "sock/ai-pair.sock"), store: store}
  end

  describe "the three grammars, ordered" do
    test "each corpus really sits where it is claimed to sit" do
      # ANTI-VACUITY for everything below: an empty or misfiled corpus would
      # make the containments trivially true.
      assert @recordable != [] and @v2_only != [] and @v1_only != []

      for pane <- @recordable do
        assert recordable?(pane), "#{inspect(pane)} is listed as recordable and is not"
        assert ReceiptLog.valid_pane?(pane)
        assert v1_accepts?(pane)
      end

      for pane <- @v2_only do
        refute recordable?(pane), "#{inspect(pane)} is listed as v2-only and the record took it"
        assert ReceiptLog.valid_pane?(pane)
        assert v1_accepts?(pane)
      end

      for pane <- @v1_only do
        refute recordable?(pane)
        refute ReceiptLog.valid_pane?(pane)
        assert v1_accepts?(pane), "#{inspect(pane)} is listed as v1-accepted and v1 refused it"
      end
    end

    test "record implies delivery implies v1, and both containments are strict" do
      for pane <- corpus() do
        if recordable?(pane) do
          assert ReceiptLog.valid_pane?(pane),
                 "#{inspect(pane)} is storable but the delivery grammar refuses it, so a " <>
                   "recorded pane could never be delivered to"
        end

        if ReceiptLog.valid_pane?(pane) do
          assert v1_accepts?(pane), "#{inspect(pane)} is deliverable but v1 dispatch refuses it"
        end
      end

      # STRICTNESS. Three grammars, not two and not one: each gap has a witness.
      assert Enum.any?(@v2_only, &(ReceiptLog.valid_pane?(&1) and not recordable?(&1))),
             "the delivery and record grammars have become the same grammar"

      assert Enum.any?(@v1_only, &(v1_accepts?(&1) and not ReceiptLog.valid_pane?(&1))),
             "the v1 dispatch clause and the delivery grammar have become the same grammar"
    end
  end

  describe "one set of bytes, two protocol versions" do
    test "v1 reports an absent PANE where v2 reports an invalid REQUEST", ctx do
      pid = start_server!(ctx, :ipc_bridge_versions)
      on_exit(fn -> stop_quietly(pid) end)

      for pane <- @v1_only do
        assert %{"ok" => false, "error" => "pane_not_found", "pane_id" => ^pane} =
                 wire(ctx.sock_path, %{"cmd" => "detach_pane", "pane_id" => pane}),
               "v1 answered about the PANE named #{inspect(pane)}, which is the finding: an " <>
                 "id no store could key is reported as an absence rather than as a request " <>
                 "the daemon cannot read"

        assert %{ok: false, error: "invalid_pane_id"} =
                 Delivery.dispatch(
                   %{
                     "cmd" => "reconcile",
                     "protocol_version" => 2,
                     "msg_id" => @msg,
                     "pane_id" => pane,
                     "payload_hash" => @hash,
                     "wait_ms" => 0
                   },
                   ctx.store
                 )
      end
    end
  end

  describe "a v1 attach the record layer could not have stored" do
    test "succeeds, and the same id is refused by Record.validate/2", ctx do
      pid = start_server!(ctx, :ipc_bridge_attach)
      on_exit(fn -> stop_quietly(pid) end)

      pane = "%pane_bridge_#{System.unique_integer([:positive])}"

      # The witness must be exactly the interesting kind: deliverable, not
      # storable. A witness outside the delivery grammar would prove something
      # weaker and a storable one would prove nothing at all.
      assert ReceiptLog.valid_pane?(pane)
      refute recordable?(pane)

      :ok = RouteGuard.own_pane(pane)

      assert %{"ok" => true, "pane_id" => ^pane, "started" => true} =
               wire(ctx.sock_path, %{"cmd" => "attach_pane", "pane_id" => pane})

      assert {:ok, _sm} = AiPair.PaneSupervisor.whereis_pane(pane),
             "the daemon holds a live attachment for a pane id it cannot record"

      assert {:error, {"pane_id", :malformed}} = Record.validate(record(pane), @root)

      # And the control: the identical record with a recordable id passes, so
      # the refusal above is about the pane id and not about the other twelve
      # keys.
      assert :ok = Record.validate(record("%1"), @root)
    end
  end

  # ===== helpers =====

  defp corpus, do: @recordable ++ @v2_only ++ @v1_only

  defp recordable?(pane), do: Record.validate(record(pane), @root) == :ok

  # The v1 dispatch guard, quoted: `is_binary(pane_id) and pane_id != ""`. It is
  # restated here rather than called because it guards a private clause head;
  # the wire rows above check the restatement against the real server.
  defp v1_accepts?(pane), do: is_binary(pane) and pane != ""

  defp start_server!(ctx, name) do
    {:ok, pid} =
      AiPair.IPC.Server.start_link(inbox: ctx.inbox, name: name, receipt_store: ctx.store)

    pid
  end

  defp record(pane) do
    values = %{
      "schema_version" => Record.version(),
      "pane_id" => pane,
      "agent" => "claude_code",
      "classifier" => "stub",
      "project" => "synthetic-project",
      "project_dir" => @root,
      "project_inbox" => @root,
      "tmux_session" => "synthetic",
      "session_gen" => "1",
      "cwd" => @root,
      "command" => "bash",
      "pane_pid" => 4321,
      "updated_at" => "2026-09-18T00:00:00Z"
    }

    assert Enum.sort(Record.record_keys()) == Enum.sort(Map.keys(values)),
           "the record key set changed; this fixture is no longer a valid record"

    values
  end

  defp wire(sock_path, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  # The listener closes its acceptor on the way down and answers `:shutdown`
  # rather than `:normal`; the sibling IPC suites take the same precaution.
  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
