defmodule AiPair.Delivery.ReceiptSchema3RedTest do
  @moduledoc """
  RS3 RED (NS-15.G.002 B1b; scope r1 GO): receipt log schema 3.

  - A version 3 line has the ten version 2 keys plus registration_id and generation, both null or both set
    (reg_ + 32 lowercase hex; a decimal string). Versions 1 and 2 keep their own key sets.
  - Within one attempt every line repeats the attempt's pair (a pre-3 line reads as null); a new attempt after
    not_delivered may carry a new pair. A version 2 attempt continues under version 3; never the reverse, boot
    finalization included.
  - `cancelled` is legal only in version 3, only after queued, and is terminal: nothing follows it in that attempt and
    no new attempt opens. The store never writes it; a stored one reads as ambiguous (reconcile and duplicate) and
    is never restored.
  - Every line the store writes, boot finalization included, is version 3 with a null pair. A queued version 3
    attempt restores like version 2, and its pair reaches the registry and the handed entry.
  - S9 is not rollback evidence: no old build runs. It checks only that the lines this build writes fall outside a
    copy of the pre-RS3 version predicate.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore, SystemFs}

  @schema "ai-pair/delivery-receipt"
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @epoch "ep_" <> String.duplicate("ab", 12)
  @reg "reg_" <> String.duplicate("7e", 16)
  @other_reg "reg_" <> String.duplicate("e7", 16)
  @gen "8800"

  setup do
    inbox = Path.join(System.tmp_dir!(), "rs3_red_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(inbox, "delivery"))
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  defp hash(seed),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, seed <> " bytes"), case: :lower)

  defp pane, do: "%" <> "rs3"

  # {seed, status, attempt, version, pair} -> chained lines; pair is {registration_id, generation} or :none
  defp lines(specs) do
    {rows, _} =
      specs
      |> Enum.with_index(1)
      |> Enum.map_reduce(@anchor, fn {{seed, status, attempt, version, pair}, seq}, previous ->
        record =
          %{
            "schema" => @schema,
            "schema_version" => version,
            "seq" => seq,
            "prev_line_sha256" => previous,
            "daemon_epoch" => @epoch,
            "message_id" => id(seed),
            "pane_id" => pane(),
            "payload_hash" => hash(seed),
            "status" => status,
            "delivery_attempt" => attempt
          }
          |> with_pair(pair)

        line = Jason.encode!(record) <> "\n"
        {line, "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)}
      end)

    Enum.join(rows)
  end

  defp with_pair(record, :none), do: record
  defp with_pair(record, {:raw, extra}), do: Map.merge(record, extra)

  defp with_pair(record, {reg, gen}),
    do: Map.merge(record, %{"registration_id" => reg, "generation" => gen})

  defp open(inbox, specs) do
    File.write!(Path.join([inbox, "delivery", "receipts.jsonl"]), lines(specs))
    result = ReceiptLog.open(SystemFs.new(), inbox)
    with {:ok, log} <- result, do: ReceiptLog.close(log)
    result
  end

  defp corrupt?({:error, {:receipt_log_corrupt, _seq}}), do: true
  defp corrupt?(_other), do: false

  test "S1 version 3 lines with a null pair, or a set pair, open; the view carries the pair", c do
    assert {:ok, log} =
             open(c.inbox, [{"a", "pending", 1, 3, {nil, nil}}, {"a", "queued", 1, 3, {nil, nil}}])

    assert %{registration_id: nil, generation: nil} = ReceiptLog.view(log.entries[id("a")])

    assert {:ok, log} =
             open(c.inbox, [
               {"b", "pending", 1, 3, {@reg, @gen}},
               {"b", "delivered", 1, 3, {@reg, @gen}}
             ])

    assert %{registration_id: @reg, generation: @gen, status: "delivered"} =
             ReceiptLog.view(log.entries[id("b")])
  end

  test "S2 a malformed, half or extra pair, a missing key, or the pair on a version 2 line is corrupt",
       c do
    bad = [
      {@reg, nil},
      {nil, @gen},
      {"reg_" <> String.duplicate("A", 32), @gen},
      {@reg, "12a"},
      {@reg, 12},
      {:raw, %{"registration_id" => nil}},
      {:raw, %{"registration_id" => nil, "generation" => nil, "extra" => 1}}
    ]

    for pair <- bad do
      assert corrupt?(open(c.inbox, [{"c", "pending", 1, 3, pair}])), inspect(pair)
    end

    assert corrupt?(open(c.inbox, [{"c", "pending", 1, 2, {nil, nil}}])),
           "a v2 line has no pair keys"
  end

  test "S3 cancelled is legal only at version 3 and only after queued", c do
    assert {:ok, _} =
             open(c.inbox, [
               {"d", "pending", 1, 3, {nil, nil}},
               {"d", "queued", 1, 3, {nil, nil}},
               {"d", "cancelled", 1, 3, {nil, nil}}
             ])

    assert corrupt?(
             open(c.inbox, [
               {"d", "pending", 1, 2, :none},
               {"d", "queued", 1, 2, :none},
               {"d", "cancelled", 1, 2, :none}
             ])
           )

    assert corrupt?(
             open(c.inbox, [
               {"d", "pending", 1, 1, :none},
               {"d", "queued", 1, 1, :none},
               {"d", "cancelled", 1, 1, :none}
             ])
           ),
           "a v1 cancelled is corrupt"

    assert {:ok, _} =
             open(c.inbox, [{"d", "pending", 1, 1, :none}, {"d", "queued", 1, 1, :none}]),
           "control: the v1 prefix opens"

    assert corrupt?(
             open(c.inbox, [
               {"d", "pending", 1, 3, {nil, nil}},
               {"d", "cancelled", 1, 3, {nil, nil}}
             ])
           )

    assert corrupt?(
             open(c.inbox, [
               {"d", "pending", 1, 3, {nil, nil}},
               {"d", "paste_started", 1, 3, {nil, nil}},
               {"d", "cancelled", 1, 3, {nil, nil}}
             ])
           )
  end

  test "S4 cancelled is terminal: nothing follows it and no new attempt opens", c do
    cancelled = [
      {"e", "pending", 1, 3, {nil, nil}},
      {"e", "queued", 1, 3, {nil, nil}},
      {"e", "cancelled", 1, 3, {nil, nil}}
    ]

    for next <- [
          {"e", "delivered", 1, 3, {nil, nil}},
          {"e", "ambiguous", 1, 3, {nil, nil}},
          {"e", "pending", 2, 3, {nil, nil}}
        ] do
      assert corrupt?(open(c.inbox, cancelled ++ [next])), inspect(next)
    end
  end

  test "S5 the pair is fixed within an attempt and may change only with a new attempt after not_delivered",
       c do
    assert corrupt?(
             open(c.inbox, [
               {"f", "pending", 1, 3, {@reg, @gen}},
               {"f", "queued", 1, 3, {@other_reg, @gen}}
             ])
           )

    assert corrupt?(
             open(c.inbox, [{"f", "pending", 1, 3, {@reg, @gen}}, {"f", "queued", 1, 3, {nil, nil}}])
           )

    assert {:ok, _} =
             open(c.inbox, [
               {"f", "pending", 1, 3, {@reg, @gen}},
               {"f", "not_delivered", 1, 3, {@reg, @gen}},
               {"f", "pending", 2, 3, {@other_reg, "9900"}}
             ])
  end

  test "S6 a version 2 attempt continues under version 3; a version 3 attempt never continues as version 2",
       c do
    assert {:ok, _} =
             open(c.inbox, [
               {"g", "pending", 1, 2, :none},
               {"g", "queued", 1, 2, :none},
               {"g", "delivered", 1, 3, {nil, nil}}
             ])

    assert corrupt?(
             open(c.inbox, [{"g", "pending", 1, 3, {nil, nil}}, {"g", "queued", 1, 2, :none}])
           )

    assert corrupt?(
             open(c.inbox, [{"g", "pending", 1, 2, :none}, {"g", "queued", 1, 3, {@reg, @gen}}])
           )

    for from <- ["pending", "queued"] do
      head = if from == "queued", do: [{"g", "pending", 1, 3, {nil, nil}}], else: []

      assert corrupt?(
               open(
                 c.inbox,
                 head ++ [{"g", from, 1, 3, {nil, nil}}, {"g", "ambiguous", 1, 2, :none}]
               )
             ),
             "no v3 #{from} -> v2 ambiguous edge, boot finalization included"
    end

    assert {:ok, _} =
             open(c.inbox, [{"g", "pending", 1, 2, :none}, {"g", "ambiguous", 1, 3, {nil, nil}}]),
           "control: v2 pending -> v3 ambiguous is the forward boot finalization"
  end

  test "S7 every line the store writes, boot finalization included, is version 3 with a null pair; it refuses cancelled",
       c do
    store = start_store!(c.inbox)

    {:ok, {:admitted, %{operation_token: a}}} = admit(store, "h-a")
    assert {:error, _refused} = ReceiptStore.transition(store, id("h-a"), a, "cancelled")
    assert :ok = ReceiptStore.queue(store, id("h-a"), a, bytes("h-a"))
    assert :ok = ReceiptStore.transition(store, id("h-a"), a, "delivered")
    {:ok, {:admitted, %{operation_token: b}}} = admit(store, "h-b")
    assert :ok = ReceiptStore.transition(store, id("h-b"), b, "not_delivered")
    {:ok, {:admitted, _}} = admit(store, "h-c")
    stop(store)
    stop(start_store!(c.inbox))

    records = receipts(c.inbox)

    assert Enum.map(records, &{&1["message_id"], &1["status"]}) == [
             {id("h-a"), "pending"},
             {id("h-a"), "queued"},
             {id("h-a"), "delivered"},
             {id("h-b"), "pending"},
             {id("h-b"), "not_delivered"},
             {id("h-c"), "pending"},
             {id("h-c"), "ambiguous"}
           ]

    for r <- records do
      assert r["schema_version"] == 3 and Map.fetch(r, "registration_id") == {:ok, nil} and
               Map.fetch(r, "generation") == {:ok, nil},
             inspect(r)
    end
  end

  test "S8 a stored cancelled reads as ambiguous on reconcile and duplicate, is never re-admitted or restored",
       c do
    queued_then_killed!(c.inbox, ["i", "i-control"])

    rechain!(c.inbox, fn records ->
      queued = Enum.find(records, &(&1["message_id"] == id("i") and &1["status"] == "queued"))
      records ++ [%{queued | "seq" => length(records) + 1, "status" => "cancelled"}]
    end)

    store = start_store!(c.inbox)

    assert {:ok, view} =
             ReceiptStore.reconcile(store, id("i"), pane(), payload_hash("i"), wait_ms: 0)

    assert view.status == "ambiguous" and view.outcome == "ambiguous"

    assert {:ok, {:duplicate, duplicate}} = admit(store, "i")
    assert %{status: "ambiguous", delivery_attempt: 1} = duplicate

    assert List.last(receipts(c.inbox))["status"] == "cancelled",
           "nothing is appended after a stored cancelled"

    assert [%{msg_id: control}] = registry(store)[pane()], "only the queued control is restored"
    assert control == id("i-control")
    stop(store)
  end

  # A copy of the version predicate of receipt_log.ex at Orrisd 7005ac31 (@schema_versions [1, 2]). No old
  # build runs, so this row is not rollback evidence; it shows only that what this build writes is outside it.
  defp pre_rs3_compatible?(%{"schema" => @schema, "schema_version" => v}) when is_integer(v),
    do: v in [1, 2]

  defp pre_rs3_compatible?(_record), do: false

  test "S9 every line this build writes falls outside a copy of the pre-RS3 version predicate", c do
    queued_then_killed!(c.inbox, ["j"])

    for r <- receipts(c.inbox), do: refute(pre_rs3_compatible?(r), inspect(r))
  end

  test "S10 a queued version 3 attempt with a set pair restores, and the pair reaches the registry and the holder",
       c do
    queued_then_killed!(c.inbox, ["k"])

    rechain!(c.inbox, fn records ->
      Enum.map(records, fn r ->
        if r["message_id"] == id("k"),
          do: %{r | "registration_id" => @reg, "generation" => @gen},
          else: r
      end)
    end)

    store = start_store!(c.inbox)

    assert [%{msg_id: msg, registration_id: @reg, generation: @gen, holder: nil}] =
             registry(store)[pane()]

    assert msg == id("k")
    assert List.last(receipts(c.inbox))["status"] == "queued", "the attempt stays queued"

    assert {:ok, cap} = apply(ReceiptStore, :issue_restore_capability, [store, pane(), make_ref()])

    assert {:ok, [%{msg_id: ^msg, registration_id: @reg, generation: @gen}]} =
             apply(ReceiptStore, :claim_restored, [store, pane(), cap])

    stop(store)
  end

  defp bytes(seed), do: seed <> " bytes"
  defp payload_hash(seed), do: Payload.hash(Payload.new(bytes(seed)))

  defp admit(store, seed),
    do: ReceiptStore.admit(store, id(seed), pane(), payload_hash(seed), self())

  defp registry(store), do: apply(ReceiptStore, :restore_registry, [store])
  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp start_store!(inbox) do
    assert {:ok, pid} =
             GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new(), restore_issuer: self())

    on_exit(fn -> stop(pid) end)
    pid
  end

  # Each seed is admitted and queued under a real store, which is then killed.
  defp queued_then_killed!(inbox, seeds) do
    store = start_store!(inbox)

    for seed <- seeds do
      {:ok, {:admitted, %{operation_token: token}}} = admit(store, seed)
      assert :ok = ReceiptStore.queue(store, id(seed), token, bytes(seed))
    end

    stop(store)
  end

  defp receipts(inbox) do
    inbox
    |> Path.join("delivery/receipts.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # Rewrites the receipt log through `fun`, chaining every line again from the anchor.
  defp rechain!(inbox, fun) do
    {rows, _} =
      inbox
      |> receipts()
      |> fun.()
      |> Enum.map_reduce(@anchor, fn record, previous ->
        line = Jason.encode!(%{record | "prev_line_sha256" => previous}) <> "\n"
        {line, "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)}
      end)

    File.write!(Path.join([inbox, "delivery", "receipts.jsonl"]), Enum.join(rows))
  end
end
