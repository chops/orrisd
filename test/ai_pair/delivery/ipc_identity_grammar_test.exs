defmodule AiPair.Delivery.IPCIdentityGrammarTest do
  @moduledoc """
  One `pane_id` grammar, on the echo and on the receipt alike.

  `docs/contracts/ipc-v2.org` (vendored from orris `3684f53e`; the sentences below
  landed in the consumer at `e5da392e` and are unchanged since) states the grammar and
  which way the disagreement resolves:

  > `pane_id` is `%` followed by 1..128 characters from `[a-zA-Z0-9_]`. This is the
  > GOVERNING grammar: it is the one the daemon's receipt record is keyed by, so a pane
  > id outside it cannot be stored and therefore cannot be delivered. A daemon whose echo
  > predicate is wider than its storage predicate will echo a pane id it then refuses;
  > the two predicates are one grammar and a daemon reconciles them on its own side.

  This daemon was that daemon. `AiPair.IPC.Delivery` held a private `echoable_pane?/1`
  whose regex was `ReceiptLog.valid_pane?/1`'s plus `-`, so three classes of hyphenated
  pane id -- measured, not imagined: `%pane-alpha`, `%panealpha-`, and a 128-character id
  ending in a hyphen -- were echoed back in a reply that refused them `invalid_pane_id` in
  the same breath. The echo now consults the storage predicate, so there is one grammar.

  What these rows pin, in order:

    * the three divergent values answer `invalid_pane_id` with NO `pane_id` echo;
    * the echo decision and the refusal decision are the SAME decision across a corpus
      that includes every boundary of the grammar, so re-introducing a second predicate
      for either field fails here rather than on a consumer's wire;
    * `invalid_msg_id` and `invalid_pane_id` each drop only their own identity and keep
      the other one, and stay distinct from `missing_msg_id` / `missing_pane_id`;
    * the grammar refusal precedes the pane registry lookup, so it is a fact about the
      request and never an answer about delivery: no `outcome`, no `status`;
    * replies for identities the grammar accepts are byte-for-byte what they were.

  The consumer half of this slice (orris `e5da392e`) names both words as request errors
  and asserts it needs no echo to do so, which is why dropping the echo is safe.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Delivery

  @msg "snd_" <> String.duplicate("ab", 32)
  @other_msg "snd_" <> String.duplicate("cd", 32)
  @hash "sha256:" <> String.duplicate("e5", 32)

  @pane "%pane_alpha"

  # The exact values the consumer lane's divergence case named, plus the length boundary:
  # each is accepted by the OLD echo regex and refused by the storage regex.
  @divergent [
    {"a hyphen in the middle", "%pane-alpha"},
    {"a trailing hyphen", "%panealpha-"},
    {"a hyphen at the 128-character bound", "%" <> String.duplicate("a", 127) <> "-"}
  ]

  @accepted [
    "%a",
    "%pane_alpha",
    "%PaneAlpha9Z",
    "%" <> String.duplicate("a", 128)
  ]

  @refused [
    "%",
    "%pane.alpha",
    "%pane alpha",
    "pane_alpha",
    "",
    "%" <> String.duplicate("a", 129),
    "%pane_alpha\n"
  ]

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_grammar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, inbox: tmp, store: start_supervised!({ReceiptStore, inbox: tmp})}
  end

  describe "the divergent pane ids" do
    test "each is refused invalid_pane_id and is NOT echoed back", ctx do
      for {label, pane} <- @divergent do
        refute ReceiptLog.valid_pane?(pane),
               "#{label}: the corpus is only about the divergence while the storage " <>
                 "grammar still refuses these; a value it accepted would make the rows below " <>
                 "assertions about an ordinary valid pane"

        for reply <- [reconcile(ctx, pane_id: pane), send_frame(ctx, pane_id: pane)] do
          assert reply.ok == false, label
          assert reply.error == "invalid_pane_id", label

          refute Map.has_key?(reply, :pane_id),
                 "#{label}: this daemon used to echo it and refuse it in the same reply"

          assert reply.msg_id == @msg,
                 "#{label}: only the identity that failed is dropped"

          assert reply.protocol_version == 2, label
        end
      end
    end

    test "the wire bytes carry no pane_id key either", ctx do
      {:ok, pid} =
        AiPair.IPC.Server.start_link(
          inbox: ctx.inbox,
          name: :ipc_grammar_wire,
          receipt_store: ctx.store
        )

      on_exit(fn -> stop_quietly(pid) end)

      decoded =
        wire(Path.join(ctx.inbox, "sock/ai-pair.sock"), %{
          "cmd" => "reconcile",
          "protocol_version" => 2,
          "msg_id" => @msg,
          "pane_id" => "%pane-alpha",
          "payload_hash" => @hash,
          "wait_ms" => 0
        })

      assert decoded["error"] == "invalid_pane_id"
      assert decoded["msg_id"] == @msg
      assert decoded["protocol_version"] == 2

      refute Map.has_key?(decoded, "pane_id"),
             "the JSON frame, not just the map the module builds, must omit it"
    end
  end

  describe "the echo decision and the refusal decision are one decision" do
    test "across the whole corpus, a pane is echoed exactly when it is storable", ctx do
      # ANTI-VACUITY. A corpus that was all-accepted or all-refused would make the
      # equivalence below trivially true, so both halves must be non-empty and must
      # really disagree with each other.
      assert @accepted != [] and @refused != [] and @divergent != []
      assert Enum.all?(@accepted, &ReceiptLog.valid_pane?/1)
      assert Enum.all?(@refused, fn pane -> not ReceiptLog.valid_pane?(pane) end)

      for pane <- corpus() do
        storable? = ReceiptLog.valid_pane?(pane)
        echoed? = Map.has_key?(reconcile(ctx, pane_id: pane), :pane_id)

        assert echoed? == storable?,
               "#{inspect(pane)}: echoed?=#{echoed?} storable?=#{storable?}. Two predicates " <>
                 "for one field is the defect this slice closed; the echo must consult " <>
                 "ReceiptLog.valid_pane?/1 and nothing else"
      end
    end

    test "and a pane the grammar refuses is refused by name, whatever else is wrong", ctx do
      for pane <- @refused ++ Enum.map(@divergent, &elem(&1, 1)) do
        reply = reconcile(ctx, pane_id: pane)

        assert reply.error == "invalid_pane_id",
               "#{inspect(pane)} -> #{inspect(reply)}"
      end

      for pane <- @accepted do
        refute Map.get(reconcile(ctx, pane_id: pane), :error) == "invalid_pane_id",
               "#{inspect(pane)} is storable, so no grammar refusal is available for it"
      end
    end

    test "lib/ holds exactly one pane grammar, in the module the receipt record uses" do
      holders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn path -> File.read!(path) =~ ~r/~r\/\\A%\[a-zA-Z0-9/ end)
        |> Enum.sort()

      # ANTI-VACUITY: the detector must still find the one that is really there, or the
      # equality below is a statement about a broken wildcard.
      assert "lib/ai_pair/delivery/receipt_log.ex" in holders

      assert holders == ["lib/ai_pair/delivery/receipt_log.ex"],
             "a second pane regex anywhere in lib/ is a second grammar, and the vendored " <>
               "contract says there is one. Found: #{inspect(holders)}"
    end
  end

  describe "each request error drops only its own identity" do
    test "invalid_msg_id keeps the pane echo and drops the message echo", ctx do
      for bad <- ["snd_ZZZ", "send_as_0001", String.upcase(@msg), 42] do
        reply = reconcile(ctx, msg_id: bad)

        assert reply.error == "invalid_msg_id", inspect(bad)
        refute Map.has_key?(reply, :msg_id), inspect(bad)
        assert reply.pane_id == @pane, inspect(bad)
      end
    end

    test "an absent identity is missing_*, never invalid_*", ctx do
      assert reconcile(ctx, msg_id: nil).error == "missing_msg_id"
      assert reconcile(ctx, pane_id: nil).error == "missing_pane_id"

      assert reconcile(ctx, msg_id: nil).pane_id == @pane,
             "the identity that was present is still readable and still echoed"

      refute Map.has_key?(reconcile(ctx, pane_id: nil), :pane_id)

      # The consumer distinguishes "the field was absent" from "the field was malformed",
      # so collapsing the two here would silently retire half its vocabulary.
      refute reconcile(ctx, msg_id: nil).error == "invalid_msg_id"
      refute reconcile(ctx, pane_id: nil).error == "invalid_pane_id"
    end

    test "the message id is read before the pane id, so one reply names one fault", ctx do
      reply = reconcile(ctx, msg_id: "snd_ZZZ", pane_id: "%pane-alpha")

      assert reply.error == "invalid_msg_id",
             "identity/1 is a cond, so the first failing field names the refusal"

      refute Map.has_key?(reply, :msg_id)
      refute Map.has_key?(reply, :pane_id)
    end
  end

  describe "a grammar refusal is never an answer about delivery" do
    test "it carries no outcome and no status, on reconcile and on send", ctx do
      for pane <- Enum.map(@divergent, &elem(&1, 1)),
          reply <- [reconcile(ctx, pane_id: pane), send_frame(ctx, pane_id: pane)] do
        refute Map.has_key?(reply, :outcome),
               "an unreadable pane id must never be read as absence"

        refute Map.has_key?(reply, :status)
        refute Map.has_key?(reply, :duplicate)
        refute Map.has_key?(reply, :delivery_attempt)
      end
    end

    test "it happens before the pane registry is consulted", ctx do
      # A storable pane that is not registered gets as far as the registry and is told so.
      assert send_frame(ctx, pane_id: "%not_registered_here").error == "pane_not_found"

      # An unstorable one never gets there, so the operator is told what to fix.
      assert send_frame(ctx, pane_id: "%pane-alpha").error == "invalid_pane_id"
    end
  end

  describe "replies for identities the grammar accepts did not move" do
    test "a storable pane still reconciles and still echoes both identities", ctx do
      for pane <- @accepted do
        assert reconcile(ctx, pane_id: pane) == %{
                 ok: true,
                 outcome: "absent",
                 msg_id: @msg,
                 pane_id: pane,
                 protocol_version: 2
               }
      end
    end

    test "an admitted receipt still answers with its view and both echoes", ctx do
      assert {:ok, {:admitted, %{operation_token: token, delivery_attempt: 1}}} =
               ReceiptStore.admit(ctx.store, @other_msg, @pane, @hash, self())

      :ok = ReceiptStore.transition(ctx.store, @other_msg, token, "delivered")

      assert reconcile(ctx, msg_id: @other_msg) == %{
               ok: true,
               outcome: "delivered",
               status: "delivered",
               delivery_attempt: 1,
               payload_hash: @hash,
               msg_id: @other_msg,
               pane_id: @pane,
               protocol_version: 2
             }
    end

    test "ping is unchanged for a storable pane and stops echoing an unstorable one", ctx do
      assert ping(ctx, @pane) == %{
               ok: true,
               pong: AiPair.version(),
               capabilities: ["delivery_reconcile", "sessions_read"],
               pane_id: @pane,
               protocol_version: 2
             }

      # `echo/1` is merged into EVERY v2 reply, ping included, so the narrowed predicate
      # reaches a reply that was never a refusal. That is the one other place this slice
      # changes bytes, and it is pinned here rather than discovered by a client.
      assert ping(ctx, "%pane-alpha") == %{
               ok: true,
               pong: AiPair.version(),
               capabilities: ["delivery_reconcile", "sessions_read"],
               protocol_version: 2
             }
    end
  end

  # ===== helpers =====

  defp corpus, do: @accepted ++ @refused ++ Enum.map(@divergent, &elem(&1, 1))

  defp reconcile(ctx, opts) do
    Delivery.dispatch(
      %{
        "cmd" => "reconcile",
        "protocol_version" => 2,
        "msg_id" => Keyword.get(opts, :msg_id, @msg),
        "pane_id" => Keyword.get(opts, :pane_id, @pane),
        "payload_hash" => @hash,
        "wait_ms" => 0
      },
      ctx.store
    )
  end

  defp send_frame(ctx, opts) do
    Delivery.dispatch(
      %{
        "cmd" => "send",
        "protocol_version" => 2,
        "msg_id" => Keyword.get(opts, :msg_id, @msg),
        "pane_id" => Keyword.get(opts, :pane_id, @pane),
        "text" => "hello"
      },
      ctx.store
    )
  end

  defp ping(ctx, pane) do
    Delivery.dispatch(%{"cmd" => "ping", "protocol_version" => 2, "pane_id" => pane}, ctx.store)
  end

  # The listener closes its acceptor on the way down and answers `:shutdown` rather than
  # `:normal`; `ipc_reconcile_test.exs` takes the same precaution for the same reason.
  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp wire(sock_path, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end
end
