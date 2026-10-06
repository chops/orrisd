defmodule AiPair.Delivery.ReceiptWriterV2RedTest do
  @moduledoc """
  NS-15.G.003 S0b (scope r2, RED design r3), store level: the receipt writer writes schema
  version 2 and `begin_paste` makes a version 2 `paste_started` record durable before it
  answers `:ok`.

  Rows:

    * W1 every record an S0b store appends is version 2, including `paste_started`.
    * W2 `begin_paste` appends exactly one marker and fsyncs it before replying `:ok`.
    * W3 a failed marker write (write error, torn prefix, complete line then error, fsync
      error) answers `receipt_store_unavailable`, poisons the store and appends nothing more.
    * W4 a restart after each W3 fault follows the design r3 boot table: the attempt ends
      ambiguous, a torn tail is repaired first, and no `not_delivered` is ever appended.
    * W5 transitions out of `paste_started`.
    * W6 boot over mixed history: v1 nonterminal and v2 queued-without-marker become v2
      ambiguous; nothing is restored.
    * W7 a live `paste_started` on the immediate path is projected as `pending` in every reply.
    * W7b a live `paste_started` on a queued attempt is projected as `queued` (its status
      before the marker), so the v2 replies stay unchanged.

  W8 (a pre-S0a reader on an S0b log) is a documented limit, not a row: no version-1-only
  reader exists in this tree (see the RED source packet).

  Expected at Orrisd 9faf41c3: every row fails, because `begin_paste` writes nothing and
  the writer writes version 1.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{ReceiptLog, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  @schema "ai-pair/delivery-receipt"
  @pane "%receiptwriter_v2"
  @payload "sha256:" <> String.duplicate("e7", 32)
  @epoch "ep_" <> String.duplicate("2e", 12)
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  setup do
    inbox = Path.join(System.tmp_dir!(), "receiptwriter_v2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  test "W1 every record an S0b store appends is version 2", %{inbox: dir} do
    store = start_store!(dir, SystemFs.new())

    try do
      x = admit!(store, id("x"))
      assert :ok = ReceiptStore.transition(store, id("x"), x, "queued")
      assert :ok = ReceiptStore.begin_paste(store, id("x"), x)
      assert :ok = ReceiptStore.transition(store, id("x"), x, "delivered")
      y = admit!(store, id("y"))
      assert :ok = ReceiptStore.transition(store, id("y"), y, "not_delivered")
      admit!(store, id("y"))
    after
      stop(store)
    end

    assert Enum.map(
             log_lines(dir),
             &{&1["message_id"], &1["status"], &1["delivery_attempt"], &1["schema_version"]}
           ) ==
             [
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
    assert log.seq == 7
  end

  test "W2 begin_paste appends exactly one marker and fsyncs it before replying :ok", %{
    inbox: dir
  } do
    fs = FaultFs.new()
    store = start_store!(dir, fs)

    try do
      token = admit!(store, id("x"))
      expected = marker_line(dir, store, id("x"), 1)
      writes = FaultFs.count(fs, :write)
      syncs = FaultFs.count(fs, :sync)
      ops_before = length(FaultFs.ops(fs))

      assert :ok = ReceiptStore.begin_paste(store, id("x"), token)

      assert FaultFs.count(fs, :write) == writes + 1
      assert FaultFs.count(fs, :sync) == syncs + 1
      assert Enum.drop(FaultFs.ops(fs), ops_before) == [:write, :sync]
      assert List.last(raw_lines(dir)) == expected
    after
      stop(store)
    end
  end

  # {label, fault target, fault}; the target is the marker write itself or the fsync after it.
  faults = [
    {"write error", :write, {:error, :eio}},
    {"torn prefix", :write, :torn_prefix},
    {"complete line then error", :write, :torn_full},
    {"fsync error", :sync, {:error, :eio}}
  ]

  for {label, op, fault} <- faults do
    test "W3 a failed marker write poisons the store and appends nothing more: #{label}", %{
      inbox: dir
    } do
      fs = FaultFs.new()
      store = start_store!(dir, fs)

      try do
        token = admit!(store, id("x"))
        inject_marker_fault!(fs, dir, store, id("x"), unquote(op), unquote(Macro.escape(fault)))

        assert ReceiptStore.begin_paste(store, id("x"), token) ==
                 {:error, :receipt_store_unavailable}

        writes = FaultFs.count(fs, :write)
        bytes = File.read!(log_path(dir))

        assert ReceiptStore.admit(store, id("z"), @pane, @payload, self()) ==
                 {:error, :receipt_store_unavailable}

        assert ReceiptStore.transition(store, id("x"), token, "not_delivered") ==
                 {:error, :receipt_store_unavailable}

        assert ReceiptStore.transition(store, id("x"), token, "delivered") ==
                 {:error, :receipt_store_unavailable}

        assert FaultFs.count(fs, :write) == writes, "nothing is written after the failed marker"
        assert File.read!(log_path(dir)) == bytes
      after
        stop(store)
      end
    end

    test "W4 a restart after a failed marker write follows the boot table: #{label}", %{
      inbox: dir
    } do
      fs = FaultFs.new()
      store = start_store!(dir, fs)

      try do
        token = admit!(store, id("x"))
        inject_marker_fault!(fs, dir, store, id("x"), unquote(op), unquote(Macro.escape(fault)))

        assert {:error, :receipt_store_unavailable} =
                 ReceiptStore.begin_paste(store, id("x"), token)
      after
        stop(store)
      end

      restarted = start_store!(dir, SystemFs.new())

      try do
        statuses = Enum.map(log_lines(dir), &{&1["status"], &1["schema_version"]})

        assert statuses == boot_expectation(unquote(op), unquote(Macro.escape(fault)))
        refute Enum.any?(log_lines(dir), &(&1["status"] == "not_delivered"))

        assert {:ok, %{outcome: "ambiguous"}} =
                 ReceiptStore.reconcile(restarted, id("x"), @pane, @payload)
      after
        stop(restarted)
      end
    end
  end

  test "W5 delivered and ambiguous follow paste_started", %{inbox: dir} do
    store = start_store!(dir, SystemFs.new())

    try do
      x = admit!(store, id("x"))
      assert :ok = ReceiptStore.begin_paste(store, id("x"), x)
      assert :ok = ReceiptStore.transition(store, id("x"), x, "delivered")
      y = admit!(store, id("y"))
      assert :ok = ReceiptStore.begin_paste(store, id("y"), y)
      assert :ok = ReceiptStore.transition(store, id("y"), y, "ambiguous")
    after
      stop(store)
    end

    assert Enum.map(log_lines(dir), &{&1["message_id"], &1["status"], &1["schema_version"]}) == [
             {id("x"), "pending", 2},
             {id("x"), "paste_started", 2},
             {id("x"), "delivered", 2},
             {id("y"), "pending", 2},
             {id("y"), "paste_started", 2},
             {id("y"), "ambiguous", 2}
           ]
  end

  test "W5 not_delivered, queued and a second begin_paste are refused after paste_started", %{
    inbox: dir
  } do
    store = start_store!(dir, SystemFs.new())

    try do
      x = admit!(store, id("x"))
      assert :ok = ReceiptStore.begin_paste(store, id("x"), x)
      assert last_status(dir) == {"paste_started", 2}
      bytes = File.read!(log_path(dir))

      assert ReceiptStore.transition(store, id("x"), x, "not_delivered") ==
               {:error, :paste_outcome_unproven}

      assert ReceiptStore.transition(store, id("x"), x, "queued") ==
               {:error, :paste_outcome_unproven}

      assert ReceiptStore.begin_paste(store, id("x"), x) == {:error, :paste_already_started}
      assert File.read!(log_path(dir)) == bytes
    after
      stop(store)
    end
  end

  test "W6 boot finalizes v1 nonterminal and v2 queued-without-marker as v2 ambiguous", %{
    inbox: dir
  } do
    write_log!(
      dir,
      chain([
        {1, "a", "pending", 1},
        {1, "b", "pending", 1},
        {1, "b", "queued", 1},
        {2, "c", "pending", 1},
        {2, "c", "queued", 1},
        {2, "d", "pending", 1},
        {2, "d", "paste_started", 1}
      ])
    )

    store = start_store!(dir, SystemFs.new())

    try do
      appended = Enum.drop(log_lines(dir), 7)

      assert Enum.map(appended, &{&1["message_id"], &1["status"], &1["schema_version"]}) == [
               {id("a"), "ambiguous", 2},
               {id("b"), "ambiguous", 2},
               {id("c"), "ambiguous", 2},
               {id("d"), "ambiguous", 2}
             ]

      assert {:ok, %{outcome: "ambiguous"}} =
               ReceiptStore.reconcile(store, id("c"), @pane, @payload)
    after
      stop(store)
    end
  end

  test "W6 a v1 not_delivered attempt is retried as a v2 pending attempt 2", %{inbox: dir} do
    write_log!(dir, chain([{1, "y", "pending", 1}, {1, "y", "not_delivered", 1}]))
    store = start_store!(dir, SystemFs.new())

    try do
      admit!(store, id("y"))
    after
      stop(store)
    end

    assert %{"status" => "pending", "delivery_attempt" => 2, "schema_version" => 2} =
             List.last(log_lines(dir))
  end

  test "W7 an immediate attempt in flight is projected as its pre-marker status, pending", %{
    inbox: dir
  } do
    store = start_store!(dir, SystemFs.new())

    try do
      x = admit!(store, id("x"))
      assert :ok = ReceiptStore.begin_paste(store, id("x"), x)
      assert last_status(dir) == {"paste_started", 2}

      assert {:ok, {:duplicate, view}} = ReceiptStore.admit(store, id("x"), @pane, @payload, self())
      assert view.status == "pending"

      assert {:ok, now} = ReceiptStore.reconcile(store, id("x"), @pane, @payload)
      assert now.status == "pending"
      assert now.outcome == "ambiguous"

      parent = self()

      waiter =
        spawn(fn ->
          send(
            parent,
            {:waited, ReceiptStore.reconcile(store, id("x"), @pane, @payload, wait_ms: 2_000)}
          )
        end)

      await_waiter(store, waiter)
      assert :ok = ReceiptStore.transition(store, id("x"), x, "delivered")
      assert_receive {:waited, {:ok, %{outcome: "delivered"}}}, 2_000

      for reply <- [view, now] do
        refute inspect(reply) =~ "paste_started", "no public reply carries paste_started"
      end
    after
      stop(store)
    end
  end

  test "W7b a queued attempt in flight is projected as queued, not as pending", %{inbox: dir} do
    store = start_store!(dir, SystemFs.new())

    try do
      x = admit!(store, id("x"))
      assert :ok = ReceiptStore.transition(store, id("x"), x, "queued")
      assert :ok = ReceiptStore.begin_paste(store, id("x"), x)
      assert last_status(dir) == {"paste_started", 2}

      assert {:ok, {:duplicate, view}} = ReceiptStore.admit(store, id("x"), @pane, @payload, self())
      assert view.status == "queued"

      assert {:ok, now} = ReceiptStore.reconcile(store, id("x"), @pane, @payload)
      assert now.status == "queued"
      assert now.outcome == "ambiguous"

      for reply <- [view, now] do
        refute inspect(reply) =~ "paste_started", "no public reply carries paste_started"
      end
    after
      stop(store)
    end
  end

  # ----- helpers -----

  defp start_store!(dir, fs) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: dir, fs: fs)
    pid
  end

  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp admit!(store, msg_id) do
    assert {:ok, {:admitted, %{operation_token: token}}} =
             ReceiptStore.admit(store, msg_id, @pane, @payload, self())

    token
  end

  # The exact bytes of the marker an S0b store must append for `msg_id` next: the same record
  # shape every receipt line has, at the next seq, chained to the current last line.
  defp marker_line(dir, store, msg_id, attempt) do
    lines = raw_lines(dir)

    record = %{
      "schema" => @schema,
      "schema_version" => 2,
      "seq" => length(lines) + 1,
      "prev_line_sha256" => digest(List.last(lines)),
      "daemon_epoch" => ReceiptStore.daemon_epoch(store),
      "message_id" => msg_id,
      "pane_id" => @pane,
      "payload_hash" => @payload,
      "status" => "paste_started",
      "delivery_attempt" => attempt
    }

    Jason.encode!(record) <> "\n"
  end

  defp inject_marker_fault!(fs, _dir, _store, _msg_id, :sync, fault),
    do: FaultFs.inject(fs, :sync, FaultFs.count(fs, :sync) + 1, fault)

  defp inject_marker_fault!(fs, dir, store, msg_id, :write, fault) do
    line = marker_line(dir, store, msg_id, 1)

    planned =
      case fault do
        :torn_prefix -> {:torn, div(byte_size(line), 2)}
        :torn_full -> {:torn, byte_size(line)}
        other -> other
      end

    FaultFs.inject(fs, :write, &marker_write?/1, planned)
  end

  # Design r3 boot table: no marker byte on disk (or a torn tail, repaired at open) ends the
  # attempt at its pending record; a complete marker replays. Either way boot appends ambiguous.
  defp boot_expectation(:write, fault) when fault in [{:error, :eio}, :torn_prefix],
    do: [{"pending", 2}, {"ambiguous", 2}]

  defp boot_expectation(_op, _fault), do: [{"pending", 2}, {"paste_started", 2}, {"ambiguous", 2}]

  defp marker_write?([_fd, data]), do: IO.iodata_to_binary(data) =~ ~s("status":"paste_started")

  defp await_waiter(store, waiter) do
    deadline = System.monotonic_time(:millisecond) + 2_000

    Stream.repeatedly(fn ->
      waiting = map_size(:sys.get_state(store).waiters) > 0

      cond do
        waiting ->
          :ok

        not Process.alive?(waiter) ->
          flunk("the reconcile waiter exited before registering")

        System.monotonic_time(:millisecond) > deadline ->
          flunk("the reconcile waiter never registered")

        true ->
          Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  defp chain(rows) do
    {lines, _prev} =
      rows
      |> Enum.with_index(1)
      |> Enum.map_reduce(@anchor, fn {{version, seed, status, attempt}, seq}, prev ->
        line =
          Jason.encode!(%{
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
          }) <> "\n"

        {line, digest(line)}
      end)

    lines
  end

  defp write_log!(dir, lines) do
    path = log_path(dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines))
  end

  defp raw_lines(dir) do
    dir
    |> log_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 <> "\n"))
  end

  defp log_lines(dir), do: dir |> raw_lines() |> Enum.map(&Jason.decode!/1)

  defp last_status(dir) do
    last = List.last(log_lines(dir))
    {last["status"], last["schema_version"]}
  end

  defp log_path(dir), do: Path.join([dir, "delivery", "receipts.jsonl"])

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
