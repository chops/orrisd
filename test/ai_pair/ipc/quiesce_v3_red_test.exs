defmodule AiPair.IPC.QuiesceV3RedTest.ManualTimer do
  @moduledoc false
  # A timer that never fires by itself: each arm is reported to the test process, which
  # delivers the timeout message explicitly (RB-3a producer scope r3, A3; used here for A10).
  def arm(dest, ms, message) do
    ref = make_ref()
    send(:persistent_term.get({__MODULE__, :test}), {:armed, ref, dest, ms, message})
    ref
  end

  def cancel(_ref), do: :ok
end

defmodule AiPair.IPC.QuiesceV3RedTest do
  @moduledoc """
  NS-32.M.002 RB-3a RED, rows A8 to A15 (producer RED scope r3; vendored ipc-v3.org "Quiesce",
  ipc-v2.org and ipc-v1.org "next paired" quiescing refusals). The version 3 dispatch answers
  quiesce and resume through the server's AiPair.Admission; every admission path refuses while a
  fence is held, in each protocol version's own shape; ping advertises quiesce in durable mode and
  carries quiesced and fence_id only while a fence is held.

  API pinned here (GREEN; apply/3 at RED):
    * the DeliveryV3 context key :admission and the IPC server option :admission;
    * AiPair.Admission.Observer.observe/1 over a sources map with :receipt_store,
      :pane_intent_store and :marker (a 0-arity function returning {:ok, version} or :error),
      and optional per-dimension read overrides :effects, :lineage and :payloads (0-arity
      functions; the defaults read the receipt store, which owns the effect journal, the lineage
      and the payload store). It returns {:ok, observation} or {:error, dimension}, the dimensions
      checked in the order receipts, pane_intent, effects, lineage, payloads, session_marker;
    * the observation values: receipts versions = the schema versions present in the receipt
      log, queued and pending = receipt counts by status; pane_intent version =
      PaneIntentStore.Record.version(), live_panes = committed pane-intent records; effects
      version = EffectJournal.version(), unresolved_holds = panes with an unresolved effect;
      lineage version = Lineage.schema_version(), attested = the store's attestation result;
      payloads layouts = [1] when any payload file exists, else []; session_marker version = the
      marker reader's version.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{EffectJournal, Lineage, Payload, ReceiptStore}
  alias AiPair.IPC.{Delivery, DeliveryV3}
  alias AiPair.IPC.QuiesceV3RedTest.ManualTimer

  @root Path.expand("../../fixtures/contracts/ipc/v3", __DIR__)
  @text "rb3a wire row"
  @guard_ms 5_000
  @observation_keys ~w(effects lineage pane_intent payloads receipts session_marker)
  @intent_pane "%1"

  setup do
    :persistent_term.put({ManualTimer, :test}, self())
    on_exit(fn -> :persistent_term.erase({ManualTimer, :test}) end)
    n = System.unique_integer([:positive])
    inbox = Path.join(canonical_tmp(), "rb3a-wire-#{n}")
    File.mkdir_p!(inbox)
    File.chmod!(inbox, 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    pis = start_supervised!({AiPair.PaneIntentStore, root: inbox})
    secret = :crypto.strong_rand_bytes(32)

    {:ok,
     n: n,
     inbox: inbox,
     store: store,
     pis: pis,
     pane: "%rb3a_wire_#{n}",
     secret_hex: Base.encode16(secret, case: :lower),
     hash: "sha256:" <> Base.encode16(:crypto.hash(:sha256, secret), case: :lower)}
  end

  defp observer(c, overrides \\ %{}) do
    sources =
      Map.merge(
        %{receipt_store: c.store, pane_intent_store: c.pis, marker: fn -> {:ok, 1} end},
        overrides
      )

    fn -> apply(AiPair.Admission.Observer, :observe, [sources]) end
  end

  defp admission(c, opts \\ []) do
    defaults = [bound_ms: 60_000, receipt_store: c.store, observe: observer(c)]
    {:ok, pid} = apply(AiPair.Admission, :start_link, [Keyword.merge(defaults, opts)])
    pid
  end

  defp context(c, admission) do
    %{
      receipt_store: c.store,
      durable: true,
      admission: admission,
      committed: fn _pane -> :none end,
      current_pid: fn _pane -> {:ok, 4242} end
    }
  end

  defp v3(request, context), do: apply(DeliveryV3, :dispatch, [request, context])

  defp quiesce(c, adm) do
    request = %{"cmd" => "quiesce", "protocol_version" => 3, "resume_hash" => c.hash}
    v3(request, context(c, adm))
  end

  defp fixture(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()

  # decode, then replace the dynamic values by the contract's placeholders
  defp normalized(reply, c, fence_id \\ nil) do
    json = Jason.encode!(reply)
    json = if fence_id, do: String.replace(json, fence_id, "<fence_id>"), else: json

    json
    |> String.replace(c.pane, "<pane_id>")
    |> String.replace(~r/snd_[0-9a-f]{64}/, "<msg_id>")
    |> Jason.decode!()
  end

  defp id, do: "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp admit(c, id, pane) do
    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id, pane, Payload.hash(Payload.new(@text)), self())

    token
  end

  # a committed pane-intent record (the store's own record shape, as pane_intent_store_test.exs)
  defp intent_record(root) do
    %{
      "schema_version" => "2.0",
      "registration_id" => "reg_" <> String.duplicate("ab", 16),
      "pane_id" => @intent_pane,
      "agent" => "claude_code",
      "classifier" => "fingerprint:claude_code",
      "project" => "demo",
      "project_dir" => "/workspace/demo",
      "project_inbox" => root,
      "tmux_session" => "ai-pair/demo",
      "session_gen" => "2",
      "cwd" => "/workspace/demo",
      "command" => "claude",
      "pane_pid" => 4242,
      "updated_at" => "2026-10-07T00:00:00Z"
    }
  end

  # a pid proven dead before dispatch (its :DOWN is received), never a still-live one
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @guard_ms
    refute Process.alive?(pid)
    pid
  end

  defp file_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> :absent
    end
  end

  test "A8 quiesce answers a fence id and exactly the six-key observation of data-bearing state",
       c do
    # one queued receipt with its payload, one pending receipt, one committed pane intent
    queued_id = id()
    token = admit(c, queued_id, c.pane)
    :ok = ReceiptStore.queue(c.store, queued_id, token, @text)
    _pending = admit(c, id(), c.pane)
    :ok = AiPair.PaneIntentStore.put(c.pis, intent_record(c.inbox))

    reply = quiesce(c, admission(c))
    assert %{ok: true, quiesced: true, fence_id: fence_id, observation: obs} = reply
    assert fence_id =~ ~r/\Afence_[0-9a-f]{32}\z/
    assert Enum.sort(Map.keys(obs)) == @observation_keys

    assert obs == %{
             "receipts" => %{"versions" => [3], "queued" => 1, "pending" => 1},
             "pane_intent" => %{
               "version" => AiPair.PaneIntentStore.Record.version(),
               "live_panes" => 1
             },
             "effects" => %{"version" => EffectJournal.version(), "unresolved_holds" => 0},
             "lineage" => %{"version" => Lineage.schema_version(), "attested" => true},
             "payloads" => %{"layouts" => [1]},
             "session_marker" => %{"version" => 1}
           }

    # every version is one this build declares it reads (AiPair.Compat.reads/0)
    reads = AiPair.Compat.reads()
    assert obs["receipts"]["versions"] -- reads["receipts"] == []
    assert obs["pane_intent"]["version"] in reads["pane_intent"]
    assert [obs["effects"]["version"]] == reads["effects"]
    assert [obs["lineage"]["version"]] == reads["lineage"]
    assert obs["payloads"]["layouts"] -- reads["payloads"] == []

    # the wire shape: the vendored example's keys at every level
    normalized = normalized(reply, c, fence_id)
    expected = fixture("quiesce.ok.json")
    assert Enum.sort(Map.keys(normalized)) == Enum.sort(Map.keys(expected))

    for key <- @observation_keys do
      assert Enum.sort(Map.keys(normalized["observation"][key])) ==
               Enum.sort(Map.keys(expected["observation"][key])),
             key
    end
  end

  # three real-owner failures and three per-dimension read failures: every dimension is named
  for {label, override, dimension} <- [
        {"a dead receipt store", :dead_store, "receipts"},
        {"a dead pane-intent store", :dead_pis, "pane_intent"},
        {"a failing effect journal read", :effects, "effects"},
        {"a failing lineage read", :lineage, "lineage"},
        {"a failing payload store read", :payloads, "payloads"},
        {"a failing marker reader", :marker_error, "session_marker"}
      ] do
    test "A9 #{label} gives observation_incomplete naming #{dimension}, admission reopened", c do
      override =
        case unquote(override) do
          :dead_store -> %{receipt_store: dead_pid()}
          :dead_pis -> %{pane_intent_store: dead_pid()}
          :marker_error -> %{marker: fn -> :error end}
          dim -> %{dim => fn -> :error end}
        end

      adm = admission(c, observe: observer(c, override))
      reply = quiesce(c, adm)

      assert normalized(reply, c) ==
               Map.put(
                 fixture("quiesce.error.observation_incomplete.json"),
                 "dimension",
                 unquote(dimension)
               )

      assert apply(AiPair.Admission, :fence, [adm]) == nil
      assert {:ok, ticket} = apply(AiPair.Admission, :enter, [adm, :ipc_send])
      assert apply(AiPair.Admission, :exit, [adm, ticket]) == :ok
    end
  end

  test "A10 the quiesce and resume replies have the vendored example shapes", c do
    adm = admission(c)
    request = Map.put(fixture("v3_request.quiesce.json"), "resume_hash", c.hash)
    ok = v3(request, context(c, adm))
    fence_id = ok.fence_id

    assert normalized(v3(request, context(c, adm)), c) ==
             fixture("quiesce.error.quiesce_busy.json")

    assert normalized(v3(Map.delete(request, "resume_hash"), context(c, admission(c))), c) ==
             fixture("quiesce.error.invalid_request.json")

    resume = fixture("v3_request.resume.json")
    wrong = %{resume | "fence_id" => fence_id, "resume_secret" => String.duplicate("0", 64)}
    assert normalized(v3(wrong, context(c, adm)), c) == fixture("resume.error.fence_mismatch.json")

    right = %{resume | "fence_id" => fence_id, "resume_secret" => c.secret_hex}
    assert normalized(v3(right, context(c, adm)), c) == fixture("resume.ok.json")
  end

  test "A10 quiesce_timeout carries the bound, under the injected timer and an explicit trigger",
       c do
    adm = admission(c, bound_ms: 4_321, timer: ManualTimer)
    {:ok, held} = apply(AiPair.Admission, :enter, [adm, :ipc_send])
    task = Task.async(fn -> quiesce(c, adm) end)

    assert_receive {:armed, _ref, dest, 4_321, message}, @guard_ms
    assert Task.yield(task, 0) == nil
    send(dest, message)

    assert normalized(Task.await(task, @guard_ms), c) ==
             Map.put(fixture("quiesce.error.quiesce_timeout.json"), "bound_ms", 4_321)

    assert apply(AiPair.Admission, :exit, [adm, held]) == :ok
  end

  test "A11 version 3 send and release are refused quiescing while a fence is held", c do
    adm = admission(c)
    %{ok: true} = quiesce(c, adm)

    send = %{
      "cmd" => "send",
      "protocol_version" => 3,
      "msg_id" => id(),
      "pane_id" => c.pane,
      "text" => @text
    }

    assert normalized(v3(send, context(c, adm)), c) == fixture("send.error.quiescing.json")

    release = %{"cmd" => "release", "protocol_version" => 3, "pane_id" => c.pane}
    assert normalized(v3(release, context(c, adm)), c) == fixture("release.error.quiescing.json")
  end

  test "A12 a version 2 send is refused quiescing and never changes an existing receipt", c do
    adm = admission(c)
    existing = id()
    hash = Payload.hash(Payload.new(@text))
    token = admit(c, existing, c.pane)
    :ok = ReceiptStore.queue(c.store, existing, token, @text)
    {:ok, before} = ReceiptStore.reconcile(c.store, existing, c.pane, hash, wait_ms: 0)
    %{ok: true, fence_id: fence_id} = quiesce(c, adm)

    v2 = %{
      "cmd" => "send",
      "protocol_version" => 2,
      "msg_id" => existing,
      "pane_id" => c.pane,
      "text" => @text
    }

    reply = apply(Delivery, :dispatch, [v2, c.store, %{admission: adm}])
    assert normalized(reply, c) == fixture("v2_reply.send.quiescing.json")

    assert :ok = apply(AiPair.Admission, :resume, [adm, fence_id, c.secret_hex])
    assert {:ok, ^before} = ReceiptStore.reconcile(c.store, existing, c.pane, hash, wait_ms: 0)
  end

  test "A13 version 1 send, attach_pane and detach_pane are refused quiescing with no change", c do
    sock_dir = Path.join(c.inbox, "sock")
    File.mkdir_p!(sock_dir)
    File.chmod!(sock_dir, 0o700)
    adm = admission(c)

    start_supervised!(
      {AiPair.IPC.Server,
       inbox: c.inbox, name: :"rb3a_wire_server_#{c.n}", receipt_store: c.store, admission: adm}
    )

    # the server's authoritative stores are these: the receipt store it was given, and the
    # pane-intent store it locates by this inbox root (server.ex, the global name lookup)
    assert :global.whereis_name({AiPair.PaneIntentStore, c.inbox}) == c.pis
    receipts = Path.join([c.inbox, "delivery", "receipts.jsonl"])
    intents = Path.join(c.inbox, "pane-attachments.json")
    receipts_before = file_bytes(receipts)
    intents_before = file_bytes(intents)

    %{ok: true} = quiesce(c, adm)
    expected = fixture("v1_reply.quiescing.json")

    for frame <- [
          %{"cmd" => "send", "pane_id" => c.pane, "text" => @text},
          %{"cmd" => "attach_pane", "pane_id" => c.pane, "agent" => "claude_code"},
          %{"cmd" => "detach_pane", "pane_id" => c.pane}
        ] do
      assert request(Path.join(sock_dir, "ai-pair.sock"), frame) == expected, frame["cmd"]
      assert AiPair.PaneSupervisor.whereis_pane(c.pane) == :error, frame["cmd"]
      assert AiPair.PaneIntentStore.list(c.pis) == {:ok, []}, frame["cmd"]
      assert file_bytes(receipts) == receipts_before, frame["cmd"]
      assert file_bytes(intents) == intents_before, frame["cmd"]
    end
  end

  test "A14 version 2 refuses quiesce and resume with unsupported_command", c do
    for cmd <- ["quiesce", "resume"] do
      request = fixture("v2_request.#{cmd}.json")

      assert normalized(Delivery.dispatch(request, c.store), c) ==
               fixture("v2_reply.#{cmd}.unsupported_command.json")
    end
  end

  test "A15 ping advertises quiesce in durable mode, and quiesced with fence_id only while held",
       c do
    adm = admission(c)
    ping = %{"cmd" => "ping", "protocol_version" => 3}

    open = v3(ping, context(c, adm))
    assert "quiesce" in open.capabilities
    refute Map.has_key?(open, :quiesced) or Map.has_key?(open, :fence_id)
    refute "quiesce" in v3(ping, %{context(c, adm) | durable: false}).capabilities

    %{ok: true, fence_id: fence_id} = quiesce(c, adm)
    held = v3(ping, context(c, adm))
    assert held.quiesced == true and held.fence_id == fence_id
    refute inspect(held) =~ String.replace_prefix(c.hash, "sha256:", "")

    assert Map.delete(normalized(held, c, fence_id), "pong") ==
             Map.delete(fixture("ping.ok.quiesced.json"), "pong")
  end

  defp request(sock, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, @guard_ms)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  # the pane-intent store refuses a root under a symlink (macOS /var); as pane_intent_store_test.exs
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
end
