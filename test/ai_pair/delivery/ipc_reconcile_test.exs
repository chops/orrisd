defmodule AiPair.Delivery.IPCReconcileTest do
  @moduledoc """
  Reconcile at the IPC seam (protocol version 2).

  `docs/contracts/ipc-v1.org` freezes v1 byte-for-byte and classifies negotiation, capability
  advertisement, msg-id echo and incompatible-peer rejection as v2 features, so reconcile
  lives in **protocol v2**, and these tests pin it as such:

    * every v2 request carries `protocol_version: 2` and every v2 reply echoes it;
    * `ping` advertises capabilities, so a durable client can refuse a daemon that cannot
      reconcile rather than discovering it by side effect;
    * every send/reconcile reply echoes the exact `msg_id` it was given --
      a missing or mismatched echo is protocol conflict, never success and never absence;
    * `reconcile` binds the payload with `payload_hash`, so a same-id
      different-payload send is a `conflict` rather than a false `delivered`;
    * `msg_id` must be the globally scoped `snd_<64 hex>` form, because the daemon
      receipt store is global and run-scoped `send_as_NNNN` ids repeat in every run;
    * an unknown command, a missing version, or a v1 version on the v2 surface must fail
      closed with **no** `outcome` key, because "unknown command" must never be read as
      "absent";
    * the server refuses to start at all without a receipt authority, which is the
      behavioural form of the receipt-authority ordering requirement.

  A v1 daemon may keep serving legacy clients; what these tests forbid is the durable
  orchestrator concluding anything from one.

  Further rules:

    * `protocol_version` is explicit on every v2 request and echoed on every v2 reply,
      including refusals. There is no ambient default in either direction, so a reply that
      does not name its version cannot be read as a v2 answer.
    * The store is addressed through `admit/5` and the token-bearing `transition/4`,
      and a reconcile reply names the `delivery_attempt` it is answering about.
    * `pane_id` is echoed alongside `msg_id`. A receipt is identified by the pair, so a
      client that validated only the message id could bind a reply to the wrong pane.
    * The outcome vocabulary is exercised in full: a proven pre-paste failure reads as
      `absent` on the wire, and a lost owner reads as `ambiguous`.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.IPC.Server

  @pane "%" <> "9"
  @other_pane "%" <> "8"
  @msg_a "snd_" <> String.duplicate("a1", 32)
  @msg_b "snd_" <> String.duplicate("b2", 32)
  @payload "sha256:" <> String.duplicate("e5", 32)
  @other_payload "sha256:" <> String.duplicate("f6", 32)

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_reconcile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    store = start_supervised!({ReceiptStore, inbox: tmp})
    {:ok, inbox: tmp, store: store, sock_path: Path.join(tmp, "sock/ai-pair.sock")}
  end

  describe "the v2 surface announces itself" do
    test "ping advertises the protocol version and the reconcile capability", ctx do
      sock = serve(ctx, :ipc_v2_ping)

      reply = send_frame(sock, %{"cmd" => "ping", "protocol_version" => 2})

      assert reply["ok"] == true
      assert reply["protocol_version"] == 2
      assert "delivery_reconcile" in reply["capabilities"]

      assert Enum.all?(reply["capabilities"], &is_binary/1),
             "capabilities are opaque tokens a client matches, never a structure it parses"
    end

    test "a ping without a version is answered as v1", ctx do
      sock = serve(ctx, :ipc_v2_ping_unversioned)

      reply = send_frame(sock, %{"cmd" => "ping"})

      refute Map.has_key?(reply, "capabilities"),
             "an unversioned request is a v1 request. A client that forgot the field " <>
               "must not be handed v2 semantics by accident"
    end

    test "a v1 ping keeps working and advertises nothing new", ctx do
      sock = serve(ctx, :ipc_v1_ping)

      reply = send_frame(sock, %{"cmd" => "ping"})

      assert reply["ok"] == true

      refute Map.has_key?(reply, "capabilities"),
             "v1 is frozen byte-for-byte, so the legacy reply may not grow fields"
    end
  end

  describe "reconcile answers the five-valued question" do
    test "a message id the daemon never saw is absent", ctx do
      sock = serve(ctx, :ipc_v2_absent)

      reply = send_frame(sock, reconcile_frame(@msg_a))

      assert reply["ok"] == true
      assert reply["outcome"] == "absent"
      assert reply["protocol_version"] == 2
      assert reply["msg_id"] == @msg_a
    end

    test "a delivered receipt reads as delivered", ctx do
      sock = serve(ctx, :ipc_v2_delivered)
      finalize!(ctx, @msg_a, "delivered")

      reply = send_frame(sock, reconcile_frame(@msg_a))

      assert reply["outcome"] == "delivered"
      assert reply["msg_id"] == @msg_a
      assert reply["delivery_attempt"] == 1
    end

    test "a queued receipt reads as queued", ctx do
      sock = serve(ctx, :ipc_v2_queued)
      finalize!(ctx, @msg_a, "queued")

      reply = send_frame(sock, reconcile_frame(@msg_a))

      assert reply["outcome"] == "queued",
             "queued is a waypoint the client must keep asking about, not a terminal answer"
    end

    test "a proven pre-paste failure reads as absent", ctx do
      sock = serve(ctx, :ipc_v2_not_delivered)
      finalize!(ctx, @msg_a, "not_delivered")

      reply = send_frame(sock, reconcile_frame(@msg_a))

      assert reply["outcome"] == "absent",
             "never-seen and proven-unsent differ in the receipt and not on the wire, " <>
               "because they license exactly one action: send it"

      assert reply["delivery_attempt"] == 1
    end

    test "a send whose owner was lost reads as ambiguous", ctx do
      sock = serve(ctx, :ipc_v2_ambiguous)
      finalize!(ctx, @msg_a, "ambiguous")

      reply = send_frame(sock, reconcile_frame(@msg_a))

      assert reply["outcome"] == "ambiguous",
             "the daemon reports what it can prove, and it cannot prove this one either way"
    end

    test "the same id with a different payload is a conflict", ctx do
      sock = serve(ctx, :ipc_v2_payload_conflict)
      finalize!(ctx, @msg_a, "delivered")

      reply = send_frame(sock, reconcile_frame(@msg_a, payload_hash: @other_payload))

      assert reply["outcome"] == "conflict",
             "without payload binding this would answer delivered for other bytes"
    end

    test "the same id on a different pane is a conflict", ctx do
      sock = serve(ctx, :ipc_v2_pane_conflict)
      finalize!(ctx, @msg_a, "delivered")

      reply = send_frame(sock, reconcile_frame(@msg_a, pane_id: @other_pane))

      assert reply["outcome"] == "conflict"
    end

    test "reconcile never echoes payload bytes", ctx do
      sock = serve(ctx, :ipc_v2_redaction)
      _token = admit!(ctx, @msg_a)

      reply = send_frame(sock, reconcile_frame(@msg_a))

      refute Map.has_key?(reply, "text")
      refute Map.has_key?(reply, "payload")
      refute Map.has_key?(reply, "prompt")
    end
  end

  describe "an unanswerable request fails closed" do
    test "a missing payload hash is refused without an outcome", ctx do
      sock = serve(ctx, :ipc_v2_no_hash)

      reply =
        send_frame(sock, %{
          "cmd" => "reconcile",
          "protocol_version" => 2,
          "pane_id" => @pane,
          "msg_id" => @msg_a
        })

      assert reply["ok"] == false
      refute Map.has_key?(reply, "outcome")
    end

    test "a malformed payload hash is refused without an outcome", ctx do
      sock = serve(ctx, :ipc_v2_bad_hash)

      reply = send_frame(sock, reconcile_frame(@msg_a, payload_hash: "sha256:NOTHEX"))

      assert reply["ok"] == false
      refute Map.has_key?(reply, "outcome")
    end

    test "a run-scoped message id is refused without an outcome", ctx do
      sock = serve(ctx, :ipc_v2_bad_id)

      reply = send_frame(sock, reconcile_frame("send_as_0001"))

      assert reply["ok"] == false

      refute Map.has_key?(reply, "outcome"),
             "send_as_0001 repeats in every run, so it cannot address a global store"
    end

    test "a missing pane id is refused without an outcome", ctx do
      sock = serve(ctx, :ipc_v2_no_pane)

      reply =
        send_frame(sock, %{
          "cmd" => "reconcile",
          "protocol_version" => 2,
          "msg_id" => @msg_a,
          "payload_hash" => @payload
        })

      assert reply["ok"] == false
      refute Map.has_key?(reply, "outcome")
    end

    test "reconcile without a protocol version is refused", ctx do
      sock = serve(ctx, :ipc_v2_no_version)

      reply =
        send_frame(sock, %{
          "cmd" => "reconcile",
          "pane_id" => @pane,
          "msg_id" => @msg_a,
          "payload_hash" => @payload
        })

      assert reply["ok"] == false

      refute Map.has_key?(reply, "outcome"),
             "the v2 surface is not reachable through a v1 frame"
    end

    test "an incompatible protocol version is refused", ctx do
      sock = serve(ctx, :ipc_v2_bad_version)

      reply = send_frame(sock, reconcile_frame(@msg_a, protocol_version: 99))

      assert reply["ok"] == false
      refute Map.has_key?(reply, "outcome")
    end

    test "an unknown command carries no outcome", ctx do
      sock = serve(ctx, :ipc_v2_unknown)

      reply = send_frame(sock, %{"cmd" => "reconsile", "protocol_version" => 2})

      assert reply["ok"] == false

      refute Map.has_key?(reply, "outcome"),
             "a v1 daemon's unknown-command reply must never be read as absence"
    end
  end

  describe "identity is echoed on every v2 reply" do
    test "an error reply still echoes the message id it was given", ctx do
      sock = serve(ctx, :ipc_v2_echo_error)

      reply =
        send_frame(sock, %{
          "cmd" => "send",
          "protocol_version" => 2,
          "pane_id" => "%does-not-exist",
          "text" => "hello",
          "msg_id" => @msg_b
        })

      assert reply["ok"] == false

      assert reply["msg_id"] == @msg_b,
             "the client validates the echo before it interprets anything else"

      assert reply["pane_id"] == "%does-not-exist",
             "a receipt is keyed by pane and message together, so both are echoed"

      assert reply["protocol_version"] == 2,
             "a refusal is still a v2 answer and still says so"
    end

    test "a refusal echoes the identity it was able to read", ctx do
      sock = serve(ctx, :ipc_v2_echo_refusal)

      reply =
        send_frame(sock, %{
          "cmd" => "reconcile",
          "protocol_version" => 2,
          "pane_id" => @pane,
          "msg_id" => @msg_a
        })

      assert reply["ok"] == false
      refute Map.has_key?(reply, "outcome")
      assert reply["msg_id"] == @msg_a
      assert reply["pane_id"] == @pane
      assert reply["protocol_version"] == 2
    end

    test "a v1 send reply offers nothing for a durable client to bind to", ctx do
      sock = serve(ctx, :ipc_v1_send_echo)

      reply = send_frame(sock, %{"cmd" => "send", "pane_id" => @pane, "text" => "hello"})

      refute Map.has_key?(reply, "msg_id"),
             "v1 is frozen, so it grows no echo, and a durable client must refuse " <>
               "a v1 daemon at ping rather than send into one and hope"
    end
  end

  describe "the server refuses to serve without a receipt authority" do
    test "start_link fails when no receipt store is available", %{inbox: inbox} do
      assert {:error, :receipt_store_unavailable} =
               Server.start_link(inbox: inbox, name: :ipc_v2_no_store),
             "the receipt authority starts before the IPC surface, or not at all"
    end
  end

  # ----- helpers -----

  defp serve(ctx, name) do
    {:ok, pid} = Server.start_link(inbox: ctx.inbox, name: name, receipt_store: ctx.store)
    on_exit(fn -> stop_quietly(pid) end)
    ctx.sock_path
  end

  defp admit!(ctx, msg_id) do
    assert {:ok, {:admitted, %{operation_token: token, delivery_attempt: 1}}} =
             ReceiptStore.admit(ctx.store, msg_id, @pane, @payload, self())

    token
  end

  defp finalize!(ctx, msg_id, status) do
    token = admit!(ctx, msg_id)
    :ok = ReceiptStore.transition(ctx.store, msg_id, token, status)
  end

  defp reconcile_frame(msg_id, opts \\ []) do
    %{
      "cmd" => "reconcile",
      "protocol_version" => Keyword.get(opts, :protocol_version, 2),
      "pane_id" => Keyword.get(opts, :pane_id, @pane),
      "msg_id" => msg_id,
      "payload_hash" => Keyword.get(opts, :payload_hash, @payload)
    }
  end

  defp send_frame(sock_path, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

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
