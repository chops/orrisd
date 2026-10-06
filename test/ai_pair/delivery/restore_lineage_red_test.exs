defmodule AiPair.Delivery.RestoreLineageRedTest do
  @moduledoc """
  NS-15.G.003 S2 (design r4, RED design r3), store level: the per-epoch lineage attestation,
  its single fail-closed branch, epoch ranges, and the restore predicate at boot.

  Row classes (RED design r3 "Row classification"):

    * INDEPENDENT RED: L1, L3, L4, L5, L6, L7. Each fails at Orrisd ff960018 on its own
      named behaviour, which is its first assertion.
    * DEPENDENT RED: P10. Its first assertion is the shared restore prerequisite (a queued
      attempt is still queued after a restart); its capacity assertion is GREEN contract.
    * CONTROLS: A0, L2, P1-P9. Fail-closed behaviour that already holds at the base; they
      pass there, assert only base-observable behaviour and call no S2 function.

  Fixture rule: receipt and lineage lines are hand-built with the same encoding and chaining
  ReceiptLog uses (Jason, "\\n", prev_line_sha256 = "sha256:" <> hex of the previous full
  line, anchored at the digest of ""). A0 proves a hand-built receipt fixture opens at base.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  # Neither the pane id nor the inbox name may contain "lineage": the L6 fault matcher keys on it.
  @pane "%restore_s2_a"
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @writer "payload-marker-1"

  setup do
    inbox = Path.join(System.tmp_dir!(), "restore_s2_a_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  # ===== controls (pass at base; must stay green) =====

  test "A0 control: a hand-built receipt fixture opens and is read back", c do
    append_receipts!(c.inbox, ep(), [{id("a0"), "a0 bytes", "pending", 1, 2}])
    store = start_store!(c.inbox, SystemFs.new())
    assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, id("a0"), "a0 bytes")
    stop(store)
  end

  test "L2 control: no lineage file, a prior queued attempt with an object is finalized ambiguous",
       c do
    {msg, text} = queued_under_real_store!(c.inbox, "l2")
    File.rm(lineage_path(c.inbox))
    assert File.exists?(object_path(c.inbox, msg, 1, text))

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    refute File.exists?(object_path(c.inbox, msg, 1, text))
    stop(store)
  end

  test "P1 control: an S0b-style v2 queued record with no object is ambiguous after boot", c do
    msg = id("p1")

    append_receipts!(c.inbox, ep(), [
      {msg, "p1 bytes", "pending", 1, 2},
      {msg, "p1 bytes", "queued", 1, 2}
    ])

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    stop(store)
  end

  test "P2 control: a v1 queued record with a hand-made matching object is ambiguous, object removed",
       c do
    msg = id("p2")

    append_receipts!(c.inbox, ep(), [
      {msg, "p2 bytes", "pending", 1, 1},
      {msg, "p2 bytes", "queued", 1, 1}
    ])

    path = write_object!(c.inbox, msg, 1, "p2 bytes")

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    refute File.exists?(path)
    stop(store)
  end

  for {label, damage} <- [
        missing: :missing,
        tampered: :tampered,
        symlinked: :symlink,
        misnamed: :misnamed
      ] do
    test "P3 control: a #{label} object makes its queued attempt ambiguous and leaves no entry",
         c do
      text = "p3 #{unquote(label)} bytes"
      {msg, ^text} = queued_under_real_store!(c.inbox, "p3-#{unquote(label)}", text)
      path = object_path(c.inbox, msg, 1, text)
      damage!(unquote(damage), c.inbox, path)

      store = start_store!(c.inbox, SystemFs.new())
      assert last_status(c.inbox, msg) == {"ambiguous", 1}
      assert payload_entries(c.inbox) == []
      stop(store)
    end
  end

  test "P4 control: a queued attempt with paste_started and an object is ambiguous, object removed",
       c do
    text = "p4 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "p4", text)
    # RS3: the real store wrote this attempt's queued record as version 3, and a version 2
    # line after it within the same attempt is corruption, so the marker is version 3.
    append_receipts!(c.inbox, ep(), [{msg, text, "paste_started", 1, 3}])

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    refute File.exists?(object_path(c.inbox, msg, 1, text))
    stop(store)
  end

  test "P5 control (vacuous at base; discriminating at GREEN with L3): another attempt's object restores nothing",
       c do
    text = "p5 bytes"
    msg = id("p5")

    append_receipts!(c.inbox, ep(), [
      {msg, text, "pending", 1, 2},
      {msg, text, "not_delivered", 1, 2},
      {msg, text, "pending", 2, 2},
      {msg, text, "queued", 2, 2}
    ])

    write_object!(c.inbox, msg, 1, text)

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 2}
    stop(store)
  end

  test "P6 control: a boot that finalized the queued attempt ambiguous leaves the next boot nothing to restore",
       c do
    text = "p6 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "p6", text)
    # RS3: the queued record is version 3 and no version 2 line may follow it within the attempt
    # (a pre-RS3 build cannot open this log at all), so the finalizing line is version 3.
    append_receipts!(c.inbox, ep(), [{msg, text, "ambiguous", 1, 3}])

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    refute File.exists?(object_path(c.inbox, msg, 1, text))
    stop(store)
  end

  test "P7 control: a corrupt receipt log refuses the store with the log and every object byte-unchanged",
       c do
    {_msg, _text} = queued_under_real_store!(c.inbox, "p7")
    log = receipts_path(c.inbox)
    File.write!(log, File.read!(log) <> ~s({"not":"a receipt"}\n))
    before = digest_tree(c.inbox)

    assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new())
    assert digest_tree(c.inbox) == before
  end

  test "P8 control: a pending attempt is ambiguous after a restart", c do
    store = start_store!(c.inbox, SystemFs.new())
    {msg, _token} = admit!(store, "p8", "p8 bytes")
    stop(store)

    revived = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    stop(revived)
  end

  test "P9 control: a delivered msg_id is a duplicate after a restart", c do
    store = start_store!(c.inbox, SystemFs.new())
    {msg, token} = admit!(store, "p9", "p9 bytes")
    :ok = ReceiptStore.begin_paste(store, msg, token)
    :ok = ReceiptStore.transition(store, msg, token, "delivered")
    stop(store)

    revived = start_store!(c.inbox, SystemFs.new())
    assert {:ok, {:duplicate, %{status: "delivered"}}} = admit(revived, msg, "p9 bytes")
    stop(revived)
  end

  # ===== independent RED rows =====

  test "L1 the first S2 boot attests its epoch in lineage.jsonl before any receipt of that epoch",
       c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)

    assert File.exists?(lineage_path(c.inbox)), "no lineage attestation was written at boot"
    assert Bitwise.band(File.lstat!(lineage_path(c.inbox)).mode, 0o777) == 0o600

    assert [record] = lineage_records(c.inbox)

    assert record == %{
             "schema" => "ai-pair/delivery-lineage",
             "schema_version" => 1,
             "seq" => 1,
             "prev_line_sha256" => @anchor,
             "daemon_epoch" => ReceiptStore.daemon_epoch(store),
             "writer" => @writer,
             "first_receipt_seq" => 1
           }

    {_msg, _token} = admit!(store, "l1", "l1 bytes")
    trace = FaultFs.trace(fs)
    lineage_write = Enum.find_index(trace, &lineage_write?/1)
    receipt_write = Enum.find_index(trace, &receipt_write?/1)
    assert is_integer(lineage_write) and is_integer(receipt_write) and lineage_write < receipt_write

    # The lineage record's fsync (the first sync after its write) and the first-creation
    # directory sync naming lineage.jsonl both precede the epoch's first receipt write.
    lineage_sync =
      trace
      |> Enum.with_index()
      |> Enum.find_value(fn {op, i} -> if i > lineage_write and match?({:sync, _}, op), do: i end)

    lineage_dir_sync =
      Enum.find_index(trace, fn
        {:dir_sync, args} -> lineage_args?(args)
        _ -> false
      end)

    assert is_integer(lineage_sync) and lineage_sync < receipt_write
    assert is_integer(lineage_dir_sync) and lineage_dir_sync < receipt_write
    stop(store)
  end

  test "L3 a queued attempt of an attested epoch with a verified object stays queued across a restart",
       c do
    text = "l3 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "l3", text)
    before = statuses(c.inbox, msg)

    revived = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"queued", 1}, "a restorable queued attempt was finalized"
    assert statuses(c.inbox, msg) == before, "no record may be appended for a restored attempt"
    assert File.exists?(object_path(c.inbox, msg, 1, text))
    assert %{@pane => [%{msg_id: ^msg, holder: nil}]} = registry(revived)
    stop(revived)
  end

  # Dependent on the restore prerequisite: L2's registry clause, which a base-passing control
  # cannot assert (it would call an S2 function).
  test "L2R once lineage is gone, the next boot finalizes the restored attempt and lists nothing",
       c do
    text = "l2r bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "l2r", text)

    revived = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"queued", 1}, "shared restore prerequisite"
    assert %{@pane => [%{msg_id: ^msg, holder: nil}]} = registry(revived)
    stop(revived)

    File.rm!(lineage_path(c.inbox))
    unattested = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"ambiguous", 1}
    refute File.exists?(object_path(c.inbox, msg, 1, text))
    assert registry(unattested) == %{}
    stop(unattested)
  end

  for {label, mutate} <- [
        chain_gap: :chain_gap,
        duplicate_epoch: :duplicate_epoch,
        unknown_writer: :unknown_writer,
        invalid_shape: :invalid_shape,
        decreasing_first_seq: :decreasing,
        first_seq_beyond_log: :beyond_log,
        undecodable_middle_line: :middle_garbage
      ] do
    test "L4 a lineage file with #{label} refuses the whole store unchanged", c do
      {_msg, _text} = queued_under_real_store!(c.inbox, "l4-#{unquote(label)}")
      epochs = receipt_epochs(c.inbox)

      File.write!(
        lineage_path(c.inbox),
        corrupt_lineage(unquote(mutate), epochs, receipt_seq(c.inbox))
      )

      before = digest_tree(c.inbox)

      assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new()),
             "a #{unquote(label)} lineage must refuse the store"

      assert digest_tree(c.inbox) == before
    end
  end

  test "L5 a torn final lineage line is truncated and the new epoch is appended", c do
    {_msg, _text} = queued_under_real_store!(c.inbox, "l5")
    [e1 | _] = receipt_epochs(c.inbox)

    File.write!(
      lineage_path(c.inbox),
      lineage_file([{e1, @writer, 1}]) <> ~s({"schema":"ai-pair/delivery-lin)
    )

    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)

    refute File.read!(lineage_path(c.inbox)) =~ ~s(lin{"schema"),
           "the torn final fragment must be truncated before the new record"

    assert String.ends_with?(File.read!(lineage_path(c.inbox)), "\n"),
           "the torn final fragment must be truncated"

    records = lineage_records(c.inbox)
    assert length(records) == 2, "the torn line must be repaired and one new epoch record appended"
    assert List.last(records)["daemon_epoch"] == ReceiptStore.daemon_epoch(store)

    # The truncation is made durable (a sync after it) before the new record is written.
    trace = FaultFs.trace(fs)

    truncate =
      Enum.find_index(trace, fn
        {:truncate, args} -> lineage_args?(args)
        _ -> false
      end)

    record_write = Enum.find_index(trace, &lineage_write?/1)
    assert is_integer(truncate) and is_integer(record_write) and truncate < record_write

    assert trace
           |> Enum.slice((truncate + 1)..(record_write - 1)//1)
           |> Enum.any?(&match?({:sync, _}, &1)),
           "the truncation must be fsynced before the new record is appended"

    stop(store)
  end

  # On a fresh inbox the first write and the first sync of a boot are the lineage
  # attestation's (no receipt exists to finalize), and the lineage directory sync names the
  # lineage path (GREEN contract: dir_sync(fs, <inbox>/delivery/lineage.jsonl), as ReceiptLog
  # syncs its own path).
  for op <- [:write, :sync, :dir_sync] do
    test "L6 a lineage #{op} fault at boot stops the store before any receipt", c do
      fs = FaultFs.new()

      if unquote(op) == :dir_sync,
        do: FaultFs.inject(fs, :dir_sync, &lineage_args?/1, {:error, :eio}),
        else: FaultFs.inject(fs, unquote(op), 1, {:error, :eio})

      assert {:error, :lineage_unavailable} =
               GenServer.start(ReceiptStore, inbox: c.inbox, fs: fs)

      assert receipt_seq(c.inbox) == 0, "no receipt may be appended in an unattested epoch"

      store = start_store!(c.inbox, SystemFs.new())
      assert List.last(lineage_records(c.inbox))["daemon_epoch"] == ReceiptStore.daemon_epoch(store)
      stop(store)
    end
  end

  test "L7 an attested epoch's record beyond its range refuses the store", c do
    {_msg, _text} = queued_under_real_store!(c.inbox, "l7-range")
    [e1 | _] = receipt_epochs(c.inbox)
    second = start_store!(c.inbox, SystemFs.new())
    # the second epoch writes one receipt so its range is non-empty before e1 reappears
    {_m2, _t2} = admit!(second, "l7-second", "second bytes")
    stop(second)
    append_receipts!(c.inbox, e1, [{id("l7-late"), "late bytes", "pending", 1, 2}])
    before = digest_tree(c.inbox)

    assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new())
    assert digest_tree(c.inbox) == before
  end

  test "L7 an attested record after a foreign-epoch record inside the same range refuses the store",
       c do
    {_msg, _text} = queued_under_real_store!(c.inbox, "l7-interleave")
    [e1 | _] = receipt_epochs(c.inbox)
    append_receipts!(c.inbox, ep(), [{id("l7-foreign"), "foreign bytes", "pending", 1, 2}])
    append_receipts!(c.inbox, e1, [{id("l7-after"), "after bytes", "pending", 1, 2}])
    before = digest_tree(c.inbox)

    assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new())
    assert digest_tree(c.inbox) == before
  end

  test "L7 a rollback range: the attested epoch's queued attempt restores, the foreign one does not",
       c do
    text = "l7 attested bytes"
    {kept, ^text} = queued_under_real_store!(c.inbox, "l7-kept", text)
    foreign = id("l7-rollback")

    append_receipts!(c.inbox, ep(), [
      {foreign, "rollback bytes", "pending", 1, 2},
      {foreign, "rollback bytes", "queued", 1, 2}
    ])

    write_object!(c.inbox, foreign, 1, "rollback bytes")

    store = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, kept) == {"queued", 1}, "the attested epoch's attempt must restore"
    assert last_status(c.inbox, foreign) == {"ambiguous", 1}
    stop(store)
  end

  test "L7 a queued record below its attested epoch's first_receipt_seq refuses the store", c do
    {_msg, _text} = queued_under_real_store!(c.inbox, "l7-below")
    [e1 | _] = receipt_epochs(c.inbox)
    File.write!(lineage_path(c.inbox), lineage_file([{e1, @writer, 2}]))
    before = digest_tree(c.inbox)

    assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new())
    assert digest_tree(c.inbox) == before
  end

  # Design r5: an epoch with no receipt leaves the next boot's first_receipt_seq equal; equal
  # values give the earlier epoch an empty range and never refuse the store.
  test "L8 three no-traffic boots each attest; a fourth boot's queued attempt restores on the fifth",
       c do
    for _ <- 1..3, do: c.inbox |> start_store!(SystemFs.new()) |> stop()

    assert length(lineage_records(c.inbox)) == 3, "each no-traffic boot attests its epoch"
    assert Enum.all?(lineage_records(c.inbox), &(&1["first_receipt_seq"] == 1))

    text = "l8 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "l8", text)

    revived = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"queued", 1}
    assert length(lineage_records(c.inbox)) == 5
    stop(revived)
  end

  test "L9 an aborted attestation (sync fault) is retried by the next boot, which then restores",
       c do
    fs = FaultFs.new()
    FaultFs.inject(fs, :sync, 1, {:error, :eio})

    assert {:error, :lineage_unavailable} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: fs)
    assert receipt_seq(c.inbox) == 0

    text = "l9 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "l9", text)
    assert Enum.all?(lineage_records(c.inbox), &(&1["first_receipt_seq"] == 1))

    revived = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, msg) == {"queued", 1}, "the retried epoch's attempt must restore"
    stop(revived)
  end

  # ===== dependent RED (shared restore prerequisite first; capacity is GREEN contract) =====

  test "P10 dependent: retained restored objects count against the object limit", c do
    text = "p10 bytes"
    {msg, ^text} = queued_under_real_store!(c.inbox, "p10", text)

    revived = start_store!(c.inbox, SystemFs.new(), payload_limit_objects: 1)
    assert last_status(c.inbox, msg) == {"queued", 1}, "shared restore prerequisite"
    assert File.exists?(object_path(c.inbox, msg, 1, text))

    {next, token} = admit!(revived, "p10-next", "p10 next bytes")
    assert queue(revived, next, token, "p10 next bytes") == {:error, :payload_store_full}
    stop(revived)
  end

  # ===== helpers =====

  # Admits and queues one attempt under a real store (whose epoch an S2 build attests), stops it.
  defp queued_under_real_store!(inbox, seed, text \\ nil) do
    text = text || seed <> " bytes"
    store = start_store!(inbox, SystemFs.new())
    {msg, token} = admit!(store, seed, text)
    assert :ok = queue(store, msg, token, text)
    stop(store)
    {msg, text}
  end

  defp damage!(:missing, _inbox, path), do: File.rm!(path)

  defp damage!(:tampered, _inbox, path) do
    File.chmod!(path, 0o600)
    File.write!(path, "tampered bytes")
    File.chmod!(path, 0o600)
  end

  defp damage!(:symlink, inbox, path) do
    target = Path.join(inbox, "outside")
    File.write!(target, File.read!(path))
    File.rm!(path)
    :ok = File.ln_s(target, path)
  end

  defp damage!(:misnamed, _inbox, path) do
    File.rename!(
      path,
      String.replace(
        path,
        ~r/\.[0-9a-f]{64}\.payload\z/,
        "." <> String.duplicate("e", 64) <> ".payload"
      )
    )
  end

  defp corrupt_lineage(:chain_gap, [e | _], _seq) do
    [line] = lineage_lines([{e, @writer, 1}])
    String.replace(line, @anchor, "sha256:" <> String.duplicate("0", 64)) <> "\n"
  end

  defp corrupt_lineage(:duplicate_epoch, [e | _], seq),
    do: lineage_file([{e, @writer, 1}, {e, @writer, seq + 1}])

  defp corrupt_lineage(:unknown_writer, [e | _], _seq),
    do: lineage_file([{e, "payload-marker-0", 1}])

  defp corrupt_lineage(:invalid_shape, [e | _], _seq) do
    Jason.encode!(%{
      "schema" => "ai-pair/delivery-lineage",
      "schema_version" => 1,
      "seq" => 1,
      "daemon_epoch" => e
    }) <> "\n"
  end

  # Design r5: equal values are legal (an empty range); only a decrease is refused. The unused
  # epoch has no records and the log's epoch run starts at its own value, so only order fails.
  defp corrupt_lineage(:decreasing, [e | _], _seq),
    do: lineage_file([{ep(), @writer, 2}, {e, @writer, 1}])

  defp corrupt_lineage(:beyond_log, [e | _], seq), do: lineage_file([{e, @writer, seq + 5}])

  defp corrupt_lineage(:middle_garbage, [e | _], seq) do
    [a, b] = lineage_lines([{e, @writer, 1}, {ep(), @writer, seq + 1}])
    a <> "\n" <> "not json\n" <> b <> "\n"
  end

  defp lineage_file(entries), do: Enum.map_join(lineage_lines(entries), "", &(&1 <> "\n"))

  defp lineage_lines(entries) do
    {lines, _} =
      entries
      |> Enum.with_index(1)
      |> Enum.map_reduce(@anchor, fn {{epoch, writer, first}, seq}, prev ->
        line =
          Jason.encode!(%{
            "schema" => "ai-pair/delivery-lineage",
            "schema_version" => 1,
            "seq" => seq,
            "prev_line_sha256" => prev,
            "daemon_epoch" => epoch,
            "writer" => writer,
            "first_receipt_seq" => first
          })

        {line, digest(line <> "\n")}
      end)

    lines
  end

  # Appends chained receipt records {msg_id, text, status, attempt, version} under `epoch`.
  defp append_receipts!(inbox, epoch, records) do
    File.mkdir_p!(Path.dirname(receipts_path(inbox)))
    File.chmod!(Path.dirname(receipts_path(inbox)), 0o700)
    {seq, prev} = chain_state(inbox)

    {lines, _} =
      Enum.map_reduce(records, {seq, prev}, fn {msg, text, status, attempt, version}, {s, p} ->
        record =
          with_pair(
            %{
              "schema" => "ai-pair/delivery-receipt",
              "schema_version" => version,
              "seq" => s + 1,
              "prev_line_sha256" => p,
              "daemon_epoch" => epoch,
              "message_id" => msg,
              "pane_id" => @pane,
              "payload_hash" => hash(text),
              "status" => status,
              "delivery_attempt" => attempt
            },
            version
          )

        line = Jason.encode!(record) <> "\n"

        {line, {s + 1, digest(line)}}
      end)

    File.write!(receipts_path(inbox), Enum.join(lines), [:append])
    File.chmod!(receipts_path(inbox), 0o600)
  end

  # RS3: a version 3 record carries the attempt's registration pair (null here).
  defp with_pair(record, 3), do: Map.merge(record, %{"registration_id" => nil, "generation" => nil})
  defp with_pair(record, _version), do: record

  defp chain_state(inbox) do
    case File.read(receipts_path(inbox)) do
      {:ok, bytes} ->
        lines = String.split(bytes, "\n", trim: true)

        case List.last(lines) do
          nil -> {0, @anchor}
          last -> {Jason.decode!(last)["seq"], digest(last <> "\n")}
        end

      {:error, :enoent} ->
        {0, @anchor}
    end
  end

  defp write_object!(inbox, msg, attempt, text) do
    dir = Path.dirname(object_path(inbox, msg, attempt, text))
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = object_path(inbox, msg, attempt, text)
    File.write!(path, text)
    File.chmod!(path, 0o600)
    path
  end

  defp receipt_records(inbox) do
    case File.read(receipts_path(inbox)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp receipt_seq(inbox), do: length(receipt_records(inbox))

  defp receipt_epochs(inbox),
    do: inbox |> receipt_records() |> Enum.map(& &1["daemon_epoch"]) |> Enum.uniq()

  defp statuses(inbox, msg) do
    for r <- receipt_records(inbox),
        r["message_id"] == msg,
        do: {r["status"], r["delivery_attempt"]}
  end

  defp last_status(inbox, msg), do: List.last(statuses(inbox, msg))

  defp lineage_records(inbox) do
    case File.read(lineage_path(inbox)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp lineage_write?({:write, [_fd, bytes]}),
    do: is_binary(bytes) and bytes =~ "ai-pair/delivery-lineage"

  defp lineage_write?(_), do: false

  defp receipt_write?({:write, [_fd, bytes]}),
    do: is_binary(bytes) and bytes =~ "ai-pair/delivery-receipt"

  defp receipt_write?(_), do: false

  # FaultFs matcher: an operation whose arguments touch the lineage file or carry a lineage line.
  defp lineage_args?(args) do
    Enum.any?(args, fn
      arg when is_binary(arg) -> String.ends_with?(arg, "lineage.jsonl")
      _ -> false
    end)
  end

  # Path -> sha256 of every regular file and symlink target under the inbox.
  defp digest_tree(inbox) do
    inbox
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Map.new(fn path ->
      case File.lstat!(path).type do
        :regular -> {path, :crypto.hash(:sha256, File.read!(path))}
        :symlink -> {path, {:link, File.read_link!(path)}}
        other -> {path, other}
      end
    end)
  end

  defp queue(store, msg, token, text), do: ReceiptStore.queue(store, msg, token, text)

  defp start_store!(inbox, fs, opts \\ []) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, [inbox: inbox, fs: fs] ++ opts)
    pid
  end

  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp admit(store, msg, text), do: ReceiptStore.admit(store, msg, @pane, hash(text), self())

  defp admit!(store, seed, text) do
    msg = id(seed)
    assert {:ok, {:admitted, %{operation_token: token}}} = admit(store, msg, text)
    {msg, token}
  end

  # S2 status read, reached through apply/3 so the file compiles against the base.
  defp registry(store), do: apply(ReceiptStore, :restore_registry, [store])

  defp reconcile(store, msg, text),
    do: ReceiptStore.reconcile(store, msg, @pane, hash(text), wait_ms: 0)

  defp receipts_path(inbox), do: Path.join([inbox, "delivery", "receipts.jsonl"])
  defp lineage_path(inbox), do: Path.join([inbox, "delivery", "lineage.jsonl"])

  defp object_path(inbox, msg, attempt, text) do
    "sha256:" <> hex = hash(text)
    Path.join([inbox, "delivery", "payloads", "#{msg}.#{attempt}.#{hex}.payload"])
  end

  defp payload_entries(inbox) do
    case File.ls(Path.join([inbox, "delivery", "payloads"])) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  defp ep, do: "ep_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  defp hash(text), do: Payload.hash(Payload.new(text))
  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
