defmodule AiPair.Delivery.ReceiptLogV2ReaderRedTest do
  @moduledoc """
  NS-15.G.003 S0a (design r2, RED design r1): the receipt reader accepts schema versions 1
  and 2; the writer stays version 1.

  Version 2 is the writer generation that will record a durable `paste_started` before any
  paste (S0b). S0a only READS it, so a rollback from an S0b build to an S0a build keeps the
  log readable. Rows:

    * R0.1 a v2 line after v1 lines loads; the chain validates across the version change and
      each message's replayed entry is exact.
    * R0.2 v2 `paste_started` replays (pending -> paste_started, queued -> paste_started); the
      replayed entries are exact.
    * R0.3 each allowed cross-version edge loads and replays to the exact final entry.
    * R0.4 each forbidden edge is `receipt_log_corrupt` at its line, file bytes unchanged.
    * R0.5 control: `paste_started` in a v1 line is corrupt (v1 statuses are unchanged).
    * R0.6 an S0a store boot finalizes v2 pending, queued and paste_started as `ambiguous`
      by appending VERSION 1 records after the byte-identical original log (ReceiptStore
      boot, not ReceiptLog replay).
    * R0.9 (design r3) within one attempt only nonterminal -> ambiguous may change version;
      every other same-attempt cross-version edge, including laundering chains, is
      `receipt_log_corrupt` at the first cross-version line, file bytes unchanged.
    * R0.7 every status an S0a store appends through its API (pending, queued, delivered,
      not_delivered, retry pending) is a version 1 record, after loading v2 history. The
      boot-time `ambiguous` append is R0.6.

  Expected at Orrisd b79863cd: every row except R0.5 fails (a v2 line is refused as
  incompatible today). R0.5 passes before and after.

  NS-15.G.003 S0b re-points R0.6 and R0.7 to the version 2 writer: boot and API appends are
  version 2, and begin_paste appends a paste_started marker (see each row).
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore, SystemFs}

  @schema "ai-pair/delivery-receipt"
  @pane "%receiptlog_v2"
  @payload "sha256:" <> String.duplicate("e5", 32)
  @epoch "ep_" <> String.duplicate("1e", 12)
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  setup do
    inbox = Path.join(System.tmp_dir!(), "receiptlog_v2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  test "R0.1 a v2 line after v1 lines loads and the chain validates across versions", %{inbox: dir} do
    write_log!(dir, chain([{1, "a", "pending", 1}, {2, "b", "pending", 1}]))
    assert_opens!(dir, 2, %{"a" => {1, "pending", 1, 1}, "b" => {2, "pending", 1, 2}})
  end

  test "R0.2 v2 paste_started replays after pending and after queued", %{inbox: dir} do
    lines =
      chain([
        {2, "b", "pending", 1},
        {2, "b", "paste_started", 1},
        {2, "c", "pending", 1},
        {2, "c", "queued", 1},
        {2, "c", "paste_started", 1}
      ])

    write_log!(dir, lines)

    assert_opens!(dir, 5, %{
      "b" => {2, "paste_started", 1, 2},
      "c" => {2, "paste_started", 1, 5}
    })
  end

  # {label, rows, expected final entry of "a" as {version, status, attempt, seq}}
  allowed = [
    {"v1 pending -> v2 ambiguous", [{1, "a", "pending", 1}, {2, "a", "ambiguous", 1}],
     {2, "ambiguous", 1, 2}},
    {"v1 queued -> v2 ambiguous",
     [{1, "a", "pending", 1}, {1, "a", "queued", 1}, {2, "a", "ambiguous", 1}],
     {2, "ambiguous", 1, 3}},
    {"v1 not_delivered -> v2 pending attempt 2",
     [{1, "a", "pending", 1}, {1, "a", "not_delivered", 1}, {2, "a", "pending", 2}],
     {2, "pending", 2, 3}},
    {"v2 pending -> v1 ambiguous", [{2, "a", "pending", 1}, {1, "a", "ambiguous", 1}],
     {1, "ambiguous", 1, 2}},
    {"v2 queued -> v1 ambiguous",
     [{2, "a", "pending", 1}, {2, "a", "queued", 1}, {1, "a", "ambiguous", 1}],
     {1, "ambiguous", 1, 3}},
    {"v2 paste_started -> v1 ambiguous",
     [{2, "a", "pending", 1}, {2, "a", "paste_started", 1}, {1, "a", "ambiguous", 1}],
     {1, "ambiguous", 1, 3}},
    {"v2 not_delivered -> v1 pending attempt 2",
     [{2, "a", "pending", 1}, {2, "a", "not_delivered", 1}, {1, "a", "pending", 2}],
     {1, "pending", 2, 3}},
    {"v2 paste_started -> v2 delivered",
     [{2, "a", "pending", 1}, {2, "a", "paste_started", 1}, {2, "a", "delivered", 1}],
     {2, "delivered", 1, 3}}
  ]

  for {label, rows, final} <- allowed do
    test "R0.3 allowed edge loads: #{label}", %{inbox: dir} do
      rows = unquote(Macro.escape(rows))
      write_log!(dir, chain(rows))
      assert_opens!(dir, length(rows), %{"a" => unquote(Macro.escape(final))})
    end
  end

  forbidden = [
    {"v1 pending -> v2 paste_started", [{1, "a", "pending", 1}, {2, "a", "paste_started", 1}], 2},
    {"v1 queued -> v2 paste_started",
     [{1, "a", "pending", 1}, {1, "a", "queued", 1}, {2, "a", "paste_started", 1}], 3},
    {"v2 paste_started -> v2 not_delivered",
     [{2, "a", "pending", 1}, {2, "a", "paste_started", 1}, {2, "a", "not_delivered", 1}], 3},
    {"v2 paste_started -> v1 not_delivered",
     [{2, "a", "pending", 1}, {2, "a", "paste_started", 1}, {1, "a", "not_delivered", 1}], 3},
    {"v2 delivered -> v1 ambiguous",
     [{2, "a", "pending", 1}, {2, "a", "delivered", 1}, {1, "a", "ambiguous", 1}], 3}
  ]

  for {label, rows, seq} <- forbidden do
    test "R0.4 forbidden edge is corrupt at its line, bytes unchanged: #{label}", %{inbox: dir} do
      rows = unquote(Macro.escape(rows))
      write_log!(dir, chain(rows))
      assert_refuses!(dir, {:receipt_log_corrupt, unquote(seq)})
    end
  end

  # Within one attempt only the boot-finalization edges (nonterminal -> ambiguous) may change
  # version. Every other cross-version edge would let one writer's attempt acquire the other
  # writer's records (e.g. a v1 attempt a v2 queued record that looks marker-attested), so it
  # is corrupt at the first cross-version line. {label, rows, corrupt seq}
  laundering = [
    {"v1 pending -> v2 queued", [{1, "a", "pending", 1}, {2, "a", "queued", 1}], 2},
    {"v1 pending -> v2 queued -> v2 paste_started",
     [{1, "a", "pending", 1}, {2, "a", "queued", 1}, {2, "a", "paste_started", 1}], 2},
    {"v1 pending -> v2 delivered", [{1, "a", "pending", 1}, {2, "a", "delivered", 1}], 2},
    {"v1 pending -> v2 not_delivered", [{1, "a", "pending", 1}, {2, "a", "not_delivered", 1}], 2},
    {"v1 queued -> v2 delivered",
     [{1, "a", "pending", 1}, {1, "a", "queued", 1}, {2, "a", "delivered", 1}], 3},
    {"v1 queued -> v2 not_delivered",
     [{1, "a", "pending", 1}, {1, "a", "queued", 1}, {2, "a", "not_delivered", 1}], 3},
    {"v2 pending -> v1 queued", [{2, "a", "pending", 1}, {1, "a", "queued", 1}], 2},
    {"v2 pending -> v1 queued -> v1 delivered",
     [{2, "a", "pending", 1}, {1, "a", "queued", 1}, {1, "a", "delivered", 1}], 2},
    {"v2 pending -> v1 delivered", [{2, "a", "pending", 1}, {1, "a", "delivered", 1}], 2},
    {"v2 pending -> v1 not_delivered", [{2, "a", "pending", 1}, {1, "a", "not_delivered", 1}], 2},
    {"v2 queued -> v1 delivered",
     [{2, "a", "pending", 1}, {2, "a", "queued", 1}, {1, "a", "delivered", 1}], 3},
    {"v2 queued -> v1 not_delivered",
     [{2, "a", "pending", 1}, {2, "a", "queued", 1}, {1, "a", "not_delivered", 1}], 3},
    {"v2 paste_started -> v1 delivered",
     [{2, "a", "pending", 1}, {2, "a", "paste_started", 1}, {1, "a", "delivered", 1}], 3}
  ]

  for {label, rows, seq} <- laundering do
    test "R0.9 same-attempt cross-version edge is corrupt, bytes unchanged: #{label}", %{
      inbox: dir
    } do
      rows = unquote(Macro.escape(rows))
      write_log!(dir, chain(rows))
      assert_refuses!(dir, {:receipt_log_corrupt, unquote(seq)})
    end
  end

  test "R0.5 control: paste_started in a version 1 line is corrupt", %{inbox: dir} do
    write_log!(dir, chain([{1, "a", "pending", 1}, {1, "a", "paste_started", 1}]))
    assert_refuses!(dir, {:receipt_log_corrupt, 2})
  end

  # NS-15.G.003 S0b re-point: the store now writes version 2, so boot finalization appends
  # version 2 ambiguous records (S0a appended version 1). The byte-identical prefix and the
  # exact reopened entries are kept.
  test "R0.6 a store boot finalizes v2 non-terminal attempts as ambiguous after the original log",
       %{
         inbox: dir
       } do
    history =
      chain([
        {2, "a", "pending", 1},
        {2, "b", "pending", 1},
        {2, "b", "queued", 1},
        {2, "c", "pending", 1},
        {2, "c", "paste_started", 1}
      ])

    write_log!(dir, history)
    original = File.read!(log_path(dir))
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: dir)
    GenServer.stop(pid)

    after_boot = File.read!(log_path(dir))
    assert byte_size(after_boot) > byte_size(original)

    assert binary_part(after_boot, 0, byte_size(original)) == original,
           "boot appends only; the original log prefix stays byte-identical"

    appended = Enum.drop(log_lines(dir), 5)

    assert Enum.map(appended, &{&1["message_id"], &1["status"], &1["schema_version"]}) ==
             [{id("a"), "ambiguous", 2}, {id("b"), "ambiguous", 2}, {id("c"), "ambiguous", 2}]

    assert_opens!(dir, 8, %{
      "a" => {2, "ambiguous", 1, 6},
      "b" => {2, "ambiguous", 1, 7},
      "c" => {2, "ambiguous", 1, 8}
    })
  end

  # NS-15.G.003 S0b re-point: every record the store appends after v2 history is now version 2,
  # and begin_paste appends a durable paste_started marker before the delivered record (S0a
  # appended version 1 records and no marker). The byte-identical prefix and the exact
  # sequence are kept; the reopened seq grows by the marker.
  test "R0.7 every status the store appends after loading v2 history is version 2, with the marker",
       %{
         inbox: dir
       } do
    write_log!(dir, chain([{2, "a", "pending", 1}, {2, "a", "delivered", 1}]))
    original = File.read!(log_path(dir))
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: dir)

    try do
      assert {:ok, {:admitted, %{operation_token: x_token}}} =
               ReceiptStore.admit(pid, id("x"), @pane, @payload, self())

      assert :ok = ReceiptStore.transition(pid, id("x"), x_token, "queued")
      assert :ok = ReceiptStore.begin_paste(pid, id("x"), x_token)
      assert :ok = ReceiptStore.transition(pid, id("x"), x_token, "delivered")

      assert {:ok, {:admitted, %{operation_token: y_token}}} =
               ReceiptStore.admit(pid, id("y"), @pane, @payload, self())

      assert :ok = ReceiptStore.transition(pid, id("y"), y_token, "not_delivered")

      assert {:ok, {:admitted, %{operation_token: _}}} =
               ReceiptStore.admit(pid, id("y"), @pane, @payload, self())
    after
      GenServer.stop(pid)
    end

    after_run = File.read!(log_path(dir))
    assert binary_part(after_run, 0, byte_size(original)) == original

    appended = Enum.drop(log_lines(dir), 2)

    assert Enum.map(appended, fn r ->
             {r["message_id"], r["status"], r["delivery_attempt"], r["schema_version"]}
           end) == [
             {id("x"), "pending", 1, 2},
             {id("x"), "queued", 1, 2},
             {id("x"), "paste_started", 1, 2},
             {id("x"), "delivered", 1, 2},
             {id("y"), "pending", 1, 2},
             {id("y"), "not_delivered", 1, 2},
             {id("y"), "pending", 2, 2}
           ]

    assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)
    ReceiptLog.close(log)
    assert log.seq == 9
  end

  # ----- helpers -----

  # Builds correctly chained, newline-terminated lines from {version, seed, status, attempt}.
  defp chain(rows) do
    {lines, _prev} =
      rows
      |> Enum.with_index(1)
      |> Enum.map_reduce(@anchor, fn {{version, seed, status, attempt}, seq}, prev ->
        line = Jason.encode!(record(seq, prev, version, seed, status, attempt)) <> "\n"
        {line, digest(line)}
      end)

    lines
  end

  defp record(seq, prev, version, seed, status, attempt) do
    %{
      "schema" => @schema,
      "schema_version" => version,
      "seq" => seq,
      "prev_line_sha256" => prev,
      "daemon_epoch" => @epoch,
      "message_id" => id(seed),
      "pane_id" => @pane,
      "payload_hash" => @payload,
      "status" => status,
      "delivery_attempt" => attempt
    }
  end

  # `finals` maps each seed to the exact replayed entry {version, status, attempt, seq};
  # the replayed entry set must be exactly these message ids.
  defp assert_opens!(dir, seq, finals) do
    assert {:ok, log} = ReceiptLog.open(SystemFs.new(), dir)

    try do
      assert log.seq == seq
      assert Enum.sort(Map.keys(log.entries)) == Enum.sort(Enum.map(Map.keys(finals), &id/1))

      for {seed, {version, status, attempt, at}} <- finals do
        entry = Map.fetch!(log.entries, id(seed))

        assert %{
                 "schema" => @schema,
                 "schema_version" => ^version,
                 "seq" => ^at,
                 "pane_id" => @pane,
                 "payload_hash" => @payload,
                 "status" => ^status,
                 "delivery_attempt" => ^attempt
               } = entry

        assert entry["message_id"] == id(seed)
      end
    after
      ReceiptLog.close(log)
    end
  end

  defp assert_refuses!(dir, reason) do
    path = log_path(dir)
    before = File.read!(path)
    result = ReceiptLog.open(SystemFs.new(), dir)
    with {:ok, log} <- result, do: ReceiptLog.close(log)

    assert result == {:error, reason}, "ReceiptLog.open must refuse with the exact reason"
    assert File.read!(path) == before, "a refused log is left byte-unchanged"
  end

  defp write_log!(dir, lines) do
    path = log_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines))
  end

  defp log_lines(dir),
    do:
      dir
      |> log_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

  defp log_path(dir), do: Path.join([dir, "delivery", "receipts.jsonl"])

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
