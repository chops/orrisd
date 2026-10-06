defmodule AiPair.Delivery.PayloadStoreRedTest do
  @moduledoc """
  NS-15.G.003 S1 (scope r1, RED design r3), store level: a queued attempt's prompt bytes are
  published to an attempt-bound payload object, durably, BEFORE its queued receipt. S1
  restores nothing.

  Rows: P1 publication order and file modes, P1b mode/identity failure, P2 faults at each
  publication step, P3 an existing object at the final name, P4 the global limits, P5
  terminal cleanup order, P6 boot cleanup and the corrupt-log refusal, P7 directory and object
  safety (detection only; the threat model excludes a concurrent same-uid directory swap),
  P8 the hash guard.

  The store calls that S1 adds are reached through `apply/3`, so this file compiles against
  the base and every row fails there at run time.

  Expected at Orrisd 413916b7: every row fails (no payload store, no queue/4).
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Test.FaultFs

  @pane "%payloadstore_s1"

  setup do
    inbox = Path.join(System.tmp_dir!(), "payloadstore_s1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox, uid: File.lstat!(inbox).uid}
  end

  test "P1 queue publishes one 0600 object in a 0700 directory before the queued receipt", c do
    store = start_store!(c.inbox, SystemFs.new())
    text = "p1 prompt bytes"
    {id, token} = admit!(store, "p1", text)

    assert :ok = queue(store, id, token, text)
    path = object_path(c.inbox, id, 1, text)

    assert File.read!(path) == text
    assert File.lstat!(path).type == :regular
    assert Bitwise.band(File.lstat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.lstat!(payload_dir(c.inbox)).mode, 0o777) == 0o700
    assert last_status(c.inbox, id) == {"queued", 1}
    stop(store)
  end

  test "P1 the FaultFs trace orders the object fully before the queued receipt", c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    {id, token} = admit!(store, "p1-trace", "trace bytes")
    before = length(FaultFs.ops(fs))

    assert :ok = queue(store, id, token, "trace bytes")

    assert Enum.drop(FaultFs.ops(fs), before) == [
             :lstat,
             :open_exclusive,
             :chmod,
             :fstat,
             :write,
             :sync,
             :close,
             :link,
             :unlink,
             :dir_sync,
             :write,
             :sync
           ]

    stop(store)
  end

  test "P1b a temp whose mode cannot be set to 0600 is refused before any byte is written", c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    {id, token} = admit!(store, "p1b-chmod", "mode bytes")
    FaultFs.inject(fs, :chmod, FaultFs.count(fs, :chmod) + 1, {:error, :eperm})
    writes = FaultFs.count(fs, :write)

    assert queue(store, id, token, "mode bytes") == {:error, :payload_store_unavailable}
    assert FaultFs.count(fs, :write) == writes + 1, "only the not_delivered receipt is written"
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert payload_entries(c.inbox) == []
    stop(store)
  end

  # Each case is the fstat of the OPEN temp handle reporting one wrong property.
  for {label, wrong} <- [
        {"mode 0644", %{type: :regular, mode: 0o100644, uid_delta: 0, links: 1}},
        {"a foreign owner", %{type: :regular, mode: 0o100600, uid_delta: 1, links: 1}},
        {"two links", %{type: :regular, mode: 0o100600, uid_delta: 0, links: 2}},
        {"a non-regular file", %{type: :directory, mode: 0o040600, uid_delta: 0, links: 1}}
      ] do
    test "P1b a temp whose open handle reports #{label} is refused before any write", c do
      fs = FaultFs.new()
      store = start_store!(c.inbox, fs)
      {id, token} = admit!(store, "p1b-#{unquote(label)}", "fstat bytes")
      w = unquote(Macro.escape(wrong))
      stat = %File.Stat{type: w.type, mode: w.mode, uid: c.uid + w.uid_delta, links: w.links}
      FaultFs.inject(fs, :fstat, FaultFs.count(fs, :fstat) + 1, {:return, {:ok, stat}})
      writes = FaultFs.count(fs, :write)

      assert queue(store, id, token, "fstat bytes") == {:error, :payload_store_unavailable}
      assert FaultFs.count(fs, :write) == writes + 1, "only the not_delivered receipt is written"
      assert last_status(c.inbox, id) == {"not_delivered", 1}
      assert payload_entries(c.inbox) == []
      stop(store)
    end
  end

  # Each publication step faulted once, as the NEXT call of that operation: queue performs the
  # payload steps before any receipt write, so the next call is the payload's own.
  for {op, at_or_after_link} <- [
        open_exclusive: false,
        write: false,
        sync: false,
        close: false,
        link: true,
        unlink: true,
        dir_sync: true
      ] do
    test "P2 a fault at #{op} gives no queued receipt, a durable not_delivered and boot cleanup",
         c do
      fs = FaultFs.new()
      store = start_store!(c.inbox, fs)
      text = "p2 #{unquote(op)} bytes"
      {id, token} = admit!(store, "p2-#{unquote(op)}", text)
      FaultFs.inject(fs, unquote(op), FaultFs.count(fs, unquote(op)) + 1, {:error, :eio})

      assert queue(store, id, token, text) == {:error, :payload_store_unavailable}
      refute {"queued", 1} in statuses(c.inbox, id), "no queued receipt after a payload fault"
      assert last_status(c.inbox, id) == {"not_delivered", 1}

      unless unquote(at_or_after_link) do
        refute File.exists?(object_path(c.inbox, id, 1, text))
      end

      stop(store)

      # Whatever the fault left (an orphan object or a temp), the next boot removes it.
      restarted = start_store!(c.inbox, SystemFs.new())
      assert payload_entries(c.inbox) == []
      assert {:ok, {:admitted, %{delivery_attempt: 2}}} = admit(restarted, id, text)
      stop(restarted)
    end
  end

  test "P3 an existing object with identical bytes is idempotent", c do
    store = start_store!(c.inbox, SystemFs.new())
    text = "p3 same bytes"
    {id, token} = admit!(store, "p3-same", text)
    path = object_path(c.inbox, id, 1, text)
    File.mkdir_p!(payload_dir(c.inbox))
    File.write!(path, text)
    File.chmod!(path, 0o600)

    assert :ok = queue(store, id, token, text)
    assert File.read!(path) == text
    assert last_status(c.inbox, id) == {"queued", 1}
    stop(store)
  end

  test "P3 an existing object with other bytes or a symlink at the final name is refused", c do
    store = start_store!(c.inbox, SystemFs.new())
    File.mkdir_p!(payload_dir(c.inbox))

    {id1, t1} = admit!(store, "p3-other", "p3 real bytes")
    other = object_path(c.inbox, id1, 1, "p3 real bytes")
    File.write!(other, "different bytes")
    File.chmod!(other, 0o600)

    assert queue(store, id1, t1, "p3 real bytes") == {:error, :payload_store_unavailable}
    assert File.read!(other) == "different bytes"
    assert last_status(c.inbox, id1) == {"not_delivered", 1}

    {id2, t2} = admit!(store, "p3-link", "p3 link bytes")
    target = Path.join(c.inbox, "outside_target")
    File.write!(target, "untouched")
    :ok = File.ln_s(target, object_path(c.inbox, id2, 1, "p3 link bytes"))

    assert queue(store, id2, t2, "p3 link bytes") == {:error, :payload_store_unavailable}
    assert File.read!(target) == "untouched"
    assert last_status(c.inbox, id2) == {"not_delivered", 1}

    {id3, t3} = admit!(store, "p3-dir", "p3 dir bytes")
    in_the_way = object_path(c.inbox, id3, 1, "p3 dir bytes")
    File.mkdir_p!(in_the_way)

    assert queue(store, id3, t3, "p3 dir bytes") == {:error, :payload_store_unavailable}
    assert File.dir?(in_the_way) and File.ls!(in_the_way) == []
    assert last_status(c.inbox, id3) == {"not_delivered", 1}
    stop(store)
  end

  test "P4 the default limits are 256 objects and 64 MiB, room for one full pane", _c do
    assert {256, 67_108_864} = apply(ReceiptStore, :payload_limits, [])
    {_n, bytes} = apply(ReceiptStore, :payload_limits, [])
    assert bytes >= 32 * 524_288
  end

  test "P4 at the default object limit 256 objects are accepted and the 257th is refused", c do
    store = start_store!(c.inbox, SystemFs.new())

    for n <- 1..256 do
      {id, token} = admit!(store, "p4d-#{n}", "p4d #{n}")
      assert :ok = queue(store, id, token, "p4d #{n}")
    end

    retained = snapshot(c.inbox)
    assert length(retained) == 256
    {id, token} = admit!(store, "p4d-257", "p4d 257")

    assert queue(store, id, token, "p4d 257") == {:error, :payload_store_full}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert snapshot(c.inbox) == retained
    stop(store)
  end

  test "P4 at the default byte limit 128 maximum-size objects (64 MiB) are accepted, then refused",
       c do
    store = start_store!(c.inbox, SystemFs.new())
    max = 524_288

    # 128 x 524_288 = 64 MiB exactly; the first 32 are one full pane's queue.
    for n <- 1..128 do
      text = String.duplicate(<<rem(n, 251) + 1>>, max - 4) <> <<n::32>>
      {id, token} = admit!(store, "p4m-#{n}", text)
      assert :ok = queue(store, id, token, text), "max-size object #{n} must be accepted"
    end

    retained = digest_snapshot(c.inbox)
    assert map_size(retained) == 128
    {id, token} = admit!(store, "p4m-129", "x")

    assert queue(store, id, token, "x") == {:error, :payload_store_full}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert digest_snapshot(c.inbox) == retained, "every retained object is byte-identical"
    stop(store)
  end

  test "P4 past the object limit a queue is refused payload_store_full and nothing is deleted", c do
    store = start_store!(c.inbox, SystemFs.new(), payload_limit_objects: 2)

    for n <- 1..2 do
      {id, token} = admit!(store, "p4-#{n}", "p4 bytes #{n}")
      assert :ok = queue(store, id, token, "p4 bytes #{n}")
    end

    retained = snapshot(c.inbox)
    {id3, t3} = admit!(store, "p4-3", "p4 bytes 3")

    assert queue(store, id3, t3, "p4 bytes 3") == {:error, :payload_store_full}
    assert last_status(c.inbox, id3) == {"not_delivered", 1}
    refute {"queued", 1} in statuses(c.inbox, id3)
    assert snapshot(c.inbox) == retained
    stop(store)
  end

  test "P4 past the byte limit a queue is refused payload_store_full and nothing is deleted", c do
    store = start_store!(c.inbox, SystemFs.new(), payload_limit_bytes: 10)
    {id1, t1} = admit!(store, "p4b-1", "six b1")
    assert :ok = queue(store, id1, t1, "six b1")
    retained = snapshot(c.inbox)
    {id2, t2} = admit!(store, "p4b-2", "six b2")

    assert queue(store, id2, t2, "six b2") == {:error, :payload_store_full}
    assert last_status(c.inbox, id2) == {"not_delivered", 1}
    assert snapshot(c.inbox) == retained
    stop(store)
  end

  for terminal <- ~w(delivered not_delivered ambiguous) do
    test "P5 a #{terminal} receipt is durable before its object is removed", c do
      fs = FaultFs.new()
      store = start_store!(c.inbox, fs)
      text = "p5 #{unquote(terminal)} bytes"
      {id, token} = admit!(store, "p5-#{unquote(terminal)}", text)
      assert :ok = queue(store, id, token, text)

      if unquote(terminal) == "delivered",
        do: assert(:ok = ReceiptStore.begin_paste(store, id, token))

      before = length(FaultFs.ops(fs))
      assert :ok = ReceiptStore.transition(store, id, token, unquote(terminal))
      ops = Enum.drop(FaultFs.ops(fs), before)

      assert Enum.take(ops, 2) == [:write, :sync]
      assert Enum.drop(ops, 2) == [:lstat, :unlink, :dir_sync]
      refute File.exists?(object_path(c.inbox, id, 1, text))
      stop(store)
    end
  end

  test "P5 an unlink that fails after the terminal receipt leaves the object for the next boot",
       c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    text = "p5 crash bytes"
    {id, token} = admit!(store, "p5-crash", text)
    assert :ok = queue(store, id, token, text)
    FaultFs.inject(fs, :unlink, FaultFs.count(fs, :unlink) + 1, {:error, :eio})

    assert :ok = ReceiptStore.transition(store, id, token, "ambiguous")
    assert last_status(c.inbox, id) == {"ambiguous", 1}
    assert File.exists?(object_path(c.inbox, id, 1, text))
    stop(store)

    restarted = start_store!(c.inbox, SystemFs.new())
    refute File.exists?(object_path(c.inbox, id, 1, text))
    stop(restarted)
  end

  test "P6 boot finalizes a queued attempt as ambiguous and removes its object (S1 restores nothing)",
       c do
    store = start_store!(c.inbox, SystemFs.new())
    text = "p6 queued bytes"
    {id, token} = admit!(store, "p6-queued", text)
    assert :ok = queue(store, id, token, text)
    stop(store)

    # NS-15.G.003 S2: only an epoch attested in lineage.jsonl restores; without the file the
    # epoch is unattested, as every S1 epoch is (absent at S1, where nothing writes it).
    _ = File.rm(Path.join([c.inbox, "delivery", "lineage.jsonl"]))

    restarted = start_store!(c.inbox, SystemFs.new())
    assert last_status(c.inbox, id) == {"ambiguous", 1}
    assert payload_entries(c.inbox) == []

    assert {:ok, %{outcome: "ambiguous"}} =
             ReceiptStore.reconcile(restarted, id, @pane, hash(text))

    stop(restarted)
  end

  test "P6 boot removes orphans, objects of terminal attempts and leftover temps", c do
    store = start_store!(c.inbox, SystemFs.new())
    {done_id, done_token} = admit!(store, "p6-done", "p6 done bytes")
    assert :ok = queue(store, done_id, done_token, "p6 done bytes")
    assert :ok = ReceiptStore.transition(store, done_id, done_token, "ambiguous")
    stop(store)

    dir = payload_dir(c.inbox)
    terminal_object = object_path(c.inbox, done_id, 1, "p6 done bytes")
    File.write!(terminal_object, "p6 done bytes")
    orphan = object_path(c.inbox, id("p6-orphan"), 1, "orphan bytes")
    File.write!(orphan, "orphan bytes")
    temp = Path.join(dir, ".tmp-leftover")
    File.write!(temp, "partial")
    Enum.each([terminal_object, orphan, temp], &File.chmod!(&1, 0o600))

    restarted = start_store!(c.inbox, SystemFs.new())
    assert payload_entries(c.inbox) == []
    stop(restarted)
  end

  test "P6 a corrupt receipt log refuses the store with the log and every object byte-unchanged",
       c do
    store = start_store!(c.inbox, SystemFs.new())
    {id, token} = admit!(store, "p6-corrupt", "p6 corrupt bytes")
    assert :ok = queue(store, id, token, "p6 corrupt bytes")
    stop(store)

    log = Path.join([c.inbox, "delivery", "receipts.jsonl"])
    File.write!(log, File.read!(log) <> ~s({"not":"a receipt"}\n))
    before = snapshot(c.inbox)
    log_before = File.read!(log)

    assert {:error, _} = GenServer.start(ReceiptStore, inbox: c.inbox, fs: SystemFs.new())
    assert File.read!(log) == log_before
    assert snapshot(c.inbox) == before
  end

  test "P7 a symlinked payload directory disables the store and nothing is written through it",
       c do
    elsewhere = Path.join(c.inbox, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.mkdir_p!(Path.join(c.inbox, "delivery"))
    :ok = File.ln_s(elsewhere, payload_dir(c.inbox))

    store = start_store!(c.inbox, SystemFs.new())
    {id, token} = admit!(store, "p7-symdir", "p7 bytes")

    assert queue(store, id, token, "p7 bytes") == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert File.ls!(elsewhere) == []
    stop(store)
  end

  test "P7 a payload directory owned by another uid disables the store", c do
    File.mkdir_p!(payload_dir(c.inbox))
    File.chmod!(payload_dir(c.inbox), 0o700)
    fs = FaultFs.new()
    dir = payload_dir(c.inbox)
    real = File.lstat!(dir, time: :posix)
    foreign = %{real | uid: real.uid + 1}
    FaultFs.inject(fs, :lstat, fn [path] -> path == dir end, {:return, {:ok, foreign}})

    store = start_store!(c.inbox, fs)
    {id, token} = admit!(store, "p7-owner", "p7 owner bytes")

    assert queue(store, id, token, "p7 owner bytes") == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert File.ls!(dir) == []
    stop(store)
  end

  test "P7 a payload directory with a mode other than 0700 disables the store", c do
    File.mkdir_p!(payload_dir(c.inbox))
    File.chmod!(payload_dir(c.inbox), 0o755)

    store = start_store!(c.inbox, SystemFs.new())
    {id, token} = admit!(store, "p7-mode", "p7 mode bytes")

    assert queue(store, id, token, "p7 mode bytes") == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    assert payload_entries(c.inbox) == []
    stop(store)
  end

  test "P7 a payload directory replaced after init is detected at the next queue", c do
    store = start_store!(c.inbox, SystemFs.new())
    {id1, t1} = admit!(store, "p7-before", "p7 before bytes")
    assert :ok = queue(store, id1, t1, "p7 before bytes")

    dir = payload_dir(c.inbox)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    {id2, t2} = admit!(store, "p7-after", "p7 after bytes")

    assert queue(store, id2, t2, "p7 after bytes") == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id2) == {"not_delivered", 1}
    assert File.ls!(dir) == []
    stop(store)
  end

  test "P7 a symlink at an object name is never followed; boot removes the link entry only", c do
    store = start_store!(c.inbox, SystemFs.new())
    stop(store)

    target = Path.join(c.inbox, "outside_object")
    File.write!(target, "outside bytes")
    link = object_path(c.inbox, id("p7-objlink"), 1, "outside bytes")
    :ok = File.ln_s(target, link)

    restarted = start_store!(c.inbox, SystemFs.new())
    assert {:error, :enoent} = File.lstat(link)
    assert File.read!(target) == "outside bytes"
    stop(restarted)
  end

  test "P7 an object swapped between its lstat and its open is refused, never read", c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    text = "p7 swap bytes"
    {id, token} = admit!(store, "p7-swap", text)
    path = object_path(c.inbox, id, 1, text)
    File.mkdir_p!(payload_dir(c.inbox))
    File.write!(path, text)
    File.chmod!(path, 0o600)

    swap = fn ->
      File.rm!(path)
      File.write!(path, text)
      File.chmod!(path, 0o600)
    end

    FaultFs.inject(fs, :open_read, FaultFs.count(fs, :open_read) + 1, {:hook, swap})

    assert queue(store, id, token, text) == {:error, :payload_store_unavailable}
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    stop(store)
  end

  test "P8 bytes that do not hash to the attempt are refused before any payload write", c do
    fs = FaultFs.new()
    store = start_store!(c.inbox, fs)
    {id, token} = admit!(store, "p8", "the admitted bytes")
    exclusive = FaultFs.count(fs, :open_exclusive)

    assert queue(store, id, token, "other bytes") == {:error, :payload_store_unavailable}
    assert FaultFs.count(fs, :open_exclusive) == exclusive
    assert last_status(c.inbox, id) == {"not_delivered", 1}
    stop(store)
  end

  # ----- helpers -----

  defp queue(store, id, token, text), do: apply(ReceiptStore, :queue, [store, id, token, text])

  defp start_store!(inbox, fs, opts \\ []) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, [inbox: inbox, fs: fs] ++ opts)
    pid
  end

  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp admit(store, msg_id, text),
    do: ReceiptStore.admit(store, msg_id, @pane, hash(text), self())

  defp admit!(store, seed, text) do
    msg_id = id(seed)
    assert {:ok, {:admitted, %{operation_token: token}}} = admit(store, msg_id, text)
    {msg_id, token}
  end

  defp payload_dir(inbox), do: Path.join([inbox, "delivery", "payloads"])

  defp object_path(inbox, msg_id, attempt, text) do
    "sha256:" <> hex = hash(text)
    Path.join(payload_dir(inbox), "#{msg_id}.#{attempt}.#{hex}.payload")
  end

  defp payload_entries(inbox) do
    case File.ls(payload_dir(inbox)) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  defp snapshot(inbox) do
    for name <- payload_entries(inbox),
        do: {name, File.read!(Path.join(payload_dir(inbox), name))}
  end

  # Name -> sha256 of the bytes, so a 64 MiB set is compared byte-for-byte without holding it.
  defp digest_snapshot(inbox) do
    Map.new(payload_entries(inbox), fn name ->
      {name, :crypto.hash(:sha256, File.read!(Path.join(payload_dir(inbox), name)))}
    end)
  end

  defp statuses(inbox, msg_id) do
    [inbox, "delivery", "receipts.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg_id))
    |> Enum.map(&{&1["status"], &1["delivery_attempt"]})
  end

  defp last_status(inbox, msg_id), do: List.last(statuses(inbox, msg_id))

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
